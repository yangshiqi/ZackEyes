"""Exercise the real installer with an isolated HTTPS download stub."""
import hashlib
import io
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
INSTALLER = ROOT / 'Scripts/install-remote.sh'

class InstallerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='zackeyes-installer-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.downloads = self.root / 'downloads'
        self.downloads.mkdir()
        self.tools = self.root / 'tools'
        self.tools.mkdir()
        self.prefix = self.root / 'install with spaces'
        self.env = dict(os.environ, PATH=str(self.tools) + os.pathsep + os.environ['PATH'], FIXTURES=str(self.downloads))
        self.tool('uname', '#!/bin/sh\ncase "$1" in -s) echo Linux;; -m) echo x86_64;; esac\n')
        self.tool('curl', '''#!/bin/sh
while [ "$#" -gt 0 ]; do
 case "$1" in --output|-o) output=$2; shift 2;; https://*) url=$1; shift;; *) shift;; esac
done
cp "$FIXTURES/${url##*/}" "$output"
''')
        self.asset = 'zackeyes-remote-0.10.0-linux-x86_64.tar.gz'
        self.package()

    def tool(self, name, content):
        p = self.tools / name
        p.write_text(content)
        p.chmod(0o755)

    def package(self, executable=b'#!/bin/sh\n[ "$1" = --help ] || exit 1\necho "Usage: zackeyes --stream"\n'):
        p = self.downloads / self.asset
        with tarfile.open(p, 'w:gz') as archive:
            info = tarfile.TarInfo('zackeyes')
            info.size = len(executable)
            info.mode = 0o755
            archive.addfile(info, io.BytesIO(executable))
        self.checksum()

    def checksum(self):
        digest = hashlib.sha256((self.downloads / self.asset).read_bytes()).hexdigest()
        (self.downloads / 'SHA256SUMS').write_text(f'{digest}  {self.asset}\n')

    def run_installer(self, version='0.10.0'):
        return subprocess.run(['sh', str(INSTALLER), version, '--prefix', str(self.prefix)], env=self.env, text=True, capture_output=True)

    def existing(self):
        self.prefix.mkdir()
        p = self.prefix / 'zackeyes'
        p.write_text('previous working helper')
        return p

    def test_installs_verified_helper_without_swift(self):
        result = self.run_installer()
        self.assertEqual(result.returncode, 0, result.stderr)
        p = self.prefix / 'zackeyes'
        self.assertTrue(os.access(p, os.X_OK))
        self.assertIn('Usage:', subprocess.check_output([str(p), '--help'], text=True))
        self.assertEqual(list(self.prefix.iterdir()), [p])

    def test_selects_all_supported_platforms(self):
        for system, machine, platform in [('Linux', 'aarch64', 'linux-arm64'), ('Darwin', 'x86_64', 'macos-x86_64'), ('Darwin', 'arm64', 'macos-arm64')]:
            with self.subTest(platform=platform):
                self.tool('uname', f'#!/bin/sh\ncase "$1" in -s) echo {system};; -m) echo {machine};; esac\n')
                self.tool('sw_vers', '#!/bin/sh\necho 14.0\n')
                self.asset = f'zackeyes-remote-0.10.0-{platform}.tar.gz'
                self.package()
                result = self.run_installer()
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn(platform.replace('-', '/'), result.stdout)

    def test_invalid_archive_preserves_existing_helper(self):
        p = self.existing()
        (self.downloads / self.asset).write_bytes(b'not a tar archive')
        self.checksum()
        self.assertNotEqual(self.run_installer().returncode, 0)
        self.assertEqual(p.read_text(), 'previous working helper')

    def test_duplicate_checksum_preserves_existing_helper(self):
        p = self.existing()
        checksums = self.downloads / 'SHA256SUMS'
        checksums.write_text(checksums.read_text() * 2)
        self.assertNotEqual(self.run_installer().returncode, 0)
        self.assertEqual(p.read_text(), 'previous working helper')

    def test_checksum_failure_preserves_existing_helper(self):
        p = self.existing()
        (self.downloads / self.asset).write_bytes(b'corrupt download')
        result = self.run_installer()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('checksum', result.stderr.lower())
        self.assertEqual(p.read_text(), 'previous working helper')

    def test_missing_checksum_preserves_existing_helper(self):
        p = self.existing()
        (self.downloads / 'SHA256SUMS').write_text('')
        self.assertNotEqual(self.run_installer().returncode, 0)
        self.assertEqual(p.read_text(), 'previous working helper')

    def test_incompatible_binary_preserves_existing_helper(self):
        p = self.existing()
        self.package(b'#!/bin/sh\nexit 42\n')
        self.assertNotEqual(self.run_installer().returncode, 0)
        self.assertEqual(p.read_text(), 'previous working helper')

    def test_unsupported_platform_fails_before_download(self):
        self.tool('uname', '#!/bin/sh\necho unsupported\n')
        self.assertNotEqual(self.run_installer().returncode, 0)
        self.assertFalse(self.prefix.exists())

    def test_version_is_required_and_validated(self):
        for version in ['', 'latest', '../other', '0.10.0;echo unsafe']:
            with self.subTest(version=version):
                self.assertNotEqual(self.run_installer(version).returncode, 0)
                self.assertFalse(self.prefix.exists())

    def test_missing_asset_preserves_existing_helper(self):
        p = self.existing()
        (self.downloads / self.asset).unlink()
        self.assertNotEqual(self.run_installer().returncode, 0)
        self.assertEqual(p.read_text(), 'previous working helper')

    def test_does_not_follow_existing_helper_symlink(self):
        target = self.root / 'elsewhere'
        target.write_text('untouched')
        self.prefix.mkdir()
        (self.prefix / 'zackeyes').symlink_to(target)
        self.assertNotEqual(self.run_installer().returncode, 0)
        self.assertEqual(target.read_text(), 'untouched')

if __name__ == '__main__':
    unittest.main()
