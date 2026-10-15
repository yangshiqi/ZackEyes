#!/usr/bin/env python3
"""Run on the target architecture, without any Swift toolchain in PATH."""
import json
import os
from pathlib import Path
import selectors
import subprocess
import sys

binary = str(Path(sys.argv[1]).resolve())
env = dict(os.environ, PATH='/usr/bin:/bin')
help_text = subprocess.check_output([binary, '--help'], env=env, text=True, timeout=10)
assert 'zackeyes --stream' in help_text
process = subprocess.Popen([binary, '--stream'], stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
try:
    with selectors.DefaultSelector() as selector:
        selector.register(process.stdout, selectors.EVENT_READ)
        assert selector.select(timeout=15), 'No initial snapshot'
        frame = process.stdout.readline(1_048_577)
        assert len(frame) <= 1_048_576 and frame.endswith(b'\n'), 'Invalid snapshot framing'
        snapshot = json.loads(frame)
        assert snapshot['version'] == 1 and isinstance(snapshot['sessions'], list)
finally:
    process.terminate()
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait()
        raise
    process.stdout.close()
    process.stderr.close()
assert process.returncode == 0, 'Helper did not stop cleanly'
print('PASS native helper --help, protocol-v1 snapshot and clean shutdown')
