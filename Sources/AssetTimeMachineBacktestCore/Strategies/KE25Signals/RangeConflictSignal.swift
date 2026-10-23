import Foundation

private func rcNeed(_ ok:Bool,_ message:String)throws {if !ok {throw NSError(domain:"RangeConflict",code:1,userInfo:[NSLocalizedDescriptionKey:message])}}
private let rcSymbols=["sp500","nasdaq","csi300","shanghai_composite"]
private let rcRawSymbols=["sp500":"sp500","nasdaq":"nasdaq_composite","csi300":"csi300","shanghai_composite":"shanghai_composite"]
private struct RCRawHistory: Decodable { let series: [RCRawSeries] }
private struct RCRawSeries: Decodable {
    let symbol: String
    let dates: [String]
    let open_prices: [Double?], high_prices: [Double?], low_prices: [Double?], close_prices: [Double?]
    private enum CodingKeys: String, CodingKey {case symbol,dates,open_prices,high_prices,low_prices,close_prices}
    init(from decoder: Decoder) throws {
        let c=try decoder.container(keyedBy:CodingKeys.self)
        symbol=try c.decode(String.self,forKey:.symbol)
        // Other assets (including gold and FX) are not feature inputs and may
        // omit OHLC entirely. Decode no numeric series fields for those rows.
        if rcRawSymbols.values.contains(symbol) {
            dates=try c.decode([String].self,forKey:.dates)
            open_prices=try c.decode([Double?].self,forKey:.open_prices)
            high_prices=try c.decode([Double?].self,forKey:.high_prices)
            low_prices=try c.decode([Double?].self,forKey:.low_prices)
            close_prices=try c.decode([Double?].self,forKey:.close_prices)
        } else {dates=[];open_prices=[];high_prices=[];low_prices=[];close_prices=[]}
    }
}
private struct RCSeries {
    let symbol: String, raw: RCRawSeries, venue: String
    let available: [Date]
}
private func rcCalendar(_ venue: String) throws -> Calendar {
    guard let zone = TimeZone(identifier: venue) else { throw NSError(domain:"TimeZone",code:1) }
    var c = Calendar(identifier: .gregorian); c.timeZone = zone; return c
}
private func rcMidnight(_ civil: String, _ venue: String) throws -> Date {
    let c = try rcCalendar(venue), f = DateFormatter()
    f.calendar = c; f.timeZone = c.timeZone; f.locale = Locale(identifier:"en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd"; f.isLenient = false
    guard civil.count == 10, let d = f.date(from:civil), f.string(from:d) == civil else {
        throw NSError(domain:"InvalidCivilDate",code:1,userInfo:[NSLocalizedDescriptionKey:civil+" "+venue])
    }
    return d
}
private func rcDayEnd(_ civil: String, _ venue: String) throws -> Date {
    let c = try rcCalendar(venue), d = try rcMidnight(civil,venue)
    guard let end = c.date(byAdding:.day,value:1,to:d) else { throw NSError(domain:"CalendarDayEnd",code:1) }
    return end
}
private func rcCuts(_ frameDates: [String]) throws -> [Date] {
    var result = [Date](), previous: String?
    for d in frameDates {
        if let previous { try rcNeed(previous < d,"Canonical civil dates must strictly increase") }
        let a = try rcDayEnd(d,"America/New_York"), b = try rcDayEnd(d,"Asia/Shanghai")
        result.append(max(a,b)); previous = d
    }
    return result
}
private func rcPrepare(_ history: RCRawHistory) throws -> [String:RCSeries] {
    var result = [String:RCSeries]()
    for symbol in rcSymbols {
        let found = history.series.filter { $0.symbol == rcRawSymbols[symbol]! }
        try rcNeed(found.count == 1,"Exactly one original raw series for "+symbol)
        let r = found[0], n = r.dates.count
        try rcNeed([r.open_prices.count,r.high_prices.count,r.low_prices.count,r.close_prices.count].allSatisfy{$0==n},"Original native OHLC array alignment "+symbol)
        let venue = symbol == "sp500" || symbol == "nasdaq" ? "America/New_York":"Asia/Shanghai"
        var dates = [Date](), prior: String?
        for d in r.dates {
            if let prior { try rcNeed(prior < d,"Native duplicate/nonmonotonic date "+symbol+" "+d) }
            dates.append(try rcDayEnd(d,venue)); prior = d
        }
        result[symbol] = RCSeries(symbol:symbol,raw:r,venue:venue,available:dates)
    }
    return result
}
private func rcLatest(_ dates: [Date], _ cut: Date) -> Int {
    var lo=0, hi=dates.count
    while lo < hi { let m=(lo+hi)/2; if dates[m] <= cut { lo=m+1 } else { hi=m } }
    return lo-1
}
private func rcValidBar(_ r: RCRawSeries, _ j: Int) -> Bool {
    guard let o=r.open_prices[j],let h=r.high_prices[j],let l=r.low_prices[j],let c=r.close_prices[j] else { return false }
    return [o,h,l,c].allSatisfy{$0.isFinite && $0>0} && l<=min(o,c) && h>=max(o,c) && l<=h
}

struct RangeConflictRow:Codable {
 let index:Int,symbol:String,rawSymbol:String,venue:String,civilDate:String
 let sourceCutAt:Date,nativeIndex:Int?,previousIndex:Int?,nativeDate:String?,previousDate:String?,availableAt:Date?,previousAvailableAt:Date?
 let open:Double?,high:Double?,low:Double?,close:Double?,previousOpen:Double?,previousHigh:Double?,previousLow:Double?,previousClose:Double?
 let known:Bool,fresh:Bool,nativeTupleKey:String?,upClose:Bool?,downRange:Bool?,event:Bool,veto:Bool,expiry:Int?,pause:Int,control:Int,reasons:[String]
}
enum RangeConflictSignal {
 static let symbols=rcSymbols
 static func sourceCut(_ civil:String)throws->Date {max(try rcDayEnd(civil,"America/New_York"),try rcDayEnd(civil,"Asia/Shanghai"))}
 static func truncateHistory(historyData data:Data,cutoffCivilDate:String)throws->Data {
  let cut=try sourceCut(cutoffCivilDate)
  let prepared=try rcPrepare(JSONDecoder().decode(RCRawHistory.self,from:data))
  var object=try JSONSerialization.jsonObject(with:data) as! [String:Any]
  let raw=object["series"] as! [[String:Any]]
  object["series"]=try raw.compactMap { original -> [String:Any]? in
   guard let rawSymbol=original["symbol"] as? String,let symbol=rcRawSymbols.first(where:{$0.value==rawSymbol})?.key else{return nil}
   let s=prepared[symbol]!,count=rcLatest(s.available,cut)+1
   var row=original
   for key in Array(row.keys) {if let values=row[key] as? [Any],values.count==s.raw.dates.count {row[key]=Array(values.prefix(count))}}
   return row
  }
  return try JSONSerialization.data(withJSONObject:object,options:[.sortedKeys])
 }
 static func build(frameDates:[String],historyData:Data,pause:Int,control:Int)throws->[String:[RangeConflictRow]] {
  try rcNeed([1,3,5].contains(pause) && (0...2).contains(control) && (control==0 || pause==3),"Declared range conflict configuration")
  let series=try rcPrepare(JSONDecoder().decode(RCRawHistory.self,from:historyData)),sourceCuts=try rcCuts(frameDates)
  var result=Dictionary(uniqueKeysWithValues:rcSymbols.map{($0,[RangeConflictRow]())})
  var pointers=Dictionary(uniqueKeysWithValues:rcSymbols.map{($0,-1)}),lastConsumed=[String:String](),seen=[String:Set<String>](),expiries=[String:Int]()
  for i in frameDates.indices {for symbol in rcSymbols {
   let s=series[symbol]!,r=s.raw,cut=sourceCuts[i]
   var j=pointers[symbol]!;while j+1<s.available.count && s.available[j+1]<=cut {j+=1};pointers[symbol]=j
   try rcNeed(j==rcLatest(s.available,cut),"Native latest pointer/binary identity")
   let exists=j>=0,previous=j>=1
   var reasons=[String]()
   if !exists {reasons.append("NO_AVAILABLE_NATIVE_BAR")} else {
    try rcNeed(s.available[j]<=cut,"Selected native availability")
    if !rcValidBar(r,j){reasons.append("CURRENT_OHLC_INVALID_OR_MISSING")}
    if !previous {reasons.append("NO_EXACT_PREVIOUS_NATIVE_INDEX")} else {
     try rcNeed(s.available[j-1]<s.available[j] && s.available[j-1]<=cut,"Exact previous native availability")
     if !rcValidBar(r,j-1){reasons.append("PREVIOUS_OHLC_INVALID_OR_MISSING")}
    }
    if symbol=="csi300" && (r.dates[j]<"2005-04-08" || (previous && r.dates[j-1]<"2005-04-08")){reasons.append("CSI_USED_BAR_PREPUBLIC")}
   }
   let known=reasons.isEmpty
   var fresh=false,key:String?,a:Bool?,d:Bool?,event=false
   if known {
    let c=r.close_prices[j]!,pc=r.close_prices[j-1]!,h=r.high_prices[j]!,ph=r.high_prices[j-1]!,l=r.low_prices[j]!,pl=r.low_prices[j-1]!
    let up=c>pc,down=h<ph && l<pl
    try rcNeed(up==((c-pc)>0) && down==((h-ph)<0 && (l-pl)<0),"Strict direct/difference sign parity")
    a=up;d=down;let k=r.dates[j]+"|"+r.dates[j-1];key=k
    fresh=lastConsumed[symbol] != k
    try rcNeed(fresh == !(seen[symbol] ?? []).contains(k),"First native consumption last-key/set parity")
    if fresh {lastConsumed[symbol]=k;seen[symbol,default:[]].insert(k)}
    // Unknown never clears consumed identities. Pre21 consumes but cannot pause.
    event=i>=21 && fresh && (control==1 ? up : control==2 ? down : up && down)
    if event {expiries[symbol]=max(expiries[symbol] ?? -1,i+pause-1)}
   }else {expiries.removeValue(forKey:symbol)}
   let expiry=expiries[symbol],veto=known && i>=21 && (expiry.map{i<=$0} ?? false)
   // Independent finite-window definition uses actual retained rows, not
   // the expiry recursion. Unknown interrupts every previous pause.
   var independentVeto=false
   if known && i>=21 {
    let first=max(21,i-pause+1)
    for j in stride(from:i,through:first,by:-1) {
     if j==i {if event {independentVeto=true;break}}
     else {
      let past=result[symbol]![j]
      if !past.known {break}
      if past.fresh && past.event {independentVeto=true;break}
     }
    }
   }
   try rcNeed(veto==independentVeto,"Expiry veto equals independent real-row tail-H events with UNKNOWN barrier")
   result[symbol]!.append(RangeConflictRow(index:i,symbol:symbol,rawSymbol:r.symbol,venue:s.venue,civilDate:frameDates[i],sourceCutAt:cut,
    nativeIndex:exists ? j:nil,previousIndex:previous ? j-1:nil,nativeDate:exists ? r.dates[j]:nil,previousDate:previous ? r.dates[j-1]:nil,
    availableAt:exists ? s.available[j]:nil,previousAvailableAt:previous ? s.available[j-1]:nil,
    open:exists ? r.open_prices[j]:nil,high:exists ? r.high_prices[j]:nil,low:exists ? r.low_prices[j]:nil,close:exists ? r.close_prices[j]:nil,
    previousOpen:previous ? r.open_prices[j-1]:nil,previousHigh:previous ? r.high_prices[j-1]:nil,previousLow:previous ? r.low_prices[j-1]:nil,previousClose:previous ? r.close_prices[j-1]:nil,
    known:known,fresh:fresh,nativeTupleKey:key,upClose:a,downRange:d,event:event,veto:veto,expiry:expiry,pause:pause,control:control,reasons:reasons))
  }}
  return result
 }
}
