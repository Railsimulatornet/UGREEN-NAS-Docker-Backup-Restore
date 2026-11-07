"""Exercise the real restore helpers with synthetic metadata and command doubles."""
import os
import ast
import re
from pathlib import Path
import subprocess
import tempfile
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
        self.assertEqual(self.run_helper('project_selected alpha', RESTORE_ALL_PROJECTS='true').returncode, 0)
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


if __name__ == '__main__':
    unittest.main()
