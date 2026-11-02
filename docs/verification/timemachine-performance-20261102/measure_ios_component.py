from pathlib import Path
import subprocess,plistlib,sys
root=Path.cwd();folder=root/'build/calendar-interaction-perf';app=folder/'CalendarPerf.app';app.mkdir(exist_ok=True)
def block(source,marker):
 a=source.index(marker);b=source.index('{',a)+1;depth=1
 while depth:depth+=(source[b]=='{')-(source[b]=='}');b+=1
 return source[a:b]+'\n'
projection=block((root/'AssetTimeMachine/Services/TimeMachineSnapshotProjectionStore.swift').read_text(),'struct TimeMachineSnapshotProjection:')
chart=(root/'AssetTimeMachine/Views/TimeMachine/TimeMachineCharts.swift').read_text()
chart=chart.replace('        self.points = points\n        self.latestPoint = latestPoint','        Diagnostics.chartInits += 1\n        self.points = points\n        self.latestPoint = latestPoint',1)
(folder/'Charts.swift').write_text(chart)
calendar=(root/'AssetTimeMachine/Views/TimeMachine/TimeMachineChangeCalendar.swift').read_text()
calendar=calendar.replace('        return Button','        Diagnostics.cells += 1\n        return Button')
calendar=calendar.replace('    var body: some View {\n        Button', '    var body: some View {\n        Diagnostics.cells += 1\n        return Button')
calendar=calendar.replace('    private func amount(_ day: AssetChangeDay) -> String {','    private func amount(_ day: AssetChangeDay) -> String {\n        Diagnostics.formats += 1')
(folder/'Calendar.swift').write_text(calendar)
formatters=(root/'AssetTimeMachine/Views/Shared/AppFormatters.swift').read_text();formatters=formatters[formatters.index('import Foundation'):formatters.index('extension AssetCategory')]+formatters[formatters.index('extension Date'):]
(folder/'Formatters.swift').write_text(formatters)
(folder/'Theme.swift').write_text((root/'AssetTimeMachine/AssetTheme.swift').read_text().split('struct ATMCardModifier:')[0])
helper=block((root/'AssetTimeMachine/Views/Shared/SharedUIComponents.swift').read_text(),'func evenlySampledItems<T>')
(folder/'Support.swift').write_text('import SwiftUI\nimport UIKit\nimport Foundation\nenum AppPreviewSession { static let isActive=true }\n'+projection+helper)
(folder/'Preview.swift').write_text(r'''import SwiftUI
import UIKit
final class Diagnostics: NSObject {
 static var chartInits=0;static var cells=0;static var formats=0
 var intervals:[Double]=[];var previous:CFTimeInterval=0
 @objc func frame(_ link:CADisplayLink) { if previous>0 {intervals.append((link.timestamp-previous)*1000)};previous=link.timestamp }
}
@main struct CalendarPerf:App { var body:some Scene { WindowGroup { Preview() } } }
struct Preview:View {
 @State private var selection = TimeMachineSelection()

 @State private var range:TimeMachineRange = .all
 let samples:[TimeMachineSnapshotProjection]
 let points:[TimeMachineTrendPoint]
 init() {
 let c=Calendar.current;let start=c.date(from:DateComponents(year:2026,month:1,day:1))!
 samples=(0..<300).map {i in
 let date=c.date(byAdding:.day,value:i,to:start)!
 return .init(id:UUID(),date:date,updatedAt:date,totalAssets:200000+Double(i)*20, totalLiabilities:20000,
 goldAnchorPriceCNY:nil,goldAnchorDate:nil,btcAnchorPriceUSD:nil,btcAnchorPriceCNY:nil,btcAnchorDate:nil,
 nasdaqAnchorPriceUSD:nil,nasdaqAnchorPriceCNY:nil,nasdaqAnchorDate:nil)
 }
 points=samples.map {p in .init(date:p.date,mainAssets:p.totalAssets,netAssets:p.totalAssets-p.totalLiabilities,liabilities:p.totalLiabilities,goldEquivalent:nil,btcEquivalent:nil,nasdaqEquivalent:nil,goldAnchorPriceCNY:nil,goldAnchorDate:nil,btcAnchorPriceUSD:nil,btcAnchorPriceCNY:nil,btcAnchorDate:nil,nasdaqAnchorPriceUSD:nil,nasdaqAnchorPriceCNY:nil,nasdaqAnchorDate:nil) }
 }
 var body:some View {
 ScrollView { VStack {
 TimeMachineHeroTrendCard(points:points,latestPoint:points.last!,marketOptions:[],marketSeries:[],visibleSeriesIDs:Set(TimeMachineAssetSeries.allCases.map(\.id)),selectedRange:$range,selection:selection,amountsVisible:true,onToggleSeries:{_ in})
 TimeMachineChangeCalendar(summaries:samples,revision:1,selection:selection,amountsVisible:true,onOpenRecord:{_ in})
 }.padding(16) }
 .task {
 try? await Task.sleep(for:.seconds(2))
 Diagnostics.chartInits=0;Diagnostics.cells=0;Diagnostics.formats=0
 let recorder=Diagnostics();let link=CADisplayLink(target:recorder,selector:#selector(Diagnostics.frame(_:)));link.add(to:.main,forMode:.common)
 var cadence:[Double]=[];var last=CACurrentMediaTime()
 for i in 0..<100 {
  selection.select(points[i*2].date)
  try? await Task.sleep(for:.milliseconds(17))
  let now=CACurrentMediaTime();cadence.append((now-last)*1000);last=now
 }
 link.invalidate()
 let frames=recorder.intervals.sorted(),steps=cadence.sorted()
 let result:[String:Any]=["updates":100,"chartPreparations":Diagnostics.chartInits,"cellBodies":Diagnostics.cells,"amountFormats":Diagnostics.formats,"displayLinkP95Milliseconds":frames.isEmpty ? 0:frames[min(frames.count-1,Int(Double(frames.count)*0.95))],"stepCadenceP95Milliseconds":steps[94],"scope":"Actual iOS Hero chart and daily calendar, synthetic snapshots, simulator; not a physical-device FPS claim"]
 let target=FileManager.default.urls(for:.documentDirectory,in:.userDomainMask)[0].appendingPathComponent("result.json")
 try! JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:target)
 }
 }
}
''')
sdk=subprocess.check_output(['xcrun','--sdk','iphonesimulator','--show-sdk-path'],text=True).strip()
files=[folder/'Support.swift',folder/'Preview.swift',folder/'Theme.swift',root/'Shared/AssetColorPalette.swift',root/'AssetTimeMachine/AppLanguage.swift',root/'AssetTimeMachine/Views/Shared/AppTypography.swift',folder/'Formatters.swift',root/'AssetTimeMachine/Views/Shared/ChartLayoutSupport.swift',root/'AssetTimeMachine/Services/AssetChangeCalendarData.swift',folder/'Charts.swift',folder/'Calendar.swift']
subprocess.run(['xcrun','swiftc','-O','-parse-as-library','-sdk',sdk,'-target','arm64-apple-ios18.0-simulator',*[str(f) for f in files],'-o',str(app/'CalendarPerf')],check=True)
info={'CFBundleExecutable':'CalendarPerf','CFBundleIdentifier':'com.flyingrtx.calendar-performance','CFBundleName':'Calendar Perf','CFBundleVersion':'1','CFBundleShortVersionString':'1','CFBundlePackageType':'APPL','LSRequiresIPhoneOS':True,'UILaunchScreen':{},'UIDeviceFamily':[1],'MinimumOSVersion':'18.0'}
(app/'Info.plist').write_bytes(plistlib.dumps(info));subprocess.run(['codesign','--force','--sign','-',str(app)],check=True)
print('Actual iOS chart/calendar performance harness built')
