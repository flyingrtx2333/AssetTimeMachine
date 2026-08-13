import Foundation

private struct DevSet { let name:String; let history:PublicHistoryResponse; let symbols:[String] }
private struct Row {
    let config:AssetAgnosticStrategyConfig; let results:[(String,AssetAgnosticBacktestResult)]
    var worstS:Double{results.map{$0.1.performance.sharpeRatio}.min() ?? -.infinity}
    var worstMDD:Double{results.map{$0.1.performance.maxDrawdown}.max() ?? .infinity}
    var worstCAGR:Double{results.map{$0.1.performance.annualizedReturn}.min() ?? -.infinity}
    var turn:Double{results.reduce(0){$0+$1.1.performance.turnover}}
    var score:Double{worstS-1.5*max(worstMDD-0.25,0)-0.001*turn}
}
@main private enum Main{
 static func main()throws{
  let root=URL(fileURLWithPath:FileManager.default.currentDirectoryPath)
  let h1=try load(root.appendingPathComponent("tools/fixtures/backtest-history/asset_agnostic_final_holdout.json"))
  let h2=try load(root.appendingPathComponent("tools/fixtures/backtest-history/asset_agnostic_final_holdout_v3.json"))
  let hd=try load(root.appendingPathComponent("tools/fixtures/backtest-history/generalization_public_history.json"))
  let av=Set(hd.series.map(\.symbol)); let ds=[["dow_jones","dowjones"],["hang_seng","hsi"],["nikkei225","nikkei"],["shenzhen_component"],["chinext"],["oil_wti_cny"]].compactMap{$0.first(where:{av.contains($0)})}
  let sets=[DevSet(name:"country_v2",history:h1,symbols:h1.series.map(\.symbol)),DevSet(name:"country_v3",history:h2,symbols:h2.series.map(\.symbol)),DevSet(name:"diagnostic",history:hd,symbols:ds)]
  var rows:[Row]=[]
  for vol in [0.070,0.075,0.080]{for band in [0.50,0.55,0.60]{for threshold in [0.32,0.36,0.40]{
   let c=AssetAgnosticStrategyConfig(warmupSessions:252,reviewSessions:105,shortMomentumSessions:63,mediumMomentumSessions:105,longMomentumSessions:252,trendMASessions:250,volatilitySessions:63,covarianceSessions:63,targetAnnualizedVolatility:vol,maxAssetWeight:0.20,maxAssets:8,rebalanceBand:band,targetTurnoverThreshold:threshold,feeRate:0.01,slippageRate:0.0005)
   let rr=sets.compactMap{set->(String,AssetAgnosticBacktestResult)? in guard let r=AssetAgnosticBacktestEngine.runSparseV3(history:set.history,symbols:set.symbols,config:c)else{return nil};return(set.name,r)}
   if rr.count==sets.count{rows.append(.init(config:c,results:rr))}
  }}}
  let ranked=rows.sorted{if abs($0.score-$1.score)>1e-12{return $0.score>$1.score};if abs($0.worstS-$1.worstS)>1e-12{return $0.worstS>$1.worstS};return $0.turn<$1.turn}
  print("V4_FINAL_LOCAL_GRID candidates=\(ranked.count)")
  for(rank,row)in ranked.enumerated(){let c=row.config;let detail=row.results.map{name,r in String(format:"%@ S %.3f MDD %.2f%% CAGR %.2f%%",name,r.performance.sharpeRatio,r.performance.maxDrawdown*100,r.performance.annualizedReturn*100)}.joined(separator:" | ");print(String(format:"#%02d score %.3f vol %.3f band %.2f threshold %.2f | worstS %.3f worstMDD %.2f%% worstCAGR %.2f%% turn %.2fx | %@",rank+1,row.score,c.targetAnnualizedVolatility,c.rebalanceBand,c.targetTurnoverThreshold,row.worstS,row.worstMDD*100,row.worstCAGR*100,row.turn,detail))}
 }
 static func load(_ u:URL)throws->PublicHistoryResponse{try JSONDecoder().decode(PublicHistoryResponse.self,from:Data(contentsOf:u))}
}
