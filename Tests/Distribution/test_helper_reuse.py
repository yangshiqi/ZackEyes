"""Unchanged published SSH binaries can be reused, with full provenance."""
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]

def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, ROOT / 'Scripts' / filename)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module

class HelperReuseTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='zackeyes-helper-reuse-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.source = self.root / 'source'
        self.source.mkdir()
        self.inputs = load('helper_inputs', 'remote-helper-inputs.py')
        self.reuse = load('helper_reuse', 'reuse-remote-assets.py')
        self.verify = load('helper_verify', 'verify-remote-assets.py')
        for directory in ['Sources/RemoteCore', 'Sources/RemoteStream', 'Tests/RemoteCoreTests']:
            path = self.source / directory
            path.mkdir(parents=True)
            (path / 'Fixture.swift').write_text('// original\n')
        (self.source / 'Package.swift').write_text('// package\n')
        subprocess.run(['git', 'init', '-q', str(self.source)], check=True)
        self.env = dict(os.environ, GIT_AUTHOR_NAME='Fixture', GIT_AUTHOR_EMAIL='fixture@example.test',
                        GIT_COMMITTER_NAME='Fixture', GIT_COMMITTER_EMAIL='fixture@example.test')
        self.old_sha = self.commit()
        self.key = self.inputs.fingerprint(self.source, self.old_sha, ROOT)
        self.old = self.root / 'published'
        self.old.mkdir()
        for platform in self.verify.PLATFORMS:
            self.package(platform)
        (self.old / 'install-remote.sh').write_text('previous installer')
        self.checksums()

    def commit(self):
        subprocess.run(['git', '-C', str(self.source), 'add', '.'], check=True)
        subprocess.run(['git', '-C', str(self.source), 'commit', '-qm', 'fixture', '--allow-empty'], env=self.env, check=True)
        return subprocess.check_output(['git', '-C', str(self.source), 'rev-parse', 'HEAD'], text=True).strip()

    def package(self, platform, key='default', compiled=None):
        binary = bytearray(128)
        if platform.startswith('linux'):
            binary[:5] = b'\x7fELF\x02'
            binary[18:20] = (62 if platform.endswith('x86_64') else 183).to_bytes(2, 'little')
        else:
            binary[:4] = b'\xcf\xfa\xed\xfe'
            binary[4:8] = (0x1000007 if platform.endswith('x86_64') else 0x100000c).to_bytes(4, 'little')
        metadata = dict(version='0.10.2', platform=platform, source_sha=self.old_sha)
        if key is not None:
            metadata.update(helper_inputs_sha256=self.key if key == 'default' else key,
                            compiled_source_sha=compiled or self.old_sha)
        with tarfile.open(self.old / f'zackeyes-remote-0.10.2-{platform}.tar.gz', 'w:gz') as archive:
            for name, data in [('zackeyes', bytes(binary)), ('build-info.json', json.dumps(metadata).encode())]:
                info = tarfile.TarInfo(name)
                info.size, info.mode = len(data), 0o755 if name == 'zackeyes' else 0o644
                archive.addfile(info, io.BytesIO(data))

    def checksums(self):
        files = sorted(self.old.glob('*.tar.gz')) + [self.old / 'install-remote.sh']
        (self.old / 'SHA256SUMS').write_text(''.join(f'{hashlib.sha256(p.read_bytes()).hexdigest()}  {p.name}\n' for p in files))

    def test_ui_change_reuses_bytes_and_keeps_original_compiled_source(self):
        (self.source / 'UI.swift').write_text('// app changed')
        new_sha = self.commit()
        self.assertEqual(self.key, self.inputs.fingerprint(self.source, new_sha, ROOT))
        output = self.root / 'output'
        self.reuse.repackage(self.old, '0.10.2', '0.10.3', new_sha, output,
                             self.inputs.fingerprint(self.source, new_sha, ROOT), ROOT / 'Scripts/install-remote.sh')
        self.verify.verify(output, '0.10.3', new_sha, self.key)
        for platform in self.verify.PLATFORMS:
            with tarfile.open(output / f'zackeyes-remote-0.10.3-{platform}.tar.gz') as archive:
                info = json.load(archive.extractfile('build-info.json'))
                self.assertEqual(info['compiled_source_sha'], self.old_sha)
                self.assertEqual(info['source_sha'], new_sha)
                reused = archive.extractfile('zackeyes').read()
            with tarfile.open(self.old / f'zackeyes-remote-0.10.2-{platform}.tar.gz') as archive:
                self.assertEqual(reused, archive.extractfile('zackeyes').read())
        self.assertEqual((output / 'install-remote.sh').read_bytes(), (ROOT / 'Scripts/install-remote.sh').read_bytes())

    def test_all_helper_source_and_test_inputs_invalidate_reuse(self):
        for name in ['Sources/RemoteCore/Fixture.swift', 'Sources/RemoteStream/Fixture.swift',
                     'Tests/RemoteCoreTests/Fixture.swift', 'Package.swift', 'Package.resolved']:
            with self.subTest(name=name):
                path = self.source / name
                path.write_text('// changed')
                sha = self.commit()
                self.assertNotEqual(self.key, self.inputs.fingerprint(self.source, sha, ROOT))
                subprocess.run(['git', '-C', str(self.source), 'reset', '--hard', self.old_sha], check=True, capture_output=True)

    def test_legacy_missing_platform_corruption_or_changed_inputs_leave_no_output(self):
        for variant in ['legacy', 'missing', 'corrupt', 'changed']:
            with self.subTest(variant=variant):
                work = self.root / variant
                shutil.copytree(self.old, work)
                asset = next(work.glob('*linux-arm64*'))
                if variant == 'legacy':
                    self.package('linux-arm64', key=None)
                    shutil.copyfile(next(self.old.glob('*linux-arm64*')), asset)
                    self.checksums()
                    shutil.copyfile(self.old / 'SHA256SUMS', work / 'SHA256SUMS')
                    self.package('linux-arm64')
                    self.checksums()
                elif variant == 'missing': asset.unlink()
                elif variant == 'corrupt': asset.write_bytes(b'corrupt')
                output = self.root / ('out-' + variant)
                with self.assertRaises((ValueError, OSError)):
                    self.reuse.repackage(work, '0.10.2', '0.10.3', self.old_sha, output,
                                         'b' * 64 if variant == 'changed' else self.key,
                                         ROOT / 'Scripts/install-remote.sh')
                self.assertFalse(output.exists())


    def test_fingerprint_handles_container_checkout_ownership_without_global_trust(self):
        foreign = {'GIT_TEST_ASSUME_DIFFERENT_OWNER': '1', 'GIT_CONFIG_COUNT': '1',
                   'GIT_CONFIG_KEY_0': 'safe.directory', 'GIT_CONFIG_VALUE_0': ''}
        with patch.dict(os.environ, foreign):
            rejected = subprocess.run(['git', '-C', str(self.source), 'ls-tree', self.old_sha],
                                      text=True, capture_output=True)
            self.assertNotEqual(rejected.returncode, 0)
            self.assertIn('dubious ownership', rejected.stderr)
            self.assertEqual(self.key, self.inputs.fingerprint(self.source, self.old_sha, ROOT))

    def test_build_recipes_and_toolchain_changes_invalidate_reuse(self):
        tools = self.root / 'tools-copy'
        for name in self.inputs.RECIPE_PATHS:
            path = tools / name
            path.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / name, path)
        self.assertEqual(self.key, self.inputs.fingerprint(self.source, self.old_sha, tools))
        for name in self.inputs.RECIPE_PATHS:
            with self.subTest(name=name):
                path = tools / name
                before = path.read_bytes()
                path.write_bytes(before + b'\n# build input changed\n')
                self.assertNotEqual(self.key, self.inputs.fingerprint(self.source, self.old_sha, tools))
                path.write_bytes(before)

    def test_repeated_reuse_preserves_the_original_compilation_commit(self):
        first = self.root / 'first'
        second = self.root / 'second'
        self.reuse.repackage(self.old, '0.10.2', '0.10.3', 'c' * 40, first, self.key, ROOT / 'Scripts/install-remote.sh')
        self.reuse.repackage(first, '0.10.3', '0.10.4', 'd' * 40, second, self.key, ROOT / 'Scripts/install-remote.sh')
        self.verify.verify(second, '0.10.4', 'd' * 40, self.key)
        info = self.reuse.package_info(next(second.glob('*linux-arm64*')))
        self.assertEqual(info['compiled_source_sha'], self.old_sha)
        self.assertEqual(info['source_sha'], 'd' * 40)

    def test_existing_output_is_preserved(self):
        output = self.root / 'existing'
        output.mkdir()
        (output / 'keep').write_text('existing')
        with self.assertRaises(ValueError):
            self.reuse.repackage(self.old, '0.10.2', '0.10.3', self.old_sha, output, self.key, ROOT / 'Scripts/install-remote.sh')
        self.assertEqual((output / 'keep').read_text(), 'existing')

    def configure_fetch(self):
        shutil.copytree(ROOT / 'Scripts', self.source / 'Scripts', ignore=shutil.ignore_patterns('__pycache__', '*.pyc'))
        workflow = self.source / '.github/workflows/remote-helpers.yml'
        workflow.parent.mkdir(parents=True)
        shutil.copyfile(ROOT / '.github/workflows/remote-helpers.yml', workflow)
        target_sha = self.commit()
        native = self.root / 'native'
        native.mkdir()
        for platform in self.verify.PLATFORMS:
            old = self.old / f'zackeyes-remote-0.10.2-{platform}.tar.gz'
            with tarfile.open(old) as archive:
                binary = archive.extractfile('zackeyes').read()
            metadata = dict(version='0.10.3', platform=platform, source_sha=target_sha,
                            compiled_source_sha=target_sha, helper_inputs_sha256=self.key)
            with tarfile.open(native / f'zackeyes-remote-0.10.3-{platform}.tar.gz', 'w:gz') as archive:
                for name, data in [('zackeyes', binary), ('build-info.json', json.dumps(metadata).encode())]:
                    item = tarfile.TarInfo(name)
                    item.size, item.mode = len(data), 0o755 if name == 'zackeyes' else 0o644
                    archive.addfile(item, io.BytesIO(data))
        shutil.copyfile(ROOT / 'Scripts/install-remote.sh', native / 'install-remote.sh')
        (native / 'SHA256SUMS').write_text(''.join(f'{hashlib.sha256(p.read_bytes()).hexdigest()}  {p.name}\n'
            for p in sorted(native.iterdir())))
        executables = self.root / 'executables'
        executables.mkdir()
        fake = executables / 'gh'
        fake.write_text('#!' + sys.executable + '\n' + r'''
import json, os, pathlib, shutil, sys
args = sys.argv[1:]
with open(os.environ['FAKE_LOG'], 'a') as log: log.write(json.dumps(args) + '\n')
marker = pathlib.Path(os.environ['FAKE_MARKER'])
if args[:2] == ['release', 'view']:
    if os.environ.get('FAKE_NO_RELEASE') == '1': sys.exit(1)
    print(json.dumps(dict(tagName='v0.10.2', isDraft=False, isPrerelease=False)))
elif args[:2] == ['release', 'download'] or args[:2] == ['run', 'download']:
    source = pathlib.Path(os.environ['FAKE_OLD'] if args[0] == 'release' else os.environ['FAKE_NATIVE'])
    destination = pathlib.Path(args[args.index('--dir') + 1])
    destination.mkdir(parents=True, exist_ok=True)
    for file in source.iterdir(): shutil.copyfile(file, destination / file.name)
elif args[:2] == ['api', 'user']: print(os.environ.get('FAKE_LOGIN', 'yangshiqi'))
elif args[:2] == ['auth', 'switch']: sys.exit(1)
elif args[:2] == ['workflow', 'run']: marker.write_text('dispatched')
elif args[:2] == ['run', 'list']:
    print(json.dumps([dict(databaseId=42, displayTitle='Remote helpers 0.10.3 from ' + os.environ['FAKE_SHA'])] if marker.exists() else []))
elif args[:2] == ['run', 'watch']: pass
else: sys.exit(99)
''')
        fake.chmod(0o755)
        env = dict(os.environ, PATH=str(executables) + os.pathsep + os.environ['PATH'],
                   FAKE_LOG=str(self.root / 'gh.log'), FAKE_MARKER=str(self.root / 'dispatch'),
                   FAKE_OLD=str(self.old), FAKE_NATIVE=str(native), FAKE_SHA=target_sha,
                   REMOTE_HELPERS_FORCE_REBUILD='0')
        return target_sha, env

    def run_fetch(self, env):
        output = self.root / 'fetched'
        result = subprocess.run(['bash', str(self.source / 'Scripts/fetch-remote-assets.sh'),
            '0.10.3', env['FAKE_SHA'], str(output)], cwd=self.source, env=env, text=True, capture_output=True)
        calls = [json.loads(line) for line in (self.root / 'gh.log').read_text().splitlines()]
        return result, output, calls

    def test_real_fetch_entry_reuses_without_workflow_dispatch(self):
        sha, env = self.configure_fetch()
        result, output, calls = self.run_fetch(env)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.verify.verify(output, '0.10.3', sha, self.key)
        self.assertFalse(any(call[:2] == ['workflow', 'run'] for call in calls))
        self.assertIn('without native compilation', result.stdout)

    def test_force_rebuild_skips_published_reuse_and_dispatches_exact_source(self):
        sha, env = self.configure_fetch()
        env['REMOTE_HELPERS_FORCE_REBUILD'] = '1'
        result, output, calls = self.run_fetch(env)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.verify.verify(output, '0.10.3', sha, self.key)
        self.assertFalse(any(call[0] == 'release' for call in calls))
        dispatch = next(call for call in calls if call[:2] == ['workflow', 'run'])
        self.assertIn('source_ref=' + sha, dispatch)

    def test_corrupt_published_set_falls_back_to_verified_native_bundle(self):
        sha, env = self.configure_fetch()
        next(self.old.glob('*linux-arm64*')).write_bytes(b'corrupt')
        result, output, calls = self.run_fetch(env)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.verify.verify(output, '0.10.3', sha, self.key)
        self.assertTrue(any(call[:2] == ['workflow', 'run'] for call in calls))

    def test_no_published_release_falls_back(self):
        sha, env = self.configure_fetch()
        env['FAKE_NO_RELEASE'] = '1'
        result, output, calls = self.run_fetch(env)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.verify.verify(output, '0.10.3', sha, self.key)
        self.assertTrue(any(call[:2] == ['workflow', 'run'] for call in calls))

    def test_wrong_github_identity_never_dispatches(self):
        _, env = self.configure_fetch()
        env.update(FAKE_NO_RELEASE='1', FAKE_LOGIN='someone-else')
        result, output, calls = self.run_fetch(env)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(output.exists())
        self.assertFalse(any(call[:2] == ['workflow', 'run'] for call in calls))

if __name__ == '__main__': unittest.main()
