"""Reject contradictory current-version labels before building a release."""
import importlib.util
from pathlib import Path
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]

class ReleaseVersionTests(unittest.TestCase):
    def test_stale_current_version_label_is_rejected(self):
        spec = importlib.util.spec_from_file_location('release_builder', ROOT / 'scripts/build_release.py')
        builder = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(builder)
        original = Path.read_text
        def read_text(path, *args, **kwargs):
            text = original(path, *args, **kwargs)
            if path == ROOT / 'README.md':
                text += '\nCurrent script version: **v0.0.0**\n'
            return text
        with patch.object(Path, 'read_text', read_text):
            with self.assertRaisesRegex(ValueError, 'Conflicting current version'):
                builder.payload()

if __name__ == '__main__':
    unittest.main()

