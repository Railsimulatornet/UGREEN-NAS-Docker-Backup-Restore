"""Run the complete backup script; invalid selections must never stop containers."""
import json
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = Path(os.environ.get('DOCKER_BACKUP_SOURCE', ROOT / 'DockerBackup/ugreen-docker-backup.sh'))


class BackupCompletenessTests(unittest.TestCase):
    def scenario(self, kind, allowed=False):
        with tempfile.TemporaryDirectory(prefix='backup-selection-') as temporary:
            root = Path(temporary)
            source = root / 'source'
            source.mkdir()
            locations = [source / 'inside project'] if kind == 'inside' else [root / 'outside']
            if kind == 'mixed':
                locations.insert(0, source / 'inside')
            fixtures = []
            for index, location in enumerate(locations):
                if kind != 'missing':
                    location.mkdir()
                    (location / 'payload.txt').write_text('must be in the backup\n')
                fixtures.append(dict(Id=str(index), Name='/fixture'+str(index),
                    Config=dict(Image='fixture:local', Labels={
                        'com.docker.compose.project': 'project'+str(index),
                        'com.docker.compose.service': 'app',
                        'com.docker.compose.project.working_dir': str(location),
                        'com.docker.compose.project.config_files': str(location / 'compose.yaml')}),
                    State=dict(Running=kind != 'inside' and not allowed), Mounts=[], NetworkSettings=dict(Networks={})))
            (root / 'fixtures.json').write_text(json.dumps(fixtures))
            docker = root / 'docker'
            docker.write_text('''#!/usr/bin/env python3
import json,os,sys
from pathlib import Path
root=Path(os.environ['FIXTURES'])
a=sys.argv[1:]
with (root/'calls.jsonl').open('a') as f:f.write(json.dumps(a)+'\\n')
if a[:2]==['ps','-aq']:
    print('\\n'.join(x['Id'] for x in json.loads((root/'fixtures.json').read_text())))
elif a[:1]==['inspect']:
    print((root/'fixtures.json').read_text())
elif a[:2]==['compose','ls']:
    print('[]')
elif a[:1] in (['start'],['stop'],['kill']):
    sys.exit(99)
''')
            docker.chmod(0o755)
            env = dict(os.environ, ENV_FILE='/dev/null', FIXTURES=str(root),
                SOURCE_DIR=str(source), DOCKER_ROOT_DIR=str(root / 'docker-root'),
                UGOS_DOCKER_DB=str(root / 'missing.db'), DOCKER_BIN=str(docker),
                BACKUP_DIR=str(root / 'backups'), TEMP_DIR=str(root / 'temp'),
                LOG_DIR=str(root / 'logs'), LANGUAGE='en', SEND_MAIL='false',
                BACKUP_ALL_PROJECTS='true', BACKUP_STANDALONE_CONTAINERS='false',
                BACKUP_PROJECTS_OUTSIDE_SOURCE_DIR='true' if allowed else 'false',
                BACKUP_DOCKER_APP_DB='false', BACKUP_IMAGES='false',
                BACKUP_NAMED_VOLUMES='false', BACKUP_EXTERNAL_BINDS='false',
                BACKUP_DOCKER_DIR_EXTERNAL_BINDS='false', ENABLE_REMOTE_BACKUP='false',
                SHUTDOWN_AFTER_SUCCESS='false', KEEP_BACKUPS='0',
                STOP_CONTAINERS='false' if allowed else 'true')
            p = subprocess.run(['bash', str(SCRIPT)], env=env, capture_output=True,
                               text=True, timeout=30)
            archives = list((root / 'backups').glob('*.tar*'))
            calls = [json.loads(x) for x in (root / 'calls.jsonl').read_text().splitlines()]
            self.assertFalse(any(a[0] in ('stop', 'start', 'kill') for a in calls))
            if kind == 'inside' or allowed:
                self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
                self.assertEqual(len(archives), 1)
                with tarfile.open(archives[0]) as archive:
                    self.assertTrue(any('/projects/project0.tar' in n for n in archive.getnames()))
            else:
                self.assertNotEqual(p.returncode, 0, p.stdout + p.stderr)
                self.assertEqual(archives, [])
                self.assertNotIn('Backup completed.', p.stdout)
                self.assertIn('Selected project', p.stdout)

    def test_outside_source_aborts_before_stopping(self):
        self.scenario('outside')

    def test_missing_directory_aborts_before_stopping(self):
        self.scenario('missing')

    def test_mixed_selection_never_reports_partial_success(self):
        self.scenario('mixed')

    def test_valid_project_is_really_archived(self):
        self.scenario('inside')

    def test_explicit_outside_source_opt_in_is_preserved(self):
        self.scenario('outside', allowed=True)
