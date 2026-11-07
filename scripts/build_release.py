"""Build and verify the release payload without running an installer or real services."""
import argparse
import hashlib
import json
import os
import re
from pathlib import Path
import shutil
import struct
import subprocess
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[1]
CONFIG = json.loads((ROOT / 'release.json').read_text(encoding='utf-8'))
SOURCE_COMMIT = None
LAUNCH_CHECK = False


def digest(data):
    return hashlib.sha256(data).hexdigest()


def canonical(name):
    data = (ROOT / name).read_bytes()
    if Path(name).suffix.lower() not in ('.pdf', '.sfx', '.png', '.jpg'):
        data = data.replace(b'\r\n', b'\n')
        if Path(name).suffix.lower() in ('.cmd', '.ps1'):
            data = data.replace(b'\n', b'\r\n')
    return data


def payload():
    version = CONFIG['version']
    for name, marker in CONFIG['version_markers'].items():
        text = (ROOT / name).read_text(encoding='utf-8-sig')
        if marker.format(version=version) not in text:
            raise ValueError('Version mismatch: ' + name)
    files = {name: canonical(name) for name in CONFIG['files']}
    commit = SOURCE_COMMIT or subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()
    if not re.fullmatch(r'[0-9a-f]{40}', commit):
        raise ValueError('A complete source commit SHA is required')
    info = {'version': version, 'source_commit': commit,
        'sha256': {name: digest(data) for name, data in sorted(files.items())}}
    files['BUILDINFO.json'] = (json.dumps(info, indent=2, sort_keys=True) + '\n').encode()
    return files


def seven_zip():
    tool = os.environ.get('SEVEN_ZIP') or shutil.which('7z')
    if not tool and os.name == 'nt':
        candidate = Path(os.environ.get('ProgramFiles', 'C:/Program Files')) / '7-Zip/7z.exe'
        if candidate.is_file():
            tool = str(candidate)
    if not tool:
        raise RuntimeError('7-Zip is required to build and verify the setup.')
    return tool


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
    if CONFIG.get('setup'):
        setup = output / CONFIG['setup']
        stub = (ROOT / 'packaging/7zSD.sfx').read_bytes()
        if digest(stub) != CONFIG['sfx_sha256']:
            raise ValueError('SFX module checksum mismatch')
        pe = struct.unpack_from('<I', stub, 0x3c)[0]
        if stub[:2] != b'MZ' or stub[pe:pe+4] != b'PE\x00\x00':
            raise ValueError('Invalid SFX executable')
        with tempfile.TemporaryDirectory(prefix='veyon-package-') as temporary:
            directory = Path(temporary)
            for name, data in files.items():
                target = directory / name
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_bytes(data)
            compressed = directory / 'payload.7z'
            subprocess.run([seven_zip(), 'a', '-t7z', '-mx=9', '-mtc=off', '-mta=off', '-mtm=off',
                            str(compressed), *sorted(files)], cwd=directory, check=True,
                           stdout=subprocess.DEVNULL)
            config = (';!@Install@!UTF-8!\nTitle="Veyon Updater v' + CONFIG['version'] +
                      '"\nBeginPrompt="Veyon Updater installieren?"\n'
                      'Progress="no"\nRunProgram="cmd.exe /d /c Install-Veyon-AutoUpdate.cmd"\n;!@InstallEnd@!\n').encode()
            setup.write_bytes(stub + config + compressed.read_bytes())
            extracted = directory / 'verify'
            subprocess.run([seven_zip(), 'x', '-y', '-o' + str(extracted), str(setup.resolve())],
                           check=True, stdout=subprocess.DEVNULL)
            actual = {p.relative_to(extracted).as_posix(): p.read_bytes()
                      for p in extracted.rglob('*') if p.is_file()}
            if actual != files:
                raise ValueError('Setup payload does not match ZIP/source payload')
        assets.append(setup)
    else:
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
        command = ['powershell.exe', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
                   str(ROOT / 'tests/test_update.ps1')] if CONFIG.get('setup') else [
                   'python3', '-m', 'unittest', 'discover', '-s', 'tests', '-v']
        subprocess.run(command, cwd=ROOT, env=env, check=True)
        if LAUNCH_CHECK:
            if not CONFIG.get('setup') or os.name != 'nt':
                raise RuntimeError('Setup launch check requires Windows and a setup package')
            marker = directory / 'bootstrap-marker.txt'
            # Exercise the same SFX bootstrap with a harmless stand-in, never the real installer.
            synthetic = {'Install-Veyon-AutoUpdate.cmd':
                         b'@echo off\r\n> "%SFX_TEST_MARKER%" echo %CD%\r\nexit /b 0\r\n'}
            probe = build(directory / 'bootstrap', synthetic)
            env = dict(os.environ, SFX_TEST_MARKER=str(marker))
            subprocess.run([str(probe[-1]), '-y'], env=env, check=True, timeout=30,
                           creationflags=subprocess.CREATE_NO_WINDOW)
            if not marker.is_file():
                raise ValueError('SFX did not run the synthetic bootstrap')
            extraction = Path(marker.read_text().strip())
            if extraction.exists():
                raise ValueError('SFX left its temporary extraction directory behind')
            print('SFX bootstrap launch and extraction cleanup: OK')
    print('Package versions, contents, checksums, reproducibility and packaged-source tests: OK')


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path)
    parser.add_argument('--check', action='store_true')
    parser.add_argument('--source-commit', help='Verified source SHA when building from an exported source tree without Git')
    parser.add_argument('--check-setup-launch', action='store_true', help='Windows: exercise the SFX with a harmless installer stand-in')
    args = parser.parse_args()
    SOURCE_COMMIT = args.source_commit
    LAUNCH_CHECK = args.check_setup_launch
    files = payload()
    if args.check:
        check(files)
    if args.output:
        build(args.output.resolve(), files)
    if not args.check and not args.output:
        parser.error('Use --check and/or --output DIRECTORY')
