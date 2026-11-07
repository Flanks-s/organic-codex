#!/usr/bin/env python3
"""M10-B: isolated AppKit/CA program, never the app. All children finish before this script exits."""
import argparse
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import shutil

repo = Path(__file__).resolve().parents[3]
parser = argparse.ArgumentParser()
parser.add_argument('--output', type=Path, default=repo / 'runs/m10-overlay')
parser.add_argument('--skip-compile', action='store_true')
args = parser.parse_args()
output = args.output.resolve()
output.mkdir(parents=True, exist_ok=True)
binary = Path('/tmp/sol-m10-overlay-check')
if not args.skip_compile:
    source = repo / 'Sources/OrganicShell'
    # Other tasks edit Native concurrently: freeze read-only inputs, never compile a half-written later revision.
    with tempfile.TemporaryDirectory(prefix='sol-m10-overlay-inputs-') as tmp:
        files = []
        for group in ['Engine', 'Core', 'Native', 'Overlay']:
            target = Path(tmp) / group
            target.mkdir()
            for p in sorted((source / group).glob('*.swift')):
                if p.name != 'CoreSettingsController.swift':
                    q = target / p.name
                    shutil.copy2(p, q)
                    files.append(str(q))
        with (output / 'compile.log').open('w') as log:
            result = subprocess.run(['swiftc', '-swift-version', '6', '-O', '-D', 'OVERLAY_SELFTEST',
                                     '-target', 'arm64-apple-macosx26.0', *files, '-o', str(binary)],
                                    cwd=repo, stdout=log, stderr=subprocess.STDOUT)
    if result.returncode:
        print((output / 'compile.log').read_text()[-16000:])
        sys.exit(result.returncode)
env = dict(os.environ, M10_FRAMES='1')
sys.exit(subprocess.run([str(binary), str(output)], cwd=repo, env=env).returncode)
