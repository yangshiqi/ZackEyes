"""Release gates: incomplete, stale or corrupted helper sets must never ship."""
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('verify', ROOT / 'Scripts/verify-remote-assets.py')
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

class BundleTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='zackeyes-bundle-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.sha = 'a' * 40
        for platform in module.PLATFORMS:
            self.package(platform)
        (self.root / 'install-remote.sh').write_text('#!/bin/sh\n')
        self.checksums()

    def package(self, platform, source=None, machine=None):
        name = f'zackeyes-remote-0.10.0-{platform}.tar.gz'
        binary = bytearray(64)
        if platform.startswith('linux'):
            binary[:5] = b'\x7fELF\x02'
            binary[18:20] = (machine or (62 if platform.endswith('x86_64') else 183)).to_bytes(2, 'little')
        else:
            binary[:4] = b'\xcf\xfa\xed\xfe'
            binary[4:8] = (machine or (0x1000007 if platform.endswith('x86_64') else 0x100000c)).to_bytes(4, 'little')
        with tarfile.open(self.root / name, 'w:gz') as archive:
            for name, data in [('zackeyes', binary), ('build-info.json', json.dumps({'version': '0.10.0', 'platform': platform, 'source_sha': source or self.sha}).encode())]:
                item = tarfile.TarInfo(name)
                item.size = len(data)
                archive.addfile(item, io.BytesIO(data))

    def checksums(self):
        paths = sorted(self.root.glob('*.tar.gz')) + [self.root / 'install-remote.sh']
        (self.root / 'SHA256SUMS').write_text(''.join(f'{hashlib.sha256(p.read_bytes()).hexdigest()}  {p.name}\n' for p in paths))

    def verify(self):
        return module.verify(self.root, '0.10.0', self.sha)

    def test_accepts_complete_version_matched_set(self):
        self.assertEqual(len(self.verify()), 5)

    def test_rejects_missing_platform(self):
        next(self.root.glob('*linux-arm64*')).unlink()
        self.checksums()
        with self.assertRaises(ValueError): self.verify()

    def test_rejects_other_source_even_with_valid_checksum(self):
        self.package('macos-arm64', source='b' * 40)
        self.checksums()
        with self.assertRaises(ValueError): self.verify()

    def test_rejects_wrong_architecture_even_with_valid_checksum(self):
        self.package('linux-arm64', machine=62)
        self.checksums()
        with self.assertRaises(ValueError): self.verify()

    def test_rejects_download_corruption(self):
        (self.root / 'install-remote.sh').write_text('changed')
        with self.assertRaises(ValueError): self.verify()

if __name__ == '__main__': unittest.main()
