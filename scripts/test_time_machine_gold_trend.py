"""Focused proof of actual gold conversion and chart observations, without user stores."""
from pathlib import Path
import subprocess
import tempfile


def block(source, marker):
    start = source.index(marker)
    end = source.index('{', start) + 1
    depth = 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end] + '\n'


def test_time_machine_gold_trend():
    root = Path(__file__).resolve().parents[1]
    chart = (root / 'AssetTimeMachine/Views/TimeMachine/TimeMachineCharts.swift').read_text()
    projection = (root / 'AssetTimeMachine/Services/TimeMachineSnapshotProjectionStore.swift').read_text()
    ui = (root / 'AssetTimeMachine/Views/Shared/SharedUIComponents.swift').read_text()
    support = '''import Foundation
    struct TimeMachineLiveMarketAnchors {
        let goldPriceCNY: Double?; let btcPriceUSD: Double?; let btcPriceCNY: Double?
        let nasdaqPriceUSD: Double?; let nasdaqPriceCNY: Double?
    }
    '''
    actual = block(chart, 'struct TimeMachineTrendPoint:')
    actual += block(projection, 'struct TimeMachineSnapshotProjection:')
    actual += block(ui, 'func evenlySampledItems<T>')
    actual += block(chart, 'enum TimeMachineGoldTrend {')
    actual += 'enum Processor {\n'
    actual += block(projection, 'nonisolated static func makeTrendPoint(')
    actual += block(projection, 'nonisolated private static func anchorDateIfToday(')
    actual += '}\n'
    actual += 'enum Plot {\n' + block(chart, 'private static func mapGoldQuantity(').replace('private static', 'static', 1) + '}\n'
    checks = r'''
    let origin = Date(timeIntervalSince1970: 1_600_000_000)
    func point(_ day: Int, _ assets: Double = 100000, _ quote: Double? = 500,
               debt: Double = 20000) -> TimeMachineTrendPoint {
        let date = origin.addingTimeInterval(Double(day) * 86400)
        let snapshot = TimeMachineSnapshotProjection(id: UUID(), date: date, updatedAt: date,
            totalAssets: assets, totalLiabilities: debt, goldAnchorPriceCNY: quote, goldAnchorDate: date,
            btcAnchorPriceUSD: nil, btcAnchorPriceCNY: nil, btcAnchorDate: nil,
            nasdaqAnchorPriceUSD: nil, nasdaqAnchorPriceCNY: nil, nasdaqAnchorDate: nil)
        return Processor.makeTrendPoint(from: snapshot, liveAnchors: nil)
    }
    precondition(TimeMachineGoldTrend.id != "gold_cny", "Quantity visibility must not enable the price benchmark")
    let quoted = [point(0), point(1, 100000, 1000)]
    let grams = TimeMachineGoldTrend.observations(in: quoted)
    precondition(grams.map(\.grams) == [200, 100], "A doubled quote must halve grams, not draw a rising price return")
    precondition(TimeMachineGoldTrend.grams(in: point(0, 200000, 500)) == 400)
    precondition(TimeMachineGoldTrend.grams(in: point(0, 200000, 1000)) == 200)
    precondition(TimeMachineGoldTrend.grams(in: point(0, debt: 90000)) == 200,
        "Use main assets rather than net assets")
    precondition(TimeMachineGoldTrend.grams(in: point(0, 0)) == 0)
    for quote: Double? in [nil, 0, -1, .infinity, .nan] {
        precondition(TimeMachineGoldTrend.grams(in: point(0, 100000, quote)) == nil)
    }
    precondition(TimeMachineGoldTrend.grams(in: point(0, .infinity)) == nil)
    precondition(TimeMachineGoldTrend.grams(in: point(0, .greatestFiniteMagnitude, .leastNonzeroMagnitude)) == nil)
    let gaps = TimeMachineGoldTrend.observations(in: [point(0), point(1, 100000, nil), point(2)])
    precondition(gaps.count == 2 && gaps[0].segment != gaps[1].segment,
        "A missing quote must split the gold curve")
    let long = (0..<10000).map { index in
        point(index, 100000, index == 4321 ? 1000 : (index == 6789 ? 250 : 500))
    }
    let sampled = TimeMachineGoldTrend.observations(in: long)
    precondition(sampled.count <= 180 && sampled.first?.id == 0 && sampled.last?.id == 9999)
    precondition(sampled.map(\.grams).min() == 100 && sampled.map(\.grams).max() == 400,
        "Gold extrema must survive sampling even when all asset balances are constant")
    precondition(Plot.mapGoldQuantity(100, goldDomain: 100...200, plotDomain: 0...1000) == 0)
    precondition(Plot.mapGoldQuantity(150, goldDomain: 100...200, plotDomain: 0...1000) == 500)
    precondition(Plot.mapGoldQuantity(200, goldDomain: 100...200, plotDomain: 0...1000) == 1000)
    print("PASS: actual main-assets/quote conversion, inverse price direction, zero, invalid quotes, gaps, bounded gold extrema and unit-preserving scale")
    '''
    with tempfile.TemporaryDirectory(prefix='atm-gold-quantity-') as directory:
        main = Path(directory) / 'main.swift'
        main.write_text(support + actual + checks)
        executable = Path(directory) / 'check'
        subprocess.run(['xcrun', 'swiftc', str(main), '-o', str(executable)], check=True)
        subprocess.run([str(executable)], check=True)


if __name__ == '__main__':
    test_time_machine_gold_trend()
