"""Round-trip real temporary files; never contact Docker or UGOS."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
BACKUP = Path(os.environ.get('DOCKER_BACKUP_SOURCE', ROOT / 'DockerBackup/ugreen-docker-backup.sh'))
RESTORE = Path(os.environ.get('DOCKER_RESTORE_SOURCE', ROOT / 'DockerBackup/ugreen-docker-restore.sh'))


class MetadataTests(unittest.TestCase):
    def scenario(self, existing):
        with tempfile.TemporaryDirectory(prefix='docker-metadata-') as directory:
            root = Path(directory)
            source = root / 'source' / 'alpha'
            source.mkdir(parents=True)
            payload = source / 'payload.txt'
            payload.write_text('synthetic data\n')
            payload.chmod(0o640)
            subprocess.run(['setfacl', '-m', 'u:12345:r--', str(payload)], check=True)
            before = subprocess.check_output(['getfacl', '-cpn', str(payload)])
            original = payload.stat()
            stage = root / 'stage'
            (stage / 'metadata').mkdir(parents=True)
            (stage / 'projects').mkdir()
            (stage / 'metadata/manifest.env').write_text(f'SOURCE_DIR={root}/source\n')
            (stage / 'metadata/selected_projects.tsv').write_text(
                'project\tworkdir\tconfig_files\tcontainers\timages\tis_standalone\n'
                f'alpha\t{source}\t{source}/compose.yaml\tfixture\tfixture\tfalse\n')
            target = root / 'target' / 'alpha'
            if existing:
                target.mkdir(parents=True)
                (target / 'compose.yaml').write_text(f'path: {source}/keep\n')
                expected = (target / 'compose.yaml').read_bytes()
            backup = root / 'backup-helpers.sh'
            restore = root / 'restore-helpers.sh'
            for destination, script in ((backup, BACKUP), (restore, RESTORE)):
                destination.write_text(script.read_text().rsplit('\nmain "$@"', 1)[0])
            harness = f'''set -e
source "{backup}"
trap - ERR
stage_dir="{stage}"
log_file="{root}/backup.log"
SOURCE_DIR="{root}/source"
copy_project_dirs
source "{restore}"
trap - ERR
log_file="{root}/restore.log"
backup_root="{stage}"
extract_parent="{root}/extract"
mkdir -p "$extract_parent"
map_path() {{ printf '%s' "{target}"; }}
restore_project_dirs
'''
            env = dict(os.environ, ENV_FILE='/dev/null', RESTORE_PROJECTS='alpha',
                       RESTORE_ALL_PROJECTS='false', RESTORE_OVERWRITE_EXISTING='false',
                       DRY_RUN='false', BACKUP_EXCLUDE_PATHS_FILE='',
                       BACKUP_PROJECTS_OUTSIDE_SOURCE_DIR='false',
                       ENABLE_PATH_REMAP='true', APPLY_PATH_REMAP_TO_TEXT_FILES='true',
                       PATH_REMAP_FROM=str(root / 'source'), PATH_REMAP_TO=str(root / 'target'))
            result = subprocess.run(['bash', '-c', harness], env=env, capture_output=True,
                                    text=True, timeout=15)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            if existing:
                self.assertEqual((target / 'compose.yaml').read_bytes(), expected)
                self.assertFalse((target / 'payload.txt').exists())
            else:
                restored = target / 'payload.txt'
                self.assertEqual(restored.read_bytes(), payload.read_bytes())
                self.assertEqual(subprocess.check_output(['getfacl', '-cpn', str(restored)]), before)
                self.assertEqual((restored.stat().st_uid, restored.stat().st_gid,
                                  restored.stat().st_mode),
                                 (original.st_uid, original.st_gid, original.st_mode))

    def test_backup_restore_retains_additional_acl_owner_and_mode(self):
        self.scenario(existing=False)

    def test_existing_target_keeps_contents_with_remapping_enabled(self):
        self.scenario(existing=True)


if __name__ == '__main__':
    unittest.main()
