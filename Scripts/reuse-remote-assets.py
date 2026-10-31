#!/usr/bin/env python3
"""Reuse only a complete published helper set with identical build inputs."""
import argparse
import importlib.util
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile

TOOLS = Path(__file__).resolve().parent

def load(name):
    """Load an adjacent release-tool module without running its CLI entry point."""
    spec = importlib.util.spec_from_file_location(name.replace('-', '_'), TOOLS / (name + '.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module

verifier = load('verify-remote-assets')
inputs = load('remote-helper-inputs')

def package_info(path):
    """Read bounded metadata from an archive without extracting its contents."""
    with tarfile.open(path) as archive:
        member = archive.getmember('build-info.json')
        if not member.isfile() or member.size > 16384:
            raise ValueError('Invalid package metadata')
        info = json.load(archive.extractfile(member))
        if not isinstance(info, dict):
            raise ValueError('Package metadata must be an object')
        return info

def repackage(previous, old_version, version, source_sha, output, fingerprint, installer):
    """Atomically repackage a fully verified matching set with original provenance.

    Binary bytes remain unchanged; only the release metadata and installer are
    refreshed. Validation failures leave the final output directory absent.
    """
    if output.exists() or output.is_symlink():
        raise ValueError('Output exists; refusing to mix stale helper assets')
    if not re.fullmatch(r'\d+\.\d+\.\d+', version) or not re.fullmatch(r'[0-9a-f]{40}', source_sha):
        raise ValueError('Invalid target version/source')
    if not re.fullmatch(r'\d+\.\d+\.\d+', old_version):
        raise ValueError('Invalid published version')
    names = [f'zackeyes-remote-{old_version}-{p}.tar.gz' for p in verifier.PLATFORMS]
    old_source = package_info(previous / names[0]).get('source_sha', '')
    verifier.verify(previous, old_version, old_source, fingerprint)
    # Stage everything before the final rename. Reuse never exposes a partial set.
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.helper-reuse-', dir=output.parent) as temporary:
        root = Path(temporary)
        stage = root / 'bundle'
        stage.mkdir()
        for platform, name in zip(verifier.PLATFORMS, names):
            info = package_info(previous / name)
            binary = root / 'zackeyes'
            with tarfile.open(previous / name) as archive, binary.open('wb') as destination:
                shutil.copyfileobj(archive.extractfile('zackeyes'), destination)
            subprocess.run([sys.executable, str(TOOLS / 'package-remote-helper.py'),
                            version, platform, str(binary), source_sha, str(stage),
                            '--compiled-source-sha', info['compiled_source_sha'],
                            '--helper-inputs-sha256', fingerprint], check=True, capture_output=True)
        shutil.copyfile(installer, stage / 'install-remote.sh')
        artifacts = sorted(stage.glob('*.tar.gz')) + [stage / 'install-remote.sh']
        (stage / 'SHA256SUMS').write_text(''.join(f'{verifier.file_hash(p)}  {p.name}\n' for p in artifacts))
        verifier.verify(stage, version, source_sha, fingerprint)
        stage.rename(output)

def reuse_latest(version, source_sha, output, source):
    """Reuse the latest stable published helpers only when all build inputs match.

    GitHub calls are read-only. Lookup, download or validation failures propagate
    to the CLI, which reports the cause and requests a fresh native build.
    """
    fingerprint = inputs.fingerprint(source, source_sha)
    release = json.loads(subprocess.check_output([
        'gh', 'release', 'view', '--repo', 'yangshiqi/ZackEyes-release',
        '--json', 'tagName,isDraft,isPrerelease'], text=True, stderr=subprocess.PIPE, timeout=30))
    if not isinstance(release, dict):
        raise ValueError('Invalid distribution release metadata')
    tag = release.get('tagName', '')
    if release.get('isDraft') or release.get('isPrerelease') or not re.fullmatch(r'v\d+\.\d+\.\d+', tag):
        raise ValueError('No stable distribution release available')
    old_version = tag[1:]
    with tempfile.TemporaryDirectory(prefix='zackeyes-published-helpers-') as temporary:
        previous = Path(temporary)
        command = ['gh', 'release', 'download', tag, '--repo', 'yangshiqi/ZackEyes-release', '--dir', str(previous)]
        for name in [f'zackeyes-remote-{old_version}-{p}.tar.gz' for p in verifier.PLATFORMS] + ['SHA256SUMS', 'install-remote.sh']:
            command += ['--pattern', name]
        subprocess.run(command, check=True, capture_output=True, timeout=300)
        repackage(previous, old_version, version, source_sha, output, fingerprint, TOOLS / 'install-remote.sh')
    print(f'Reused verified helper binaries from {tag}; repackaged for {version} without native compilation.')

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('version')
    parser.add_argument('source_sha')
    parser.add_argument('output', type=Path)
    parser.add_argument('--source', type=Path, default=TOOLS.parent)
    args = parser.parse_args()
    if args.output.exists():
        parser.error('Output already exists')
    try:
        reuse_latest(args.version, args.source_sha, args.output, args.source)
    except (ValueError, OSError, KeyError, TypeError, tarfile.TarError, subprocess.SubprocessError) as error:
        detail = getattr(error, 'stderr', None)
        if isinstance(detail, bytes):
            detail = detail.decode('utf-8', errors='replace')
        detail = (detail or str(error)).strip() or str(error)
        print(f'Reuse check failed: {type(error).__name__}: {detail}', file=sys.stderr)
        print('Published helper reuse unavailable or inputs changed; a fresh native build is required.')
        sys.exit(2)
