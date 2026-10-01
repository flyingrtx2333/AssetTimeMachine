#!/usr/bin/env python3
"""Compile actual App core and replay six fixed product strategies (post hoc only)."""
import argparse
from pathlib import Path
import subprocess


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
    subprocess.run(['swift', 'build', '-c', 'release', '--product',
                    'AssetTimeMachineExecutionReassessment'], cwd=repo, check=True)
    bin_path = Path(subprocess.check_output(
        ['swift', 'build', '-c', 'release', '--show-bin-path'], cwd=repo, text=True).strip())
    subprocess.run([str(bin_path / 'AssetTimeMachineExecutionReassessment'),
                    str(args.history.resolve()), str(args.macro.resolve()),
                    str(args.fee_percent), str(args.output.resolve())], cwd=repo, check=True)



if __name__ == '__main__':
    main()
