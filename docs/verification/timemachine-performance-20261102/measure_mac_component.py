from pathlib import Path
import subprocess,sys
root=Path(__file__).resolve().parents[3];work=root/'build/calendar-interaction-perf';work.mkdir(parents=True,exist_ok=True)
def block(source,marker):
 a=source.index(marker);b=source.index('{',a)+1;depth=1
 while depth:depth+=(source[b]=='{')-(source[b]=='}');b+=1
 return source[a:b]+'\n'
style=(root/'AssetTimeMachineNativeMac/Sources/NativeStyle.swift').read_text()
projection=(root/'AssetTimeMachine/Services/TimeMachineSnapshotProjectionStore.swift').read_text()
source=(root/'AssetTimeMachineNativeMac/Sources/NativeAssetChangeCalendar.swift').read_text()
source=source.replace('        return Button', '        Diagnostics.cells += 1\n        return Button')
source=source.replace('    var body: some View {\n        Button', '    var body: some View {\n        Diagnostics.cells += 1\n        return Button')
source=source.replace('    private var amount: String {', '    private var amount: String {\n        Diagnostics.formats += 1')
source=source.replace('    private func amount(_ day: AssetChangeDay) -> String {','    private func amount(_ day: AssetChangeDay) -> String {\n        Diagnostics.formats += 1')
support='''import AppKit
import SwiftUI
import Foundation
import Darwin
enum Diagnostics { static var cells=0; static var formats=0 }
enum AppPreviewSession { static let isActive=true }
enum AppLocalization {
 static let currentLocale=Locale(identifier:"zh_CN")
 static func string(_ s:String)->String{s}
 static func format(_ f:String,_ value:String)->String{String(format:f,value)}
}
'''
types=block(projection,'struct TimeMachineSnapshotProjection:')
for marker in ['enum NativeStyle {','enum NativePalette {','enum AssetTheme {','enum NativeHomeStyle {']:
 types+=block(style,marker)
shared=(root/'AssetTimeMachine/Services/AssetChangeCalendarData.swift').read_text()
host=r'''
final class Driver: ObservableObject { @Published var selected:UUID? }
struct Preview: View {
 @ObservedObject var driver:Driver
 let samples:[TimeMachineSnapshotProjection]
 var body:some View {
  NativeAssetChangeCalendar(summaries:samples,revision:1,selectedID:driver.selected) {driver.selected=$0}
   .padding(20).frame(width:752,height:240)
 }
}
let calendar=Calendar.current
let start=calendar.date(from:DateComponents(year:2026,month:1,day:1))!
let samples=(0..<300).map {i -> TimeMachineSnapshotProjection in
 let d=calendar.date(byAdding:.day,value:i,to:start)!
 return .init(id:UUID(),date:d,updatedAt:d,totalAssets:100000+Double(i)*100,totalLiabilities:20000,
 goldAnchorPriceCNY:nil,goldAnchorDate:nil,btcAnchorPriceUSD:nil,btcAnchorPriceCNY:nil,btcAnchorDate:nil,
 nasdaqAnchorPriceUSD:nil,nasdaqAnchorPriceCNY:nil,nasdaqAnchorDate:nil)
}
let app=NSApplication.shared;app.setActivationPolicy(.accessory)
let driver=Driver()
let host=NSHostingView(rootView:Preview(driver:driver,samples:samples))
let window=NSWindow(contentRect:NSRect(x:0,y:0,width:752,height:240),styleMask:[.titled],backing:.buffered,defer:false)
window.contentView=host;window.orderFrontRegardless()
RunLoop.current.run(until:Date().addingTimeInterval(0.5))
Diagnostics.cells=0;Diagnostics.formats=0
var elapsed:[Double]=[]
for i in 0..<100 {
 let t=DispatchTime.now().uptimeNanoseconds
 driver.selected=samples[i*2].id
 RunLoop.current.run(until:Date().addingTimeInterval(0.001))
 host.layoutSubtreeIfNeeded();window.displayIfNeeded()
 elapsed.append(Double(DispatchTime.now().uptimeNanoseconds-t)/1e6)
}
let sorted=elapsed.sorted()
let result:[String:Any]=["updates":100,"cellBodies":Diagnostics.cells,"amountFormats":Diagnostics.formats,
 "medianMilliseconds":sorted[50],"p95Milliseconds":sorted[94],"maximumMilliseconds":sorted.last!,
 "scope":"Actual native calendar in AppKit window; synthetic values; 1ms run-loop plus layout/display barrier; local machine only"]
let path=CommandLine.arguments[1]
try! JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:path))
print(result);window.orderOut(nil)
'''
main=work/'main.swift';main.write_text(support+types+shared+source+host)
subprocess.run(['swiftc','-O','-target','arm64-apple-macosx15.0',str(main),'-o',str(work/'run')],check=True)
subprocess.run([str(work/'run'),str(work/(sys.argv[1]+'.json'))],check=True,timeout=55)
