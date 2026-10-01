#!/usr/bin/env python3
"""Compare immutable full-precision replays; never rewrite a strategy or data file."""
import argparse
import json
import math
from pathlib import Path


def compare(before, after):
    failures = []
    checks = 0
    maximum_amount_difference = 0.0

    def walk(a, b, path):
        nonlocal checks, maximum_amount_difference
        if type(a) in (float, int) and type(b) in (float, int):
            checks += 1
            if not math.isfinite(a) or not math.isfinite(b):
                failures.append({'path': path, 'error': 'nonfinite comparison input'})
                return
            metric = any(key in path for key in (
                'annualized_return', 'total_return', 'max_drawdown', 'sharpe_rf0',
                'sharpe_ratio', 'calmar_ratio', 'annualized_volatility', 'average_gross_exposure'))
            weight = 'target_weights' in path
            tolerance = 1e-12 if metric or weight else max(1e-8, abs(a) * 1e-12)
            difference = abs(a - b)
            if not metric and not weight:
                maximum_amount_difference = max(maximum_amount_difference, difference)
            if difference > tolerance:
                failures.append({'path': path, 'before': a, 'after': b, 'tolerance': tolerance})
        elif isinstance(a, dict) and isinstance(b, dict):
            if set(a) != set(b):
                failures.append({'path': path, 'keys_before': sorted(a), 'keys_after': sorted(b)})
            for key in sorted(set(a) & set(b)):
                walk(a[key], b[key], f'{path}.{key}')
        elif isinstance(a, list) and isinstance(b, list):
            if len(a) != len(b):
                failures.append({'path': path, 'length_before': len(a), 'length_after': len(b)})
            for index, (x, y) in enumerate(zip(a, b)):
                walk(x, y, f'{path}[{index}]')
        elif a != b:
            failures.append({'path': path, 'before': a, 'after': b})

    walk(before['results'], after['results'], 'results')
    return {'strategies': len(before['results']), 'checks': checks,
            'maximum_amount_difference': maximum_amount_difference,
            'failure_count': len(failures), 'failures': failures[:100]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('before', type=Path)
    parser.add_argument('after', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if args.output.exists():
        parser.error('Output exists; choose a new evidence path')
    report = compare(json.loads(args.before.read_text()), json.loads(args.after.read_text()))
    args.output.write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps({key: value for key, value in report.items() if key != 'failures'}))
    raise SystemExit(bool(report['failure_count']))


if __name__ == '__main__':
    main()
