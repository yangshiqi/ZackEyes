#!/usr/bin/env python3
"""Fail closed unless every helper package has the requested version/source/hash."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import tarfile

PLATFORMS = ('linux-x86_64', 'linux-arm64', 'macos-x86_64', 'macos-arm64')

def file_hash(path):
    result = hashlib.sha256()
    with path.open('rb') as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b''):
            result.update(chunk)
    return result.hexdigest()

def verify(directory, version, source_sha, helper_inputs_sha256=None):
    if not re.fullmatch(r'\d+\.\d+\.\d+', version) or not re.fullmatch(r'[0-9a-f]{40}', source_sha):
        raise ValueError('Expected X.Y.Z and full source SHA')
    if helper_inputs_sha256 is not None and not re.fullmatch(r'[0-9a-f]{64}', helper_inputs_sha256):
        raise ValueError('Invalid expected helper fingerprint')
    names = [f'zackeyes-remote-{version}-{platform}.tar.gz' for platform in PLATFORMS]
    names += ['install-remote.sh']
    entries = {}
    for line in (directory / 'SHA256SUMS').read_text().splitlines():
        digest, name = line.split()
        if name in entries or not re.fullmatch(r'[0-9a-f]{64}', digest):
            raise ValueError('Invalid or duplicate checksum')
        entries[name] = digest
    if set(entries) != set(names):
        raise ValueError('Missing platform or unexpected checksum entry')
    for name in names:
        if file_hash(directory / name) != entries[name]:
            raise ValueError(f'Checksum mismatch: {name}')
    for platform, name in zip(PLATFORMS, names):
        with tarfile.open(directory / name) as archive:
            members = archive.getmembers()
            if sorted(m.name for m in members) != ['build-info.json', 'zackeyes'] or not all(m.isfile() for m in members):
                raise ValueError(f'Invalid archive members: {name}')
            if archive.getmember('build-info.json').size > 16384 or archive.getmember('zackeyes').size > 512 * 1024 * 1024:
                raise ValueError(f'Oversized helper package: {name}')
            info = json.load(archive.extractfile('build-info.json'))
            if not isinstance(info, dict):
                raise ValueError(f'Invalid package metadata: {name}')
            expected = {'version': version, 'platform': platform, 'source_sha': source_sha}
            provenance = {'compiled_source_sha', 'helper_inputs_sha256'}
            if provenance.intersection(info):
                if not provenance.issubset(info) or not re.fullmatch(r'[0-9a-f]{40}', str(info['compiled_source_sha'])) \
                        or not re.fullmatch(r'[0-9a-f]{64}', str(info['helper_inputs_sha256'])):
                    raise ValueError(f'Invalid compiled provenance: {name}')
                expected.update({key: info[key] for key in provenance})
            if helper_inputs_sha256 is not None and info.get('helper_inputs_sha256') != helper_inputs_sha256:
                raise ValueError(f'Wrong helper build inputs: {name}')
            if info != expected:
                raise ValueError(f'Wrong source/version/platform: {name}')
            binary = archive.extractfile('zackeyes').read(64)
            if platform.startswith('linux'):
                machine = int.from_bytes(binary[18:20], 'little')
                if binary[:5] != b'\x7fELF\x02' or machine != (62 if platform.endswith('x86_64') else 183):
                    raise ValueError(f'Wrong ELF architecture: {name}')
            else:
                cpu = int.from_bytes(binary[4:8], 'little')
                if binary[:4] != b'\xcf\xfa\xed\xfe' or cpu != (0x1000007 if platform.endswith('x86_64') else 0x100000c):
                    raise ValueError(f'Wrong Mach-O architecture: {name}')
    return names

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('version')
    parser.add_argument('source_sha')
    parser.add_argument('directory', type=Path)
    parser.add_argument('--helper-inputs-sha256')
    args = parser.parse_args()
    verify(args.directory, args.version, args.source_sha, args.helper_inputs_sha256)
    print('PASS all four helper packages: version, source SHA, architecture and SHA256')
