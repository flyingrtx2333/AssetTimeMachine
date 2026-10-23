import Foundation
import CryptoKit
import AssetTimeMachineBacktestCore

struct Frame: Codable {
 let dates:[String],simulationRange:[Int],tradableSymbols:[String]
 let pricesBySymbol:[String:[Double]],observedBySymbol:[String:[Bool]]
}
struct Target: Decodable {let sourceFrameIndex:Int,targetWeights:[String:Double]}
let root=URL(fileURLWithPath:CommandLine.arguments[1])
let native=try Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[2]))
let decoder=JSONDecoder(),encoder=JSONEncoder()
encoder.dateEncodingStrategy = .iso8601;encoder.outputFormatting=[.sortedKeys,.withoutEscapingSlashes]
let f=try decoder.decode(Frame.self,from:Data(contentsOf:root.appendingPathComponent("frame.json")))
let expected=try decoder.decode([Target].self,from:Data(contentsOf:root.appendingPathComponent("targets.json")))
let manifest=try JSONSerialization.jsonObject(with:Data(contentsOf:root.appendingPathComponent("manifest.json"))) as! [String:Any]
let expectedSHA=(manifest["nativeDailyStatesReference"] as! [String:String])["sha256"]!
let options=Dictionary(uniqueKeysWithValues:BacktestCoreDefaults.strategyAssetOptions.map{($0.symbol,$0)})
func makeFrame(_ x:Frame)->MarketDataFrame {
 MarketDataFrame(dates:x.dates.map{BacktestSeriesAlignment.historicalSeriesDate(from:$0)!},pricesBySymbol:x.pricesBySymbol,
  observedBySymbol:x.observedBySymbol,ohlcBySymbol:[:],tradableSymbols:x.tradableSymbols,
  optionBySymbol:options.filter{x.tradableSymbols.contains($0.key)},simulationRange:21...x.simulationRange[1])
}
func same(_ a:[String:Double],_ b:[String:Double]) -> Bool {
 Set(a.keys)==Set(b.keys) && a.keys.allSatisfy{a[$0]!.bitPattern==b[$0]!.bitPattern}
}
let definition=try StrategyRegistry.definition(id:"ke25")
precondition(definition.reference.version==KE25LiveStrategy.rulesVersion)
precondition(AdvancedBacktestStrategyTemplate.productCatalog.contains{$0.id=="ke25"})
precondition(definition.template.mode.defaultFeeRatePercent==0.025 && definition.template.mode.defaultSlippageRatePercent==0)
let settings=AdvancedBacktestRiskSettings(feeRate:0.025,slippageRate:0,maxPositionRatio:100,cooldownDays:0,stopLossRatio:0,takeProfitRatio:0)
let frame=makeFrame(f)
if !CommandLine.arguments.contains("--api-only") {
let targets=try KE25LiveStrategy.targets(frame:frame,nativeHistory:native)
precondition(targets.count==5735)
for row in expected {precondition(same(targets[row.sourceFrameIndex]!,row.targetWeights),"Rebuilt policy differs at source \(row.sourceFrameIndex)")}
guard let run=KE25LiveStrategy.run(frame:frame,nativeHistory:native,initialCash:100000,settings:settings) else {fatalError("KE25 real replay failed")}
let encoded=try encoder.encode(run.dailyStates)
let digest=SHA256.hash(data:encoded).map{String(format:"%02x",$0)}.joined()
precondition(digest==expectedSHA,"Original state/cash/NAV/holding/acceptedtarget hash differs: "+digest)
precondition(run.report.annualizedReturn!.bitPattern==Double(0.06513367099281142).bitPattern)
precondition(run.report.sharpeRatio!.bitPattern==Double(1.2604899693983074).bitPattern)
precondition(run.report.maxDrawdown.bitPattern==Double(0.07557506265753908).bitPattern)
print("KE25_REBUILT_POLICY_AND_FULL_STATE_PARITY_PASS states=5735 SharpeRF0=1.2604899693983074");fflush(stdout)
// Original real data, physically shortened and read again; no invented market rows.
let temporary=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try FileManager.default.createDirectory(at:temporary,withIntermediateDirectories:false)
defer {try? FileManager.default.removeItem(at:temporary)}
for cut in [313,744,2500] {
 let short=Frame(dates:Array(f.dates.prefix(cut+1)),simulationRange:[21,cut],tradableSymbols:f.tradableSymbols,
  pricesBySymbol:f.pricesBySymbol.mapValues{Array($0.prefix(cut+1))},observedBySymbol:f.observedBySymbol.mapValues{Array($0.prefix(cut+1))})
 let path=temporary.appendingPathComponent("frame-"+String(cut)+".json")
 try encoder.encode(short).write(to:path);let fresh=try decoder.decode(Frame.self,from:Data(contentsOf:path))
 let smallFrame=makeFrame(fresh),smallTargets=try KE25LiveStrategy.targets(frame:smallFrame,nativeHistory:native)
 for i in 21...cut {precondition(same(smallTargets[i]!,targets[i]!),"Future input changed historical signal")}
 guard let small=KE25LiveStrategy.run(frame:smallFrame,nativeHistory:native,initialCash:100000,settings:settings) else {fatalError("prefix run failed")}
 let shortBytes=try encoder.encode(small.dailyStates),fullPrefixBytes=try encoder.encode(Array(run.dailyStates.prefix(cut-20)))
 precondition(shortBytes==fullPrefixBytes,"Future input changed state prefix")
 print("KE25_TRUE_PRICE_POLICY_FINANCIAL_PREFIX_PASS \(cut)");fflush(stdout)
}
}
// The production factory must use the supplied real prices/OHLC, not frozen target fixtures.
let history=try decoder.decode(PublicHistoryResponse.self,from:native)
let series=Dictionary(uniqueKeysWithValues:history.series.map{($0.symbol=="nasdaq_composite" ? "nasdaq":$0.symbol,$0)})
let appOptions=BacktestCoreStrategyDefaults.assetOptions(for:definition.template)
let inputs=appOptions.map{option in BacktestCoreEngine.advancedAssetInput(for:option){series[$0]}}
guard let product=BacktestCoreEngine.runAdvancedRotationStrategyWithTrace(assetInputs:inputs,initialCash:100000,settings:settings,mode:.ke25) else {fatalError("Registered production runtime failed")}
let productSHA=SHA256.hash(data:try encoder.encode(product.dailyStates)).map{String(format:"%02x",$0)}.joined()
precondition(productSHA==expectedSHA,"App input preparation differs from original canonical frame: "+productSHA)
guard let advice=StrategyAdviceCalculator.advancedRotationRebalanceAdvice(assetInputs:inputs,mode:.ke25,settings:settings) else {fatalError("Daily advice unavailable")}
precondition(advice.asOfDate==frame.dates.last && advice.allocations.allSatisfy{$0.targetWeight>=0})
precondition(advice.allocations.reduce(0){$0+$1.targetWeight}<=1+1e-12)
print("KE25_PRODUCTION_FACTORY_AND_DAILY_ADVICE_PASS asOf=2026-09-30")
if CommandLine.arguments.count>3 && !CommandLine.arguments[3].hasPrefix("--") {
 let currentData=try Data(contentsOf:URL(fileURLWithPath:CommandLine.arguments[3]))
 let current=try decoder.decode(PublicHistoryResponse.self,from:currentData)
 let by=Dictionary(uniqueKeysWithValues:current.series.map{($0.symbol=="nasdaq_composite" ? "nasdaq":$0.symbol,$0)})
 let liveInputs=appOptions.map{option in BacktestCoreEngine.advancedAssetInput(for:option){by[$0]}}
 guard let live=StrategyAdviceCalculator.advancedRotationRebalanceAdvice(assetInputs:liveInputs,mode:.ke25,settings:settings) else {fatalError("Current real-market advice unavailable")}
 precondition(live.asOfDate > frame.dates.last!,"Live signal did not advance beyond frozen research end")
 precondition(live.allocations.reduce(0){$0+$1.targetWeight}<=1+1e-12)
 print("KE25_CURRENT_MARKET_ADVICE_PASS date=\(live.asOfDate) allocations=\(live.allocations.count)")
}
