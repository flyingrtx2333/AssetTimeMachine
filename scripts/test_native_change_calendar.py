"""Shared iOS/native calendar calculations; no user stores or remote services."""
from pathlib import Path
import subprocess
import tempfile


def test_native_change_calendar():
    root = Path(__file__).resolve().parents[1]
    calculation = (root / 'AssetTimeMachine/Services/AssetChangeCalendarData.swift').read_text()
    projection = (root / 'AssetTimeMachine/Services/TimeMachineSnapshotProjectionStore.swift').read_text()
    projection = projection[projection.index('struct TimeMachineSnapshotProjection:'):projection.index('struct SnapshotArchiveProjection:')]
    support = '''import SwiftUI
    import AppKit
    enum AppPreviewSession { static let isActive = true }
    enum AppLocalization { static func string(_ s: String) -> String { s } }
    enum AssetTheme { static let negative = Color.red; static let positive = Color.green; static let textSecondary = Color.gray }
    '''
    checks = r'''
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }
    func row(_ date: Date, _ total: Double, _ debt: Double, updated: Date? = nil) -> TimeMachineSnapshotProjection {
        .init(id: UUID(), date: date, updatedAt: updated ?? date, totalAssets: total, totalLiabilities: debt,
              goldAnchorPriceCNY: nil, goldAnchorDate: nil, btcAnchorPriceUSD: nil, btcAnchorPriceCNY: nil,
              btcAnchorDate: nil, nasdaqAnchorPriceUSD: nil, nasdaqAnchorPriceCNY: nil, nasdaqAnchorDate: nil)
    }
    let baseline = row(date(2025,12,31),500,100)
    let old = row(date(2026,1,1),500,200)
    let closing = row(date(2026,1,1),550,200,updated:date(2026,1,1).addingTimeInterval(3600))
    let third = row(date(2026,1,3),700,200)
    let fourth = row(date(2026,1,4),700,200)
    let future = row(date(2026,1,5),999999,0)
    let model = AssetChangeYear(year:2026,summaries:[future,closing,baseline,fourth,old,third],today:date(2026,1,4),calendar:calendar)
    precondition(model.days.count==365 && model.leadingDays==3 && model.weeks==53)
    precondition(model.day(week:0,weekday:0)==nil && model.day(week:0,weekday:3)?.date==date(2026,1,1))
    precondition(model.days[0].snapshotID==closing.id && model.days[0].change == -50,
        "Closing balance, liabilities, and prior-year baseline must be respected; duplicates are not summed")
    precondition(model.days[1].snapshotID==nil && model.days[1].change==nil, "A missing day is never a fabricated flat day")
    precondition(model.days[2].change==150 && model.days[2].previousDate==date(2026,1,1),
        "A multi-day gap keeps its actual comparison date")
    precondition(model.days[3].change==0 && model.days[3].snapshotID==fourth.id)
    precondition(model.days[4].isFuture && model.days[4].snapshotID==nil && model.maximumChange==150)
    precondition(model.day(snapshotID: closing.id)?.date == date(2026,1,1))
    precondition(model.day(on: date(2026,1,3).addingTimeInterval(3600))?.snapshotID == third.id)
    precondition(model.day(on: date(2025,12,31)) == nil)
    let first=AssetChangeYear(year:2026,summaries:[closing],today:date(2026,1,4),calendar:calendar)
    precondition(first.days[0].change==nil, "First observation has no comparison, not a gain from zero")
    let tiny=row(date(2026,1,2),549.996,200)
    let rounded=AssetChangeYear(year:2026,summaries:[closing,tiny],today:date(2026,1,4),calendar:calendar)
    precondition(rounded.days[1].change==0 && rounded.days[1].change?.sign == .plus)
    let invalid=AssetChangeYear(year:2026,summaries:[closing,row(date(2026,1,2),.infinity,0)],today:date(2026,1,4),calendar:calendar)
    precondition(invalid.days[1].change==nil && invalid.maximumChange.isFinite)
    let leap=AssetChangeYear(year:2024,summaries:[],today:date(2026,1,4),calendar:calendar)
    precondition(leap.days.count==366 && leap.days.contains { $0.date==date(2024,2,29) })
    var dst=calendar;dst.timeZone=TimeZone(identifier:"America/New_York")!
    let dstYear=AssetChangeYear(year:2024,summaries:[],today:date(2026,1,4),calendar:dst)
    precondition(dstYear.days.count==366 && Set(dstYear.days.map(\.date)).count==366)
    precondition(AssetChangeColorScheme.region.redIsUp(region:"CN") && !AssetChangeColorScheme.region.redIsUp(region:"US"))
    precondition(!AssetChangeColorScheme.greenRise.redIsUp(region:"CN") && AssetChangeColorScheme.redRise.redIsUp(region:"US"))
    let defaults=AssetChangePreferences.defaults
    defaults.set(AssetChangeColorScheme.greenRise.rawValue,forKey:AssetChangePreferences.key)
    let restored=AssetChangeColorScheme(rawValue:defaults.string(forKey:AssetChangePreferences.key)!)!
    precondition(!restored.redIsUp(region:"CN"));defaults.removeObject(forKey:AssetChangePreferences.key)
    let zh = Locale(identifier:"zh-Hans"), en = Locale(identifier:"en-US")
    for locale in [zh,en] {
        precondition(AssetChangeCellPresentation.text(23.45,locale:locale)=="+23")
        precondition(AssetChangeCellPresentation.text(94.91,locale:locale)=="+95")
        precondition(AssetChangeCellPresentation.text(-0.01,locale:locale)=="−0.01")
        precondition(AssetChangeCellPresentation.text(-0.004,locale:locale)=="0")
        precondition(AssetChangeCellPresentation.text(.infinity,locale:locale)=="—")
        precondition(AssetChangeCellPresentation.text(Double.greatestFiniteMagnitude,locale:locale).count<10)
    }
    precondition(AssetChangeCellPresentation.text(120,locale:zh)=="+120")
    precondition(AssetChangeCellPresentation.text(120,locale:en)=="+120")
    precondition(AssetChangeCellPresentation.text(-3400,locale:zh)=="−3,400")
    precondition(AssetChangeCellPresentation.text(-3400,locale:en)=="−3.4K")
    precondition(AssetChangeCellPresentation.text(12345,locale:zh)=="+1.2万")
    precondition(AssetChangeCellPresentation.text(12345,locale:en)=="+12K")
    precondition(AssetChangeCellPresentation.text(999.99,locale:zh)=="+1,000")
    precondition(AssetChangeCellPresentation.text(7600,locale:zh)=="+7,600")
    precondition(AssetChangeCellPresentation.text(7600,locale:en)=="+7.6K")
    precondition(AssetChangeCellPresentation.text(9999.99,locale:zh)=="+1万")
    precondition(AssetChangeCellPresentation.text(999500,locale:en)=="+1M")
    precondition(AssetChangeCellPresentation.text(99995000,locale:zh)=="+1亿")
    for available in [CGFloat(260),315,380,744] {
        let width=AssetChangeCellPresentation.cellWidth(for:available)
        let columns=((available+AssetChangeCellPresentation.gap)/(width+AssetChangeCellPresentation.gap)).rounded()
        precondition(width>=AssetChangeCellPresentation.width)
        precondition(abs(columns*width+(columns-1)*AssetChangeCellPresentation.gap-available)<0.01,
            "The viewport must show whole columns, preserving every amount's sign")
    }
    let spread = [row(date(2026,1,1),1000,0),row(date(2026,1,2),1010,0),row(date(2026,1,3),1030,0),
                  row(date(2026,1,4),1060,0),row(date(2026,1,5),1100,0),row(date(2026,1,6),1150,0)]
    let ranked=AssetChangeYear(year:2026,summaries:spread,today:date(2026,1,8),calendar:calendar)
    precondition([10.0,20,30,40,50].map { ranked.intensity(for:$0) } == [1,2,3,4,5])
    precondition(ranked.intensity(for:-20)==ranked.intensity(for:20) && ranked.intensity(for:0)==0)
    let outlier=AssetChangeYear(year:2026,summaries:spread+[row(date(2026,1,7),1e9,0)],today:date(2026,1,8),calendar:calendar)
    precondition(outlier.intensity(for:10)<outlier.intensity(for:40) && outlier.intensity(for:1e9)==5)
    func luminance(_ color:Color)->Double {
        let c=NSColor(color).usingColorSpace(.sRGB)!
        func linear(_ x:CGFloat)->Double { let v=Double(x);return v<=0.04045 ? v/12.92 : pow((v+0.055)/1.055,2.4) }
        return 0.2126*linear(c.redComponent)+0.7152*linear(c.greenComponent)+0.0722*linear(c.blueComponent)
    }
    let cell=AssetChangeDay(date:date(2026,1,1),snapshotID:UUID(),previousDate:date(2025,12,31),change:1,isFuture:false)
    for appearance in [ColorScheme.light,.dark] {
        for scheme in [AssetChangeColorScheme.redRise,.greenRise] {
            var previousLuminance=Double.infinity
            for level in 1...5 {
                let style=AssetChangeCellPresentation.colors(day:cell,level:level,scheme:scheme,appearance:appearance)
                let a=luminance(style.background),b=luminance(style.foreground)
                precondition((max(a,b)+0.05)/(min(a,b)+0.05)>=4.5,"Every amount must remain legible at every color level")
                precondition(a<previousLuminance,"Larger absolute changes must use deeper colors in both appearances")
                previousLuminance=a
            }
        }
    }
    print("PASS: calendar invariants, readable signed amounts and unit boundaries, whole-column widths, outlier-resistant levels, deeper larger changes, and all cell text contrast")
    '''
    with tempfile.TemporaryDirectory(prefix='atm-change-calendar-') as directory:
        main = Path(directory) / 'main.swift'
        executable = Path(directory) / 'checks'
        main.write_text(support + projection + calculation + checks)
        subprocess.run(['swiftc', str(main), '-o', str(executable)], check=True)
        subprocess.run([str(executable)], check=True)


if __name__ == '__main__':
    test_native_change_calendar()
