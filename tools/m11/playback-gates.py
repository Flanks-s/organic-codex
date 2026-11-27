#!/usr/bin/env python3
"""Windowless Native + M10-A gates in private incremental debug/per-file-O packages.

playback-gates.py SUITE OUT --cache DIR [--compile-only] [--baseline JSON]
Debt #65 round two (decision #181, 11-17): the package is built from the whole product tree by
tools/m11/check_package.py (every Sources/OrganicShell/**/*.swift except App/Main.swift); the suite's flag selects
the product's own @main. The hand-written group lists, the Native trims and the RootView stub are gone (the whole
tree has App/RootView.swift). m10 remains the sole entry for the M10-A exposure gates (ModeExposureVerification).
offscreen-check.sh calls it. The retired modes remain available for compatibility:
  native  -> tools/m11/component-check.py native
  dock    -> tools/bodies/run-host-regressions.py dock
  organic -> tools/bodies/run-host-regressions.py organic
--baseline: JSON {repository-relative path: original text}; those files are compiled from the given text instead.
"""
from pathlib import Path
import argparse
import json
import os
import subprocess
import sys

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import check_package  # noqa: E402

FLAGS = {'native': 'M1_SELFTEST', 'm10': 'M10_MODE_SELFTEST', 'dock': 'M10_DOCK_SELFTEST',
         'organic': 'ORGANIC_SELFTEST'}


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument('suite', choices=sorted(FLAGS))
    p.add_argument('output', type=Path)
    p.add_argument('--cache', type=Path, required=True)
    p.add_argument('--compile-only', action='store_true')
    p.add_argument('--baseline', type=Path, help='git-show product sources for a separate baseline cache')
    a = p.parse_args()
    root = HERE.parents[1]
    out = a.output.resolve()
    out.mkdir(parents=True, exist_ok=True)
    package = a.cache.resolve() / (a.suite + ('-baseline' if a.baseline else ''))
    replacement = {}
    if a.baseline:
        originals = package.parent / (package.name + '-originals')
        originals.mkdir(parents=True, exist_ok=True)
        for rel, text in json.loads(a.baseline.read_text()).items():
            target = originals / Path(rel).name
            if not target.exists() or target.read_text() != text:
                target.write_text(text)
            replacement[Path(rel).name] = target
    sources = check_package.prepare(root, package, define=[FLAGS[a.suite]], replacement=replacement or None,
                                    name='PlaybackGate', body_assets=os.environ.get('CHECK_BODY_ASSETS'))
    (out / 'sources.txt').write_text(''.join(str(path) + '\n' for path in sources.values()))
    with (out / 'build.log').open('w') as log:
        build = subprocess.run(['swift', 'build', '--package-path', str(package), '-c', 'debug', '-j', '4'],
                               stdout=log, stderr=subprocess.STDOUT)
    if build.returncode:
        print((out / 'build.log').read_text(errors='replace')[-4000:])
        return 2
    bin_dir = subprocess.check_output(['swift', 'build', '--package-path', str(package), '-c', 'debug',
                                       '--show-bin-path'], text=True).strip()
    gate = Path(bin_dir) / 'Check'
    if a.compile_only:
        print(gate)
        return 0
    with (out / 'run.log').open('w') as log:
        code = subprocess.Popen([str(gate), str(out)], stdout=log, stderr=subprocess.STDOUT).wait()
    print((out / 'run.log').read_text(errors='replace')[-2000:])
    return code


if __name__ == '__main__':
    sys.exit(main())
