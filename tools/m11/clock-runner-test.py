#!/usr/bin/env python3
"""Portable runner exit tests with real fake children; no Swift/compiler or UI runs."""
import json
import importlib.util
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]


def temporary_directory():
    # MBA cleanup stays inside this job's own item, including fake shell trees.
    item = os.environ.get('OC_ITEM_DIR')
    directory = Path(item)/'copy' if item else None
    if directory:
        directory.mkdir(parents=True, exist_ok=True)
    return tempfile.TemporaryDirectory(dir=directory)


WRAPPER = r'''
import json, os, runpy, subprocess, sys
from pathlib import Path
from unittest.mock import patch
root, runner, output, child, code, report = sys.argv[1:]
output = Path(output)
real_popen = subprocess.Popen
def compile_stub(command, **kwargs):
    Path(command[-1]).write_bytes(b'fake compiler output; no compiler executed')
    return subprocess.CompletedProcess(command, 0)
def child_process(command, **kwargs):
    kwargs.pop('start_new_session', None)
    # The probe is mocked; the real fake child must not load the dummy dylib.
    kwargs['env'] = dict(kwargs['env'])
    kwargs['env'].pop('DYLD_INSERT_LIBRARIES', None)
    return real_popen([sys.executable, child, command[-1], code, report], **kwargs)
def probe(command, **kwargs):
    env = kwargs['env']
    value = env.get('UPTIME_MEDIA_ORIGIN', env.get('SPLIT_FAKE_MEDIA_TIME', '123'))
    return value + ' ' + value if runner == 'verify-uptime-clocks.py' else value
def probe_run(command, **kwargs):
    return subprocess.CompletedProcess(command, 0, stdout=probe(command, **kwargs))
def run_stub(command, **kwargs):
    return probe_run(command, **kwargs) if command[0].endswith('probe') else compile_stub(command, **kwargs)
sys.argv = [str(Path(root)/'scripts'/runner), sys.executable, str(output)]
if runner == 'verify-uptime-clocks.py': sys.argv += ['--suite', 'fake']
with patch.object(subprocess, 'run', side_effect=run_stub), \
     patch.object(subprocess, 'Popen', side_effect=child_process), \
     patch.object(subprocess, 'check_output', side_effect=probe), \
     patch.object(os, 'getloadavg', return_value=(0, 0, 0), create=True):
    runpy.run_path(sys.argv[0], run_name='__main__')
'''
CHILD = '''import json, sys
from pathlib import Path
out, code, report = sys.argv[1:]
if report == 'yes':
    directory = Path(out)
    (directory/'report.json').write_text(json.dumps({'checks':357,'failures':[],'measurements':[]}))
    (directory/'fake.png').write_bytes(b'fake fixture PNG')
print('fake child exit', code)
raise SystemExit(int(code))
'''


class ClockExitTests(unittest.TestCase):
    def invoke(self, runner, code, report='no'):
        temporary = temporary_directory()
        self.addCleanup(temporary.cleanup)
        directory = Path(temporary.name)
        wrapper, child = directory/'wrapper.py', directory/'child.py'
        wrapper.write_bytes(WRAPPER.encode())
        child.write_bytes(CHILD.encode())
        output = directory/'out'
        result = subprocess.run([sys.executable, str(wrapper), str(ROOT), runner,
                                 str(output), str(child), str(code), report],
                                text=True, capture_output=True)
        return result, output

    def test_uptime_real_children_exit_one_fail_outer_and_name_every_run(self):
        result, output = self.invoke('verify-uptime-clocks.py', 1)
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        last = result.stdout.splitlines()[-1]
        for name in ['real', 'small', 'large']:
            self.assertIn(name + ' exit 1', last)
        rows = json.loads((output/'environment.json').read_text())['runs']
        self.assertEqual([row['exitCode'] for row in rows], [1, 1, 1])

    def test_uptime_zero_children_preserve_success(self):
        result, _ = self.invoke('verify-uptime-clocks.py', 0)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_split_missing_report_preserves_child_exit(self):
        result, output = self.invoke('verify-split-environment.py', 1)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('current exit 1; missing report.json', result.stdout.splitlines()[-1])
        self.assertNotIn('Traceback', result.stderr)
        self.assertEqual(json.loads((output/'current/process.json').read_text())['exitCode'], 1)

    def test_split_child_failure_even_with_passing_report_fails_outer(self):
        result, _ = self.invoke('verify-split-environment.py', 1, 'yes')
        self.assertNotEqual(result.returncode, 0)
        for name in ['current', 'afternoon', 'evening']:
            self.assertIn(name + ' exit 1', result.stdout.splitlines()[-1])

    def test_split_zero_children_and_matching_reports_pass(self):
        result, _ = self.invoke('verify-split-environment.py', 0, 'yes')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


class FixedBundleTests(unittest.TestCase):
    def setUp(self):
        spec = importlib.util.spec_from_file_location('fixed_bundle_builder', ROOT/'scripts/build-uptime-harness.py')
        self.builder = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.builder)

    def fixture(self):
        temporary = temporary_directory()
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        release = root/'release'
        release.mkdir()
        compiled = release/'Check'
        compiled.write_bytes(b'fake executable')
        bundle = release/'M111Check_OrganicBodyResources.bundle'
        (bundle/'Bodies').mkdir(parents=True)
        (bundle/'Bodies/catalogue.json').write_bytes(b'fake catalogue')
        package = root/'package'
        package.mkdir()
        return compiled, bundle, package/'fixed/Check'

    def test_fixed_copy_keeps_binary_and_entire_named_bundle(self):
        compiled, bundle, fixed = self.fixture()
        self.builder.copy_fixed_binary(compiled, fixed)
        self.assertEqual(fixed.read_bytes(), compiled.read_bytes())
        self.assertEqual((fixed.parent/bundle.name/'Bodies/catalogue.json').read_bytes(), b'fake catalogue')
        self.assertEqual((bundle/'Bodies/catalogue.json').read_bytes(), b'fake catalogue')
        receipt = json.loads((fixed.parent.parent/'fixed-bundle.json').read_text())
        self.assertEqual(receipt['resourceFiles'], 1)
        self.assertEqual(Path(receipt['destination']), fixed.parent/bundle.name)

    def test_repeated_placement_removes_stale_resource_files(self):
        compiled, bundle, fixed = self.fixture()
        self.builder.copy_fixed_binary(compiled, fixed)
        stale = fixed.parent/bundle.name/'stale'
        stale.write_bytes(b'old resource')
        self.builder.copy_fixed_binary(compiled, fixed)
        self.assertFalse(stale.exists())
        self.assertTrue((bundle/'Bodies/catalogue.json').is_file())

    def test_missing_bundle_fails_before_publishing_fixed_binary(self):
        compiled, bundle, fixed = self.fixture()
        self.assertEqual(bundle.resolve().parent, compiled.parent.resolve())
        shutil.rmtree(bundle)
        with self.assertRaisesRegex(FileNotFoundError, 'Expected one built OrganicBodyResources bundle'):
            self.builder.copy_fixed_binary(compiled, fixed)
        self.assertFalse(fixed.exists())


@unittest.skipUnless(shutil.which('zsh'), 'zsh shell checks run on MBA/CI')
class ShellExitTests(unittest.TestCase):
    def test_filtered_build_failures_propagate_without_launching_windows(self):
        for runner in ['errors.sh', 'swapcheck.sh']:
            for code in [0, 7]:
                if runner == 'swapcheck.sh' and code == 0:
                    continue  # Success intentionally enters its real-window workflow.
                with self.subTest(runner=runner, code=code), temporary_directory() as temporary:
                    root = Path(temporary)
                    (root/'scripts').mkdir()
                    (root/'bin').mkdir()
                    shutil.copy2(ROOT/'scripts'/runner, root/'scripts'/runner)
                    script = root/'scripts'/runner
                    script.write_bytes(script.read_bytes().replace(b'/usr/bin/open', b'open'))
                    message = '/fake/failure.swift:1:1: error: fake compiler' if code else 'Build complete!'
                    fake = '#!/bin/zsh\necho ' + message + '\nexit ' + str(code) + '\n'
                    if runner == 'errors.sh':
                        target = root/'bin/swift'
                    else:
                        (root/'tools/movdiff').mkdir(parents=True)
                        (root/'tools/movdiff/movdiff').write_bytes(b'#!/bin/zsh\nexit 0\n')
                        (root/'tools/movdiff/movdiff').chmod(0o755)
                        target = root/'scripts/claude-build.sh'
                    target.write_bytes(fake.encode())
                    target.chmod(0o755)
                    for command in ['open', 'pgrep']:
                        forbidden = root/'bin'/command
                        forbidden.write_bytes(b'#!/bin/zsh\ntouch "$0.called"\nexit 99\n')
                        forbidden.chmod(0o755)
                    result = subprocess.run(['zsh', str(root/'scripts'/runner)],
                                            env=dict(os.environ, PATH=str(root/'bin')+os.pathsep+os.environ['PATH']),
                                            capture_output=True, text=True)
                    self.assertEqual(result.returncode, code, result.stdout + result.stderr)
                    self.assertFalse(list((root/'bin').glob('*.called')))


if __name__ == '__main__':
    unittest.main()
