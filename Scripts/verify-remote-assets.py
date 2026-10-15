#!/usr/bin/env python3
"""Fail closed unless every helper package has the requested version/source/hash."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import tarfile

PLATFORMS = ('linux-x86_64', 'linux-arm64', 'macos-x86_64', 'macos-arm64')

def verify(directory, version, source_sha):
    if not re.fullmatch(r'\d+\.\d+\.\d+', version) or not re.fullmatch(r'[0-9a-f]{40}', source_sha):
        raise ValueError('Expected X.Y.Z and full source SHA')
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
        if hashlib.sha256((directory / name).read_bytes()).hexdigest() != entries[name]:
            raise ValueError(f'Checksum mismatch: {name}')
    for platform, name in zip(PLATFORMS, names):
        with tarfile.open(directory / name) as archive:
            members = archive.getmembers()
            if sorted(m.name for m in members) != ['build-info.json', 'zackeyes'] or not all(m.isfile() for m in members):
                raise ValueError(f'Invalid archive members: {name}')
            info = json.load(archive.extractfile('build-info.json'))
            if info != {'version': version, 'platform': platform, 'source_sha': source_sha}:
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
    args = parser.parse_args()
    verify(args.directory, args.version, args.source_sha)
    print('PASS all four helper packages: version, source SHA, architecture and SHA256')
