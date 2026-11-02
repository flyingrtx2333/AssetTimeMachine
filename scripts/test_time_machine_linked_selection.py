"""Focused selection invariants, executing the production state and probe methods."""
from pathlib import Path
import subprocess
import tempfile


def block(source, start):
    offset = source.index(start)
    opening = source.index('{', offset)
    depth = 1
    end = opening + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[offset:end]


def test_linked_selection():
    root = Path(__file__).resolve().parents[1]
    page = (root / 'AssetTimeMachine/Views/TimeMachine/TimeMachineView.swift').read_text()
    chart = (root / 'AssetTimeMachine/Views/TimeMachine/TimeMachineCharts.swift').read_text()
    calendar = (root / 'AssetTimeMachine/Views/TimeMachine/TimeMachineChangeCalendar.swift').read_text()
    support = (root / 'AssetTimeMachine/Views/Shared/SharedUIComponents.swift').read_text()
    assert page.count('selection: timeline,') == 2, 'Both controls must receive the same observable selection'
    assert '@State private var timeline = TimeMachineSelection()' in page
    hero = chart[chart.index('struct TimeMachineHeroTrendCard:'):chart.index('private struct TimeMachineStaticHeroPlot:')]
    assert 'selectedDate.wrappedValue' not in hero and 'selection.date' not in block(hero, '    init(')
    assert '.onChange(of: focusedWeek(data))' in calendar, 'Do not scroll on every probe update'
    assert '.disabled(day.snapshotID == nil)' in calendar
    session = '@Observable\n' + block(chart, 'final class TimeMachineSelection {')
    follow = block(calendar, 'private func followSelection(').replace('private func', 'func', 1)
    probe = block(hero, 'private var selectedPoint:').replace('private var', 'var', 1)
    sampling = chart[chart.index('        let displayPoints = evenlySampledItems('):chart.index('        self.displayPoints = displayPoints')]
    nearest = block(chart, 'func nearestChartPoint<T>')
    sampled = block(support, 'func evenlySampledItems<T>')
    swift = '''import Foundation
import SwiftUI
import Observation
struct TimeMachineTrendPoint { let date: Date }
''' + session + '''
final class CalendarHost { var year = 2026
''' + follow + '''
}
final class Probe {
 var selectedDate:Date?
 var points:[TimeMachineTrendPoint]=[]
 var latestPoint:TimeMachineTrendPoint { points.last! }
''' + probe + '''
}
func rendered(_ points:[TimeMachineTrendPoint]) -> [TimeMachineTrendPoint] {
''' + sampling + '''
 return displayPoints
}
''' + nearest + '\n' + sampled + '''
let c = Calendar.current
let start = c.date(from: DateComponents(year:2024,month:1,day:1,hour:18,minute:30))!
let points = (0..<800).map { TimeMachineTrendPoint(date:c.date(byAdding:.day,value:$0,to:start)!) }
let selection = TimeMachineSelection()
selection.visibleRange = points[700].date...points[799].date
var reveals=0; selection.revealAll = { reveals += 1 }
let chartInput=selection; let calendarInput=selection
chartInput.select(points[750].date)
precondition(calendarInput.date == points[750].date && reveals==0)
calendarInput.select(points[15].date)
precondition(chartInput.date == points[15].date && reveals==1)
calendarInput.select(points[15].date)
precondition(reveals==1, "Repeated probe events must be deduplicated")
let year=CalendarHost();year.followSelection(chartInput.date);precondition(year.year==2024)
chartInput.select(points[750].date);year.followSelection(chartInput.date)
precondition(year.year==c.component(.year,from:points[750].date))
let base=rendered(points)
let omitted=points.first { p in !base.contains { $0.date==p.date } }!
calendarInput.select(omitted.date)
let probe=Probe();probe.points=points;probe.selectedDate=selection.date
precondition(probe.selectedPoint.date==omitted.date, "The probe must retain an unsampled real date")
precondition(base.count==180 && rendered(points).map(\\.date)==base.map(\\.date), "Selection must not rebuild the line sample")
chartInput.select(nil);precondition(calendarInput.date==nil)
print("PASS: shared observable date, deduplication, older range, cross-year following, exact unsampled probe with stable line, clearing")
'''
    with tempfile.TemporaryDirectory(prefix='atm-linked-date-') as temp:
        source = Path(temp) / 'main.swift'
        binary = Path(temp) / 'check'
        source.write_text(swift)
        subprocess.run(['swiftc', str(source), '-o', str(binary)], check=True)
        subprocess.run([str(binary)], check=True)


if __name__ == '__main__':
    test_linked_selection()
