#!/usr/bin/env python3
"""Compile actual App core and replay six fixed product strategies (post hoc only)."""
import argparse
from pathlib import Path
import re
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--history', type=Path, required=True)
    parser.add_argument('--macro', type=Path, required=True)
    parser.add_argument('--fee-percent', type=float, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[1]
    for path in (args.history, args.macro):
        if not path.is_file():
            parser.error(f'Missing input: {path}')
    if args.output.exists():
        parser.error('Output exists; choose a new versioned output path to preserve evidence')
    if not 0 <= args.fee_percent <= 100:
        parser.error('Fee is a percentage, between 0 and 100')
    # SwiftPM owns Bundle.module. Generate its actual accessor through the normal build.
    accessors = [p for p in (repo / '.build').rglob('resource_bundle_accessor.swift')
                 if 'AssetTimeMachineBacktestCore' in str(p)]
    if not accessors:
        subprocess.run(['swift', 'build', '-c', 'release', '--product',
                        'AssetTimeMachineBacktestCompute'], cwd=repo, check=True)
        accessors = [p for p in (repo / '.build').rglob('resource_bundle_accessor.swift')
                     if 'AssetTimeMachineBacktestCore' in str(p)]
    if not accessors:
        parser.error('SwiftPM resource accessor unavailable')
    package = (repo / 'Package.swift').read_text()
    names = re.findall(r'"([^"\n]+\.swift)"', package.split('sources: [', 1)[1].split('],', 1)[0])
    sources = [str(repo / 'AssetTimeMachine/Backtest' / name) for name in names]
    with tempfile.TemporaryDirectory(prefix='atm-execution-replay-') as tmp:
        executable = Path(tmp) / 'replay'
        subprocess.run(['xcrun', 'swiftc', '-O', '-D', 'ATM_SERVER', '-parse-as-library',
                        *sources, str(sorted(accessors)[0]),
                        str(repo / 'tools/strategy_execution_reassessment.swift'),
                        '-o', str(executable)], cwd=repo, check=True)
        subprocess.run([str(executable), str(args.history.resolve()), str(args.macro.resolve()),
                        str(args.fee_percent), str(args.output.resolve())], cwd=repo, check=True)


if __name__ == '__main__':
    main()
