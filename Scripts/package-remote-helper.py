#!/usr/bin/env python3
"""Package only a tested helper and its exact source provenance."""
import argparse
import io
import json
from pathlib import Path
import re
import tarfile

p = argparse.ArgumentParser()
p.add_argument('version')
p.add_argument('platform', choices=['linux-x86_64', 'linux-arm64', 'macos-x86_64', 'macos-arm64'])
p.add_argument('binary', type=Path)
p.add_argument('source_sha')
p.add_argument('output', type=Path)
p.add_argument('--compiled-source-sha')
p.add_argument('--helper-inputs-sha256')
a = p.parse_args()
if not re.fullmatch(r'\d+\.\d+\.\d+', a.version) or not re.fullmatch(r'[0-9a-f]{40}', a.source_sha):
    p.error('Expected X.Y.Z and a full source commit SHA.')
if bool(a.compiled_source_sha) != bool(a.helper_inputs_sha256):
    p.error('Compiled provenance and helper fingerprint must be supplied together.')
if a.compiled_source_sha and (not re.fullmatch(r'[0-9a-f]{40}', a.compiled_source_sha)
                              or not re.fullmatch(r'[0-9a-f]{64}', a.helper_inputs_sha256)):
    p.error('Invalid compiled source SHA or helper fingerprint.')
a.output.mkdir(parents=True, exist_ok=True)
info = {'version': a.version, 'platform': a.platform, 'source_sha': a.source_sha}
if a.compiled_source_sha:
    info.update(compiled_source_sha=a.compiled_source_sha, helper_inputs_sha256=a.helper_inputs_sha256)
metadata = json.dumps(info, sort_keys=True).encode()
archive = a.output / f'zackeyes-remote-{a.version}-{a.platform}.tar.gz'
with tarfile.open(archive, 'w:gz') as tar:
    for name, data, mode in [('zackeyes', a.binary.read_bytes(), 0o755), ('build-info.json', metadata, 0o644)]:
        item = tarfile.TarInfo(name)
        item.size, item.mode, item.mtime = len(data), mode, 0
        tar.addfile(item, io.BytesIO(data))
print(archive)
