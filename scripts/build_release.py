"""Build and verify a complete release without invoking Docker, libvirt or hardware."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[1]
CONFIG = json.loads((ROOT / 'release.json').read_text(encoding='utf-8'))
SOURCE_COMMIT = None


def digest(data):
    return hashlib.sha256(data).hexdigest()


def payload():
    version = CONFIG['version']
    for name, marker in CONFIG['version_markers'].items():
        if marker.format(version=version) not in (ROOT / name).read_text(encoding='utf-8-sig'):
            raise ValueError('Version mismatch: ' + name)
    files = {}
    for name in CONFIG['files']:
        data = (ROOT / name).read_bytes()
        if not name.endswith('.pdf'):
            data = data.replace(b'\r\n', b'\n')
        files[name] = data
    commit = SOURCE_COMMIT or subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()
    if not re.fullmatch(r'[0-9a-f]{40}', commit):
        raise ValueError('A complete source commit SHA is required')
    info = {'version': version, 'source_commit': commit,
            'sha256': {name: digest(data) for name, data in sorted(files.items())}}
    files['BUILDINFO.json'] = (json.dumps(info, indent=2, sort_keys=True) + '\n').encode()
    return files


def build(output, files):
    output.mkdir(parents=True, exist_ok=True)
    archive_path = output / CONFIG['archive']
    with zipfile.ZipFile(archive_path, 'w', zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for name, data in sorted(files.items()):
            entry = zipfile.ZipInfo(name, (2026, 1, 1, 0, 0, 0))
            entry.compress_type = zipfile.ZIP_DEFLATED
            entry.external_attr = ((0o100755 if name.endswith('.sh') else 0o100644) << 16)
            archive.writestr(entry, data)
    assets = [archive_path]
    for name in CONFIG.get('separate_assets', []):
        path = output / Path(name).name
        path.write_bytes(files[name])
        assets.append(path)
    with zipfile.ZipFile(archive_path) as archive:
        if archive.testzip() is not None or set(archive.namelist()) != set(files):
            raise ValueError('Invalid or incomplete ZIP')
        if any(archive.read(name) != data for name, data in files.items()):
            raise ValueError('ZIP content mismatch')
    (output / 'SHA256SUMS').write_text(''.join(
        digest(path.read_bytes()) + '  ' + path.name + '\n' for path in assets), encoding='ascii')
    return assets


def check(files):
    with tempfile.TemporaryDirectory(prefix='release-check-') as temporary:
        directory = Path(temporary)
        first = build(directory / 'first', files)
        second = build(directory / 'second', files)
        if [p.read_bytes() for p in first] != [p.read_bytes() for p in second]:
            raise ValueError('Package build is not reproducible')
        extracted = directory / 'source'
        with zipfile.ZipFile(first[0]) as archive:
            archive.extractall(extracted)
        env = dict(os.environ)
        for variable, name in CONFIG['test_sources'].items():
            env[variable] = str(extracted / name)
        subprocess.run(['python3', '-m', 'unittest', 'discover', '-s', 'tests', '-v'],
                       cwd=ROOT, env=env, check=True)
    print('Package versions, contents, checksums, reproducibility and packaged-source tests: OK')


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path)
    parser.add_argument('--check', action='store_true')
    parser.add_argument('--source-commit', help='Verified source SHA for an exported source tree without Git')
    args = parser.parse_args()
    SOURCE_COMMIT = args.source_commit
    files = payload()
    if args.check:
        check(files)
    if args.output:
        build(args.output.resolve(), files)
    if not args.check and not args.output:
        parser.error('Use --check and/or --output DIRECTORY')
