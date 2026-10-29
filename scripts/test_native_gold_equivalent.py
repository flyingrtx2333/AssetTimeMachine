"""Focused checks for the native gold curve, using its actual plot implementation."""
from pathlib import Path
import subprocess
import tempfile


def test_native_gold_equivalent():
    root = Path(__file__).resolve().parents[1]
    source = (root / 'AssetTimeMachineNativeMac/Sources/NativeHomeSurface.swift').read_text()
    plot = source[source.index('struct NativeGoldEquivalentPlot {'):source.index('struct NativePanoramaTrend:')]
    support = '''import SwiftUI
    import Foundation
    struct TimeMachineSnapshotProjection {
        let date: Date
        let totalAssets: Double
        let totalLiabilities: Double
        let goldAnchorPriceCNY: Double?
    }
    '''
    checks = r'''
    let origin = Date(timeIntervalSince1970: 1_750_000_000)
    func row(_ day: Int, _ assets: Double = 1000, _ price: Double? = 10) -> TimeMachineSnapshotProjection {
        .init(date: origin.addingTimeInterval(Double(day) * 86400), totalAssets: assets,
              totalLiabilities: 300, goldAnchorPriceCNY: price)
    }
    precondition(NativeGoldEquivalentPlot.value(row(0)) == 100, "Use total assets, matching iPhone; not net assets")
    precondition(NativeGoldEquivalentPlot.value(row(0, 0)) == 0, "Zero holdings is a valid value")
    for price: Double? in [nil, 0, -1, .infinity, .nan] {
        precondition(NativeGoldEquivalentPlot.value(row(0, 1000, price)) == nil)
    }
    precondition(NativeGoldEquivalentPlot.value(row(0, .infinity)) == nil)
    precondition(NativeGoldEquivalentPlot.value(row(0, .greatestFiniteMagnitude, .leastNonzeroMagnitude)) == nil)
    let missing = NativeGoldEquivalentPlot([row(0, 1000, nil), row(1, 1000, 0)])
    precondition(!missing.hasValues && missing.path.isEmpty)
    let gaps = NativeGoldEquivalentPlot([row(0), row(1, 2000), row(2, 1000, nil), row(3), row(4)])
    var moves = 0
    gaps.path.forEach { if case .move = $0 { moves += 1 } }
    precondition(moves == 2, "A missing quote must split the line, rather than bridge or become zero")
    let history = (0..<10000).map { row($0, 1000, $0 == 4321 ? 0.01 : ($0 == 6789 ? 1000 : 10)) }
    let long = NativeGoldEquivalentPlot(history)
    var vertices: [CGPoint] = []
    long.path.forEach { element in
        switch element {
        case let .move(to: point), let .line(to: point): vertices.append(point)
        default: break
        }
    }
    let values = vertices.map { long.low + (1 - $0.y) * long.span }
    // SwiftUI Path quantizes drawing coordinates to Float; source values remain Double.
    let tolerance = long.span * Double(Float.ulpOfOne)
    precondition(long.values.compactMap { $0 }.min() == 1 && long.values.compactMap { $0 }.max() == 100000)
    precondition(abs(values.max()! - 100000) < tolerance && abs(values.min()! - 1) < tolerance,
        "Gold-price extrema must survive even when asset values are constant")
    precondition(vertices.count <= 600 && vertices.allSatisfy { $0.x.isFinite && $0.y.isFinite && (0...1).contains($0.y) })
    print("PASS: iPhone total-assets basis, missing/invalid quotes, gaps, zero, finite scale, 10k-history gold extrema and bounded path")
    '''
    with tempfile.TemporaryDirectory(prefix='atm-native-gold-') as directory:
        main = Path(directory) / 'main.swift'
        executable = Path(directory) / 'check'
        main.write_text(support + plot + checks)
        subprocess.run(['swiftc', str(main), '-o', str(executable)], check=True, cwd=root)
        subprocess.run([str(executable)], check=True)


if __name__ == '__main__':
    test_native_gold_equivalent()
