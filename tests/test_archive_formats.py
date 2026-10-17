"""Restore archive regressions using temporary fixtures; Docker is not invoked."""

import io
import os
from pathlib import Path
import re
import subprocess
import tarfile
import tempfile
import unittest


REPO = Path(__file__).resolve().parents[1]
RESTORE = Path(os.environ.get("DOCKER_RESTORE_SOURCE", REPO / "DockerBackup/ugreen-docker-restore.sh"))
SOURCE = RESTORE.read_text()
EXTRACT = re.search(r"^extract_archive\(\)\{\n.*?^\}", SOURCE, re.M | re.S).group(0)
HELPERS = """
set -euo pipefail
mkdir_safe() { mkdir -p "$1"; }
log_i() { :; }
tr_text() { printf '%s' "$2"; }
die() { printf '%s\\n' "$*" >&2; exit 1; }
"""


class ArchiveFormatTests(unittest.TestCase):
    def check_archive(self, mode, suffix, valid_structure=True):
        with tempfile.TemporaryDirectory(prefix="docker archive test ") as temporary:
            root = Path(temporary)
            archive = root / ("backup" + suffix)
            payload = b"SCRIPT_VERSION=fixture\n"
            member = "ugreen-docker-backup_fixture/metadata/manifest.env" if valid_structure else "unrelated/file.txt"
            with tarfile.open(archive, mode) as handle:
                info = tarfile.TarInfo(member)
                info.size = len(payload)
                handle.addfile(info, io.BytesIO(payload))
            env = dict(os.environ, TEMP_DIR=str(root / "restore temp"), RESTORE_ARCHIVE=str(archive))
            result = subprocess.run(
                ["bash", "-c", HELPERS + EXTRACT + '\nextract_archive\nprintf "%s\\n" "$backup_root"'],
                env=env, capture_output=True, text=True, timeout=10,
            )
            if valid_structure:
                self.assertEqual(result.returncode, 0, result.stderr)
                restored = Path(result.stdout.strip()) / "metadata/manifest.env"
                self.assertEqual(restored.read_bytes(), payload)
            else:
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("Backup structure not recognized", result.stderr)

    def test_uncompressed_tar(self):
        self.check_archive("w", ".tar")

    def test_gzip_tar(self):
        self.check_archive("w:gz", ".tar.gz")

    def test_gzip_without_filename_extension(self):
        self.check_archive("w:gz", "")

    def test_unrecognized_structure_fails(self):
        self.check_archive("w:gz", ".tar.gz", valid_structure=False)


if __name__ == "__main__":
    unittest.main(verbosity=2)
