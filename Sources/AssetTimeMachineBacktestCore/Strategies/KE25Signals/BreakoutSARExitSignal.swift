import Foundation

private func bseNeed(_ ok:Bool,_ message:String)throws {if !ok {throw NSError(domain:"BreakoutSARExit",code:1,userInfo:[NSLocalizedDescriptionKey:message])}}
private let bseSymbols=["sp500","nasdaq","csi300","shanghai_composite"]
private let bseRawSymbols=["sp500":"sp500","nasdaq":"nasdaq_composite","csi300":"csi300","shanghai_composite":"shanghai_composite"]
private struct BSERawHistory: Decodable { let series: [BSERawSeries] }
private struct BSERawSeries: Decodable {
    let symbol: String
    let dates: [String]
    let open_prices: [Double?], high_prices: [Double?], low_prices: [Double?], close_prices: [Double?]
    private enum CodingKeys: String, CodingKey {case symbol,dates,open_prices,high_prices,low_prices,close_prices}
    init(from decoder: Decoder) throws {
        let c=try decoder.container(keyedBy:CodingKeys.self)
        symbol=try c.decode(String.self,forKey:.symbol)
        // Other assets (including gold and FX) are not feature inputs and may
        // omit OHLC entirely. Decode no numeric series fields for those rows.
        if bseRawSymbols.values.contains(symbol) {
            dates=try c.decode([String].self,forKey:.dates)
            open_prices=try c.decode([Double?].self,forKey:.open_prices)
            high_prices=try c.decode([Double?].self,forKey:.high_prices)
            low_prices=try c.decode([Double?].self,forKey:.low_prices)
            close_prices=try c.decode([Double?].self,forKey:.close_prices)
        } else {dates=[];open_prices=[];high_prices=[];low_prices=[];close_prices=[]}
    }
}
private struct BSESeries {
    let symbol: String, raw: BSERawSeries, venue: String
    let available: [Date]
}
private func bseCalendar(_ venue: String) throws -> Calendar {
    guard let zone = TimeZone(identifier: venue) else { throw NSError(domain:"TimeZone",code:1) }
    var c = Calendar(identifier: .gregorian); c.timeZone = zone; return c
}
private func bseMidnight(_ civil: String, _ venue: String) throws -> Date {
    let c = try bseCalendar(venue), f = DateFormatter()
    f.calendar = c; f.timeZone = c.timeZone; f.locale = Locale(identifier:"en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd"; f.isLenient = false
    guard civil.count == 10, let d = f.date(from:civil), f.string(from:d) == civil else {
        throw NSError(domain:"InvalidCivilDate",code:1,userInfo:[NSLocalizedDescriptionKey:civil+" "+venue])
    }
    return d
}
private func bseDayEnd(_ civil: String, _ venue: String) throws -> Date {
    let c = try bseCalendar(venue), d = try bseMidnight(civil,venue)
    guard let end = c.date(byAdding:.day,value:1,to:d) else { throw NSError(domain:"CalendarDayEnd",code:1) }
    return end
}
private func bseCuts(_ frameDates: [String]) throws -> [Date] {
    var result = [Date](), previous: String?
    for d in frameDates {
        if let previous { try bseNeed(previous < d,"Canonical civil dates must strictly increase") }
        let a = try bseDayEnd(d,"America/New_York"), b = try bseDayEnd(d,"Asia/Shanghai")
        result.append(max(a,b)); previous = d
    }
    return result
}
private func bsePrepare(_ history: BSERawHistory) throws -> [String:BSESeries] {
    var result = [String:BSESeries]()
    for symbol in bseSymbols {
        let found = history.series.filter { $0.symbol == bseRawSymbols[symbol]! }
        try bseNeed(found.count == 1,"Exactly one original raw series for "+symbol)
        let r = found[0], n = r.dates.count
        try bseNeed([r.open_prices.count,r.high_prices.count,r.low_prices.count,r.close_prices.count].allSatisfy{$0==n},"Original native OHLC array alignment "+symbol)
        let venue = symbol == "sp500" || symbol == "nasdaq" ? "America/New_York":"Asia/Shanghai"
        var dates = [Date](), prior: String?
        for d in r.dates {
            if let prior { try bseNeed(prior < d,"Native duplicate/nonmonotonic date "+symbol+" "+d) }
            dates.append(try bseDayEnd(d,venue)); prior = d
        }
        result[symbol] = BSESeries(symbol:symbol,raw:r,venue:venue,available:dates)
    }
    return result
}
private func bseLatest(_ dates: [Date], _ cut: Date) -> Int {
    var lo=0, hi=dates.count
    while lo < hi { let m=(lo+hi)/2; if dates[m] <= cut { lo=m+1 } else { hi=m } }
    return lo-1
}
private func bseValidBar(_ r: BSERawSeries, _ j: Int) -> Bool {
    guard let o=r.open_prices[j],let h=r.high_prices[j],let l=r.low_prices[j],let c=r.close_prices[j] else { return false }
    return [o,h,l,c].allSatisfy{$0.isFinite && $0>0} && l<=min(o,c) && h>=max(o,c) && l<=h
}


struct BreakoutSARExitRow:Codable {
 let index:Int,symbol:String,civilDate:String,control:Int
 let known:Bool,fresh:Bool,permission:Bool,entryEvent:Bool,exitEvent:Bool,entered:Bool,exited:Bool
 let sourceCutAt:Date,nativeIndex:Int?,nativeDate:String?,availableAt:Date?,nativeTupleKey:String?
 let breakout:Bool?,prior20High:Double?,prior10Low:Double?,entryLow:Double?
 let stopBefore:Double?,stopAfter:Double?,epBefore:Double?,epAfter:Double?,afBefore:Double?,afAfter:Double?
 let holdingBefore:Bool,holdingAfter:Bool,episodeID:String?,seenBefore:Bool,seenAfter:Bool
 let features:[String:Double],indices:[String:Int],reasons:[String]
}
enum BreakoutSARExitSignal {
 static let symbols=bseSymbols
 private struct Episode {
  let id:String,entryIndex:Int,entryLow:Double
  var stop:Double,ep:Double,af:Double
 }
 private static func close(_ a:Double,_ b:Double)->Bool {a.isFinite && b.isFinite && abs(a-b)<=1e-12*max(1,abs(a))}
 private static func numeric(_ values:[(String,Double)],_ symbol:String,_ i:Int,_ j:Int)throws {
  if !values.allSatisfy({$0.1.isFinite}) {
   let text=values.map{$0.0+"="+String($0.1)+"[bits="+String($0.1.bitPattern,radix:16)+"]"}.joined(separator:";")
   throw NSError(domain:"BreakoutSARExit",code:2,userInfo:[NSLocalizedDescriptionKey:"NONFINITE source=\(i) native=\(j) symbol=\(symbol);\(text)"])
  }
 }
 static func soubseeCut(_ civil:String)throws->Date {max(try bseDayEnd(civil,"America/New_York"),try bseDayEnd(civil,"Asia/Shanghai"))}
 static func truncateHistory(historyData data:Data,cutoffCivilDate:String)throws->Data {
  let cut=try soubseeCut(cutoffCivilDate)
  let prepared=try bsePrepare(JSONDecoder().decode(BSERawHistory.self,from:data))
  var object=try JSONSerialization.jsonObject(with:data) as! [String:Any]
  let raw=object["series"] as! [[String:Any]]
  object["series"]=try raw.compactMap { original -> [String:Any]? in
   guard let rawSymbol=original["symbol"] as? String,let symbol=bseRawSymbols.first(where:{$0.value==rawSymbol})?.key else{return nil}
   let s=prepared[symbol]!,count=bseLatest(s.available,cut)+1
   var row=original
   for key in Array(row.keys) {if let values=row[key] as? [Any],values.count==s.raw.dates.count {row[key]=Array(values.prefix(count))}}
   return row
  }
  return try JSONSerialization.data(withJSONObject:object,options:[.sortedKeys])
 }

 static func build(frameDates:[String],historyData:Data,control:Int)throws->[String:[BreakoutSARExitRow]] {
  try bseNeed((0...2).contains(control),"Only entry-anchored SAR/channel/fixed-entry controls")
  let series=try bsePrepare(JSONDecoder().decode(BSERawHistory.self,from:historyData)),cuts=try bseCuts(frameDates)
  var result=Dictionary(uniqueKeysWithValues:bseSymbols.map{($0,[BreakoutSARExitRow]())})
  var pointers=Dictionary(uniqueKeysWithValues:bseSymbols.map{($0,-1)}),priorProcessed=[String:Int]()
  var seen=[String:Set<String>](),lastConsumed=[String:String](),episodes=[String:Episode]()
  for i in frameDates.indices {for symbol in symbols {
   let s=series[symbol]!,r=s.raw,cut=cuts[i],prior=priorProcessed[symbol],before=episodes[symbol]
   var j=pointers[symbol]!;while j+1<s.available.count && s.available[j+1]<=cut {j+=1};pointers[symbol]=j
   try bseNeed(j==bseLatest(s.available,cut),"Latest native pointer/binary identity")
   let exists=j>=0
   var reasons=[String](),indices=["sourceIndex":i],features=["control":Double(control),"entryLookback":20.0,"channelExitLookback":10.0,"valueTolerance":1e-12]
   if let prior {indices["previousProcessedNativeIndex"]=prior}
   var rawQualified=false,high20:Double?,low10:Double?,breakout:Bool?,key:String?,fresh=false,seenBefore=false,seenAfter=false
   if !exists {reasons.append("NO_AVAILABLE_NATIVE_BAR")} else {
    indices["currentNativeIndex"]=j
    try bseNeed(s.available[j]<=cut,"Current native available by D0")
    if j<20 {reasons.append("TWENTY_EXACT_PRIOR_NATIVE_BARS_NOT_READY")}
    else {
     indices["entryWindowFirstNativeIndex"]=j-20;indices["entryWindowLastNativeIndex"]=j-1
     indices["exitWindowFirstNativeIndex"]=j-10
     let valid=(j-20...j).allSatisfy{bseValidBar(r,$0)}
     let publicBars=symbol != "csi300" || (j-20...j).allSatisfy{r.dates[$0]>="2005-04-08"}
     if !valid {reasons.append("USED_21_NATIVE_OHLC_INVALID_OR_MISSING")}
     if !publicBars {reasons.append("CSI_USED_21_NATIVE_BARS_PREPUBLIC")}
     rawQualified=valid && publicBars
     if rawQualified {
      let highs=(j-20..<j).map{r.high_prices[$0]!},lows=(j-10..<j).map{r.low_prices[$0]!}
      let hi=highs.max()!,lo=lows.min()!,c=r.close_prices[j]!
      try bseNeed(hi.bitPattern==highs.sorted().last!.bitPattern && lo.bitPattern==lows.sorted().first!.bitPattern,"Prior high/low independent enumeration/sort bounds")
      let br=c>hi
      try bseNeed(br == highs.allSatisfy{c>$0},"Strict breakout max/direct all-prior comparisons")
      high20=hi;low10=lo;breakout=br
      let k=r.dates[j]+"|"+r.dates[j-20];key=k
      seenBefore=seen[symbol,default:[]].contains(k);fresh=lastConsumed[symbol] != k
      try bseNeed(fresh == !seenBefore,"First latest tuple consumption last/set identity")
      // Consume raw-qualified identities even on a subsequent gap UNKNOWN.
      // Otherwise the same selected bar could be replayed after the reset.
      if fresh {lastConsumed[symbol]=k;seen[symbol,default:[]].insert(k)}
      seenAfter=seen[symbol,default:[]].contains(k)
     }
    }
    if let prior,j>prior+1 {reasons.append("NATIVE_GAP_IN_EPISODE");features["skippedNativeBars"]=Double(j-prior-1)}
    priorProcessed[symbol]=j
   }
   let known=reasons.isEmpty
   var state=before,entered=false,exited=false
   if !known {state=nil}
   else if fresh {
    let low=r.low_prices[j]!,high=r.high_prices[j]!,previousLow=r.low_prices[j-1]!
    if var held=state {
     let boundary=control==1 ? low10!:held.stop
     let exit=low<=boundary
     try bseNeed(exit == !(low>boundary) && exit == ((low-boundary)<=0),"Exact completed-bar stop touch without economic epsilon")
     features["exitBoundary"]=boundary
     if exit {state=nil;exited=true}
     else if control==0 {
      let nextEP=max(held.ep,high),nextAF=high>held.ep ? min(0.2,held.af+0.02):held.af
      let rawNext=held.stop+nextAF*(nextEP-held.stop),nextStop=min(rawNext,low,previousLow)
      let independentEP=high>held.ep ? high:held.ep
      var independentAF=held.af
      if high>held.ep {independentAF=held.af+0.02;if independentAF>0.2 {independentAF=0.2}}
      let independentRaw=(1-independentAF)*held.stop+independentAF*independentEP
      let independentStop=[independentRaw,low,previousLow].sorted().first!
      let values=[("previousStop",held.stop),("nextEP",nextEP),("nextAF",nextAF),("rawNextStop",rawNext),("nextStop",nextStop),("independentRawStop",independentRaw),("independentStop",independentStop)]
      try numeric(values,symbol,i,j)
      try bseNeed(nextEP.bitPattern==independentEP.bitPattern && nextAF.bitPattern==independentAF.bitPattern && close(rawNext,independentRaw) && close(nextStop,independentStop),"Independent entry-anchored long SAR update values")
      try bseNeed(nextStop>=held.stop && nextStop<=low && nextStop<=previousLow && nextAF>=0.02 && nextAF<=0.2,"Monotone surviving stop and declared AF/clamps")
      features["rawNextStop"]=rawNext;features["independentRawNextStop"]=independentRaw;features["independentNextStop"]=independentStop
      held.stop=nextStop;held.ep=nextEP;held.af=nextAF;state=held
     } else if control==1 {
      // Boundary for this row was the exact prior10 low; next row recomputes it.
      // Keep the current boundary in diagnostics, not an invented ratchet.
      held.stop=boundary;state=held
     }
    } else if breakout==true {
     let id=symbol+"|"+r.dates[j]+"|source:"+String(i)
     state=Episode(id:id,entryIndex:j,entryLow:low,stop:low,ep:high,af:0.02);entered=true
    }
   }
   try bseNeed(!(entered && exited) && (!entered || (known && fresh && before==nil && breakout==true)) && (!exited || (known && fresh && before != nil)),"Exit priority, no same-row reentry or nonfresh events")
   if !known {try bseNeed(state==nil,"Shared UNKNOWN clears every independent policy episode")}
   if known && !fresh {
    try bseNeed(state?.id==before?.id && state?.stop.bitPattern==before?.stop.bitPattern && state?.ep.bitPattern==before?.ep.bitPattern && state?.af.bitPattern==before?.af.bitPattern,"Nonfresh retains prior episode exactly")
   }
   if let state {episodes[symbol]=state;indices["entryNativeIndex"]=state.entryIndex} else {episodes.removeValue(forKey:symbol)}
   let permission=known && state != nil
   features["rawQualified"]=rawQualified ? 1:0;features["unknownReset"]=known ? 0:1
   result[symbol]!.append(BreakoutSARExitRow(index:i,symbol:symbol,civilDate:frameDates[i],control:control,
    known:known,fresh:fresh,permission:permission,entryEvent:entered,exitEvent:exited,entered:entered,exited:exited,
    sourceCutAt:cut,nativeIndex:exists ? j:nil,nativeDate:exists ? r.dates[j]:nil,availableAt:exists ? s.available[j]:nil,nativeTupleKey:key,
    breakout:breakout,prior20High:high20,prior10Low:low10,entryLow:state?.entryLow ?? before?.entryLow,
    stopBefore:before?.stop,stopAfter:state?.stop,epBefore:before?.ep,epAfter:state?.ep,afBefore:before?.af,afAfter:state?.af,
    holdingBefore:before != nil,holdingAfter:state != nil,episodeID:state?.id ?? before?.id,seenBefore:seenBefore,seenAfter:seenAfter,
    features:features,indices:indices,reasons:reasons))
  }}
  return result
 }
}
