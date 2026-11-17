"""Run the production comparison math with synthetic values only."""
from pathlib import Path
import subprocess
import tempfile


def test_time_machine_comparison():
    root = Path(__file__).resolve().parents[1]
    source = (root / "AssetTimeMachineNativeMac/Sources/NativeRootView.swift").read_text()
    comparison = source[source.index("struct NativeTimeMachineComparison {"):source.index("struct NativeTimeMachineView: View {")]
    cases = """
    let gain = NativeTimeMachineComparison(current: 120, baseline: 100)
    precondition(gain.amount == 20 && gain.percentage == 0.2)
    let loss = NativeTimeMachineComparison(current: 80, baseline: 100)
    precondition(loss.amount == -20 && loss.percentage == -0.2)
    let unchanged = NativeTimeMachineComparison(current: 100, baseline: 100)
    precondition(unchanged.amount == 0 && unchanged.percentage == 0)
    let zero = NativeTimeMachineComparison(current: 120, baseline: 0)
    precondition(zero.amount == 120 && zero.percentage == nil)
    let negative = NativeTimeMachineComparison(current: -80, baseline: -100)
    precondition(negative.amount == 20 && negative.percentage == 0.2)
    let previous = NativeTimeMachineComparison(current: 120, baseline: 115)
    precondition(previous.amount == 5 && gain.amount == 20)
    for pair: (Double?, Double?) in [(nil, 100), (120, nil), (.nan, 100), (120, .infinity),
                                   (.greatestFiniteMagnitude, -.greatestFiniteMagnitude)] {
        let unavailable = NativeTimeMachineComparison(current: pair.0, baseline: pair.1)
        precondition(unavailable.amount == nil && unavailable.percentage == nil)
    }
    let overflow = NativeTimeMachineComparison(current: 1, baseline: .leastNonzeroMagnitude)
    precondition(overflow.amount != nil && overflow.percentage == nil)
    print("12 comparison checks passed")
    """
    with tempfile.TemporaryDirectory(prefix="atm-period-comparison-") as directory:
        script = Path(directory) / "main.swift"
        script.write_text("import Foundation\n" + comparison + cases)
        subprocess.run(["swift", str(script)], check=True)


if __name__ == "__main__":
    test_time_machine_comparison()
