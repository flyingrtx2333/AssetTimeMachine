#!/usr/bin/env python3
"""Export the compiled Swift registry and compare the related backend's authorization contract."""
import argparse
import os
from pathlib import Path
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--backend-checkout', type=Path, required=True)
    parser.add_argument('--python', default='python3')
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    backend_checkout = args.backend_checkout.resolve()
    remote = subprocess.check_output(['git', '-C', str(backend_checkout), 'remote', 'get-url', 'origin'], text=True).strip()
    if not remote.removesuffix('.git').endswith('flyingrtx2333/FlyingrtxFast'):
        parser.error('The checkout must be the related FlyingrtxFast Git repository')
    backend = backend_checkout / 'backend'
    test = backend / 'tests/test_backtest_strategy_registry.py'
    if not test.is_file():
        parser.error('The backend strategy registry contract test is missing')
    subprocess.run(['swift', 'build', '-c', 'release', '--product', 'AssetTimeMachineResearch'], cwd=root, check=True)
    binaries = Path(subprocess.check_output(['swift', 'build', '-c', 'release', '--show-bin-path'], cwd=root, text=True).strip())
    with tempfile.TemporaryDirectory(prefix='atm-registry-contract-') as temporary:
        export = Path(temporary) / 'registry.json'
        with export.open('w') as output:
            subprocess.run([str(binaries / 'AssetTimeMachineResearch'), 'catalog'], cwd=root, stdout=output, check=True)
        environment = dict(os.environ, ATM_SWIFT_REGISTRY_JSON=str(export))
        subprocess.run([args.python, 'tests/run_offline.py', '-q', 'tests/test_backtest_strategy_registry.py'],
                       cwd=backend, env=environment, check=True)


if __name__ == '__main__':
    main()
