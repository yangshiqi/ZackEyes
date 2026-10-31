#!/usr/bin/env python3
"""Fingerprint the SSH implementation and actual native build recipes, not app UI."""
import argparse
import hashlib
import fnmatch
from pathlib import Path
import re
import subprocess

SOURCE_PATHS = ('Sources/RemoteCore', 'Sources/RemoteStream', 'Sources/AppLib/Remote',
                'Tests/RemoteCoreTests', 'Package*.swift', 'Package.resolved', '.swift-version')
RECIPE_PATHS = ('Scripts/build-remote-helper.sh', 'Scripts/package-remote-helper.py',
                'Scripts/smoke-remote-helper.py', 'Scripts/remote-helper-inputs.py',
                '.github/workflows/remote-helpers.yml')

def fingerprint(source, source_sha, tools=None):
    if not re.fullmatch(r'[0-9a-f]{40}', source_sha):
        raise ValueError('Expected a full source commit SHA')
    tools = Path(tools) if tools else Path(__file__).resolve().parents[1]
    source = Path(source).resolve()
    tree = subprocess.check_output(['git', '-c', 'safe.directory=' + str(source), '-C', str(source), 'ls-tree', '-rz', source_sha])
    entries = []
    for row in tree.split(b'\0'):
        if not row:
            continue
        info, name = row.split(b'\t', 1)
        path = name.decode('utf-8', errors='surrogateescape')
        if not any(fnmatch.fnmatchcase(path, pattern) or path.startswith(pattern + '/') for pattern in SOURCE_PATHS):
            continue
        mode, kind, digest = info.split()
        if kind != b'blob' or mode not in (b'100644', b'100755'):
            raise ValueError('Helper inputs must be tracked regular files')
        entries.append((name, mode + b' ' + digest))
    for required in (b'Package.swift', b'Sources/RemoteCore/', b'Sources/RemoteStream/'):
        if not any(name == required or name.startswith(required) for name, _ in entries):
            raise ValueError('Missing helper source inputs')
    result = hashlib.sha256(b'zackeyes-helper-inputs-v1\0')
    for name, digest in sorted(entries):
        result.update(b'source\0' + name + b'\0' + digest + b'\0')
    for name in RECIPE_PATHS:
        path = tools / name
        if path.is_symlink() or not path.is_file():
            raise ValueError('Missing or linked helper build recipe')
        result.update(b'recipe\0' + name.encode() + b'\0' + hashlib.sha256(path.read_bytes()).digest())
    return result.hexdigest()

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path)
    parser.add_argument('source_sha')
    args = parser.parse_args()
    print(fingerprint(args.source, args.source_sha))
