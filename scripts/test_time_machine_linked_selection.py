"""Focused date-binding and unsampled-day regression, executing production method bodies."""
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
    assert page.count('selectedDate: timelineSelection,') == 2, 'Both surfaces must receive the same parent binding'
    assert '@Binding var selectedDate: Date?' in chart[chart.index('struct TimeMachineHeroTrendCard:'):]
    assert '@Binding var selectedDate: Date?' in calendar and '@State private var selectedDate:' not in calendar
    assert '.onChange(of: selectedDate)' in calendar and 'selectedDate = nil; rebuild()' not in calendar
    assert '.disabled(day.snapshotID == nil)' in calendar, 'Unrecorded dates cannot move a record probe'
    selection = block(page, 'private var timelineSelection:').replace('private var', 'var', 1)
    selection = selection.replace('Binding(get: {', 'Binding(get: { [self] in').replace('set: { date in', 'set: { [self] date in')
    follow = block(calendar, 'private func followSelection(').replace('private func', 'func', 1)
    sampling = chart[chart.index('        var displayPoints = evenlySampledItems('):chart.index('        self.displayPoints = displayPoints')]
    nearest = block(chart, 'func nearestChartPoint<T>')
    sampled = block(support, 'func evenlySampledItems<T>')
    swift = '''import Foundation
import SwiftUI
struct TimeMachineTrendPoint { let date: Date }
enum TimeMachineRange { case sixMonths, all }
final class Host {
 var selectedTimelineDate: Date?
 var selectedRange: TimeMachineRange = .sixMonths
 var cachedFilteredTrendPoints: [TimeMachineTrendPoint] = []
''' + selection + '''
}
final class CalendarHost { var year = 2026
''' + follow + '''
}
func rendered(_ points: [TimeMachineTrendPoint], selection selectedDate: Binding<Date?>) -> [TimeMachineTrendPoint] {
''' + sampling + '''
 return displayPoints
}
''' + nearest + '\n' + sampled + '''
var c = Calendar.current
let start = c.date(from: DateComponents(year:2024, month:1, day:1, hour:18, minute:30))!
let points = (0..<800).map { TimeMachineTrendPoint(date:c.date(byAdding:.day,value:$0,to:start)!) }
let host = Host(); host.cachedFilteredTrendPoints = Array(points.suffix(100))
let chartInput = host.timelineSelection
let calendarInput = host.timelineSelection
// A chart probe change must be immediately readable by the calendar, with no copied state.
chartInput.wrappedValue = points[750].date
precondition(calendarInput.wrappedValue == points[750].date && host.selectedRange == .sixMonths)
// A calendar selection outside the visible range retains its exact timestamp and expands the range.
calendarInput.wrappedValue = points[15].date
precondition(chartInput.wrappedValue == points[15].date && host.selectedRange == .all)
let year = CalendarHost(); year.followSelection(chartInput.wrappedValue)
precondition(year.year == 2024)
chartInput.wrappedValue = points[750].date; year.followSelection(chartInput.wrappedValue)
precondition(year.year == c.component(.year,from:points[750].date))
// A selected real date omitted from the 180-point line sample must still be rendered exactly.
let base = evenlySampledItems(points,maxCount:180)
let omitted = points.first { p in !base.contains { $0.date == p.date } }!
calendarInput.wrappedValue = omitted.date
let result = rendered(points,selection:chartInput)
precondition(result.count == 181 && result.contains { $0.date == omitted.date })
precondition(result.map(\\.date) == result.map(\\.date).sorted())
chartInput.wrappedValue = nil
precondition(calendarInput.wrappedValue == nil)
print("PASS: bidirectional shared date, visible/older dates, cross-year following, exact unsampled point, clearing")
'''
    with tempfile.TemporaryDirectory(prefix='atm-linked-date-') as temp:
        source = Path(temp) / 'main.swift'
        binary = Path(temp) / 'check'
        source.write_text(swift)
        subprocess.run(['swiftc', str(source), '-o', str(binary)], check=True)
        subprocess.run([str(binary)], check=True)


if __name__ == '__main__':
    test_linked_selection()
