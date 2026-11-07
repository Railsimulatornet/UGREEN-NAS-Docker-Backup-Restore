"""Exercise the real restore helpers with synthetic metadata and command doubles."""
import os
import ast
import re
from pathlib import Path
import subprocess
import tempfile
import tarfile
import io
import unittest

REPO = Path(__file__).resolve().parents[1]
SOURCE = (REPO / 'DockerBackup/ugreen-docker-restore.sh').read_text()


class SelectionTests(unittest.TestCase):
    def test_embedded_python_selection_matches_shell(self):
        blocks = re.findall(r"<<'PY[A-Z]*'\n(.*?)\nPY[A-Z]*", SOURCE, re.S)
        checked = 0
        for block in blocks:
            tree = ast.parse(block)
            for node in tree.body:
                if not isinstance(node, ast.FunctionDef) or node.name != 'selected':
                    continue
                checked += 1
                for all_projects, projects, exclusions, expected in (
                    (False, set(), set(), False),
                    (False, {'alpha'}, set(), True),
                    (False, {'beta'}, set(), False),
                    (True, set(), set(), True),
                    (True, set(), {'alpha'}, False),
                ):
                    namespace = dict(restore_all=all_projects, restore_projects=projects,
                                     exclude_projects=exclusions, archived_projects={'alpha': {}})
                    exec(compile(ast.Module(body=[node], type_ignores=[]), '<selected>', 'exec'), namespace)
                    self.assertEqual(namespace['selected']('alpha'), expected)
        self.assertEqual(checked, 2)

    def run_helper(self, code, **settings):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            script = root / 'helpers.sh'
            script.write_text(SOURCE.rsplit('\nmain "$@"', 1)[0])
            metadata = root / 'metadata'
            metadata.mkdir()
            (metadata / 'project_archives.tsv').write_text(
                'project\tarchive\tworkdir\tconfig_files\n'
                f'alpha\ta.tar\t{root}/alpha\t{root}/alpha/compose.yaml\n'
                f'beta\tb.tar\t{root}/beta\t{root}/beta/compose.yaml\n')
            archive = root / 'backup.tar'
            archive.touch()
            env = dict(os.environ, ENV_FILE='/dev/null', RESTORE_ALL_PROJECTS='false',
                       RESTORE_PROJECTS='', EXCLUDE_PROJECTS='', RESTORE_ARCHIVE=str(archive),
                       TEST_ROOT=str(root), RESTORE_FIX_PERMISSIONS='', RESTORE_FIX_OWNER='',
                       RESTORE_FIX_DIR_MODE='', RESTORE_FIX_FILE_MODE='')
            env.update(settings)
            harness = '''source "$1"
trap - ERR
log_file="$TEST_ROOT/log"
backup_root="$TEST_ROOT"
extract_parent="$TEST_ROOT"
log() { printf '%s\\n' "$*"; }
map_path() { printf '%s' "$1"; }
''' + code
            return subprocess.run(['bash', '-c', harness, 'test', str(script)], env=env,
                                  capture_output=True, text=True, timeout=10)

    def test_empty_or_separator_only_selection_aborts(self):
        for selection in ('', '   ', ', ; ', '\t'):
            with self.subTest(selection=selection):
                result = self.run_helper('validate_restore_selection', RESTORE_PROJECTS=selection)
                self.assertNotEqual(result.returncode, 0, result.stdout)

    def test_empty_selection_does_not_select_project(self):
        self.assertNotEqual(self.run_helper('project_selected alpha').returncode, 0)

    def test_explicit_all_and_exclusions(self):
        for flag in ('true', '1', 'yes', 'y', 'ja', 'TRUE'):
            self.assertEqual(self.run_helper('project_selected alpha', RESTORE_ALL_PROJECTS=flag).returncode, 0)
        self.assertNotEqual(self.run_helper('project_selected alpha', RESTORE_ALL_PROJECTS='true', EXCLUDE_PROJECTS='alpha').returncode, 0)

    def test_targeted_selection(self):
        self.assertEqual(self.run_helper('project_selected alpha', RESTORE_PROJECTS='alpha;beta').returncode, 0)
        self.assertNotEqual(self.run_helper('project_selected beta', RESTORE_PROJECTS='alpha').returncode, 0)

    def test_unknown_or_excluded_selection_has_no_plan(self):
        for settings in ({'RESTORE_PROJECTS': 'unknown'}, {'RESTORE_ALL_PROJECTS': 'true', 'EXCLUDE_PROJECTS': 'alpha,beta'}):
            self.assertNotEqual(self.run_helper('show_restore_plan', **settings).returncode, 0)

    def test_plan_contains_only_selected_target_and_changes(self):
        result = self.run_helper('show_restore_plan', RESTORE_PROJECTS='alpha')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('alpha -> ', result.stdout)
        self.assertNotIn('beta -> ', result.stdout)
        self.assertIn('permissions=false', result.stdout)
        self.assertIn('ugos_database=', result.stdout)

    def test_permissions_preserved_by_default(self):
        result = self.run_helper('''
chown() { echo UNEXPECTED_CHOWN; return 99; }
chmod() { echo UNEXPECTED_CHMOD; return 99; }
apply_restore_permissions "$TEST_ROOT"
printf '%s:%s' "$RESTORE_FIX_PERMISSIONS" "$RESTORE_FIX_OWNER"
''')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, 'false:keep')

    def test_compose_uses_explicit_files_for_stop_and_start(self):
        result = self.run_helper('''
mkdir -p "$TEST_ROOT/alpha"
touch "$TEST_ROOT/alpha/compose.yaml"
validate_bind_mounts_for_project() { return 0; }
run_cmd_in_dir() { shift; printf 'COMMAND'; printf ' <%s>' "$@"; printf '\\n'; }
compose_up_projects
''', RESTORE_PROJECTS='alpha')
        self.assertEqual(result.returncode, 0, result.stderr)
        commands = [line for line in result.stdout.splitlines() if line.startswith('COMMAND')]
        self.assertEqual(len(commands), 2, result.stdout)
        for command in commands:
            self.assertIn('<compose> <-p> <alpha> <-f>', command)
        self.assertIn('<down>', commands[0])
        self.assertIn('<up> <-d>', commands[1])

    def test_missing_compose_file_does_not_stop_project(self):
        result = self.run_helper('''
mkdir -p "$TEST_ROOT/alpha"
validate_bind_mounts_for_project() { return 0; }
run_cmd_in_dir() { echo UNEXPECTED_COMMAND; return 99; }
compose_up_projects
''', RESTORE_PROJECTS='alpha')
        self.assertNotIn('UNEXPECTED_COMMAND', result.stdout)


class RestoreEntryTests(unittest.TestCase):
    def check_entry(self, dry_run, selection, expect_success):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            commands = root / 'bin'
            commands.mkdir()
            audit = root / 'calls'
            docker = commands / 'docker'
            docker.write_text('''#!/usr/bin/env bash
printf '%s\\n' "$*" >> "$AUDIT"
[[ "$*" == info ]] && exit 0
exit 99
''')
            docker.chmod(0o755)
            for name in ('systemctl', 'service', 'chown', 'chmod'):
                stub = commands / name
                stub.write_text('#!/usr/bin/env bash\necho UNEXPECTED >> "$AUDIT"\nexit 99\n')
                stub.chmod(0o755)
            target = root / 'target'
            target.mkdir()
            project = target / 'alpha'
            project.mkdir()
            compose = project / 'compose.yaml'
            compose.write_text('services: {}\n')
            sentinel = project / 'keep'
            sentinel.write_bytes(b'UNCHANGED\x00')
            original_mode = sentinel.stat().st_mode
            database = root / 'ugos.db'
            database.write_bytes(b'UNCHANGED DATABASE')
            archive = root / 'backup.tar.gz'
            members = {
                'metadata/manifest.env': 'SCRIPT_VERSION=fixture\n',
                'metadata/project_archives.tsv':
                    'project\tarchive\tworkdir\tconfig_files\n'
                    f'alpha\tprojects/alpha.tar\t{project}\t{compose}\n',
            }
            with tarfile.open(archive, 'w:gz') as handle:
                for name, content in members.items():
                    payload = content.encode()
                    info = tarfile.TarInfo('ugreen-docker-backup_fixture/' + name)
                    info.size = len(payload)
                    handle.addfile(info, io.BytesIO(payload))
            env = dict(os.environ, ENV_FILE='/dev/null', LANGUAGE='en',
                       BACKUP_DIR=str(root / 'backups'), SOURCE_DIR=str(target),
                       DOCKER_ROOT_DIR=str(root / 'docker-root'), UGOS_DOCKER_DB=str(database),
                       DOCKER_BIN=str(docker), RESTORE_ARCHIVE=str(archive),
                       RESTORE_ALL_PROJECTS='false', RESTORE_PROJECTS=selection,
                       DRY_RUN=dry_run, SEND_MAIL='false', RESTORE_CONFIRMATION_REQUIRED='false',
                       RESTORE_OVERWRITE_EXISTING='true', AUDIT=str(audit),
                       PATH=str(commands) + os.pathsep + os.environ['PATH'])
            result = subprocess.run(['bash', str(REPO / 'DockerBackup/ugreen-docker-restore.sh')],
                                    env=env, capture_output=True, text=True, timeout=15)
            self.assertEqual(result.returncode == 0, expect_success, result.stdout + result.stderr)
            self.assertEqual(audit.read_text().splitlines(), ['info'])
            self.assertEqual(sentinel.read_bytes(), b'UNCHANGED\x00')
            self.assertEqual(sentinel.stat().st_mode, original_mode)
            self.assertEqual(database.read_bytes(), b'UNCHANGED DATABASE')
            self.assertEqual(compose.read_text(), 'services: {}\n')
            self.assertEqual(sorted(path.name for path in target.iterdir()), ['alpha'])

    def test_full_dry_run_preserves_targets_and_database(self):
        self.check_entry('true', 'alpha', True)

    def test_empty_selection_aborts_before_real_restore(self):
        self.check_entry('false', '', False)


if __name__ == '__main__':
    unittest.main()
