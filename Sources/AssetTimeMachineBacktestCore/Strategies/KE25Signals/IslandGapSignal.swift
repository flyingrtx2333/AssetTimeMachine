import Foundation

private func igNeed(_ ok:Bool,_ message:String)throws {if !ok {throw NSError(domain:"IslandGap",code:1,userInfo:[NSLocalizedDescriptionKey:message])}}
private let igSymbols=["sp500","nasdaq","csi300","shanghai_composite"]
private let igRawSymbols=["sp500":"sp500","nasdaq":"nasdaq_composite","csi300":"csi300","shanghai_composite":"shanghai_composite"]
private struct IGRawHistory: Decodable { let series: [IGRawSeries] }
private struct IGRawSeries: Decodable {
    let symbol: String
    let dates: [String]
    let open_prices: [Double?], high_prices: [Double?], low_prices: [Double?], close_prices: [Double?]
    private enum CodingKeys: String, CodingKey {case symbol,dates,open_prices,high_prices,low_prices,close_prices}
    init(from decoder: Decoder) throws {
        let c=try decoder.container(keyedBy:CodingKeys.self)
        symbol=try c.decode(String.self,forKey:.symbol)
        // Other assets (including gold and FX) are not feature inputs and may
        // omit OHLC entirely. Decode no numeric series fields for those rows.
        if igRawSymbols.values.contains(symbol) {
            dates=try c.decode([String].self,forKey:.dates)
            open_prices=try c.decode([Double?].self,forKey:.open_prices)
            high_prices=try c.decode([Double?].self,forKey:.high_prices)
            low_prices=try c.decode([Double?].self,forKey:.low_prices)
            close_prices=try c.decode([Double?].self,forKey:.close_prices)
        } else {dates=[];open_prices=[];high_prices=[];low_prices=[];close_prices=[]}
    }
}
private struct IGSeries {
    let symbol: String, raw: IGRawSeries, venue: String
    let available: [Date]
}
private func igCalendar(_ venue: String) throws -> Calendar {
    guard let zone = TimeZone(identifier: venue) else { throw NSError(domain:"TimeZone",code:1) }
    var c = Calendar(identifier: .gregorian); c.timeZone = zone; return c
}
private func igMidnight(_ civil: String, _ venue: String) throws -> Date {
    let c = try igCalendar(venue), f = DateFormatter()
    f.calendar = c; f.timeZone = c.timeZone; f.locale = Locale(identifier:"en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd"; f.isLenient = false
    guard civil.count == 10, let d = f.date(from:civil), f.string(from:d) == civil else {
        throw NSError(domain:"InvalidCivilDate",code:1,userInfo:[NSLocalizedDescriptionKey:civil+" "+venue])
    }
    return d
}
private func igDayEnd(_ civil: String, _ venue: String) throws -> Date {
    let c = try igCalendar(venue), d = try igMidnight(civil,venue)
    guard let end = c.date(byAdding:.day,value:1,to:d) else { throw NSError(domain:"CalendarDayEnd",code:1) }
    return end
}
private func igCuts(_ frameDates: [String]) throws -> [Date] {
    var result = [Date](), previous: String?
    for d in frameDates {
        if let previous { try igNeed(previous < d,"Canonical civil dates must strictly increase") }
        let a = try igDayEnd(d,"America/New_York"), b = try igDayEnd(d,"Asia/Shanghai")
        result.append(max(a,b)); previous = d
    }
    return result
}
private func igPrepare(_ history: IGRawHistory) throws -> [String:IGSeries] {
    var result = [String:IGSeries]()
    for symbol in igSymbols {
        let found = history.series.filter { $0.symbol == igRawSymbols[symbol]! }
        try igNeed(found.count == 1,"Exactly one original raw series for "+symbol)
        let r = found[0], n = r.dates.count
        try igNeed([r.open_prices.count,r.high_prices.count,r.low_prices.count,r.close_prices.count].allSatisfy{$0==n},"Original native OHLC array alignment "+symbol)
        let venue = symbol == "sp500" || symbol == "nasdaq" ? "America/New_York":"Asia/Shanghai"
        var dates = [Date](), prior: String?
        for d in r.dates {
            if let prior { try igNeed(prior < d,"Native duplicate/nonmonotonic date "+symbol+" "+d) }
            dates.append(try igDayEnd(d,venue)); prior = d
        }
        result[symbol] = IGSeries(symbol:symbol,raw:r,venue:venue,available:dates)
    }
    return result
}
private func igLatest(_ dates: [Date], _ cut: Date) -> Int {
    var lo=0, hi=dates.count
    while lo < hi { let m=(lo+hi)/2; if dates[m] <= cut { lo=m+1 } else { hi=m } }
    return lo-1
}
private func igValidBar(_ r: IGRawSeries, _ j: Int) -> Bool {
    guard let o=r.open_prices[j],let h=r.high_prices[j],let l=r.low_prices[j],let c=r.close_prices[j] else { return false }
    return [o,h,l,c].allSatisfy{$0.isFinite && $0>0} && l<=min(o,c) && h>=max(o,c) && l<=h
}

// Completed exact three-native-bar source observation. Missing fields stay
// optional; an UNKNOWN row never substitutes zeros or skips a bad native row.
struct IslandGapRow:Codable {
 let index:Int,symbol:String,rawSymbol:String,venue:String,civilDate:String
 let sourceCutAt:Date
 let nativeIndex:Int?,previousIndex:Int?,previousPreviousIndex:Int?
 let nativeDate:String?,previousDate:String?,previousPreviousDate:String?
 let availableAt:Date?,previousAvailableAt:Date?,previousPreviousAvailableAt:Date?
 let open:Double?,high:Double?,low:Double?,close:Double?
 let previousOpen:Double?,previousHigh:Double?,previousLow:Double?,previousClose:Double?
 let previousPreviousOpen:Double?,previousPreviousHigh:Double?,previousPreviousLow:Double?,previousPreviousClose:Double?
 let known:Bool,fresh:Bool,nativeTupleKey:String?
 let upGap:Bool?,downGap:Bool?,island:Bool?
 let event:Bool,veto:Bool,expiry:Int?,pause:Int,control:Int,reasons:[String]
}
enum IslandGapSignal {
 static let symbols=igSymbols
 static func sourceCut(_ civil:String)throws->Date {
  max(try igDayEnd(civil,"America/New_York"),try igDayEnd(civil,"Asia/Shanghai"))
 }
 static func truncateHistory(historyData data:Data,cutoffCivilDate:String)throws->Data {
  let cut=try sourceCut(cutoffCivilDate)
  let prepared=try igPrepare(JSONDecoder().decode(IGRawHistory.self,from:data))
  var object=try JSONSerialization.jsonObject(with:data) as! [String:Any]
  let raw=object["series"] as! [[String:Any]]
  object["series"]=try raw.compactMap { original -> [String:Any]? in
   guard let rawSymbol=original["symbol"] as? String,let symbol=igRawSymbols.first(where:{$0.value==rawSymbol})?.key else{return nil}
   let s=prepared[symbol]!,count=igLatest(s.available,cut)+1
   var row=original
   for key in Array(row.keys) {
    if let values=row[key] as? [Any],values.count==s.raw.dates.count {row[key]=Array(values.prefix(count))}
   }
   return row
  }
  return try JSONSerialization.data(withJSONObject:object,options:[.sortedKeys])
 }
 static func build(frameDates:[String],historyData:Data,pause:Int,control:Int)throws->[String:[IslandGapRow]] {
  try igNeed(pause==3 && (0...2).contains(control),"Only declared island H3 and candidate/U-only/D-only configurations")
  let series=try igPrepare(JSONDecoder().decode(IGRawHistory.self,from:historyData)),sourceCuts=try igCuts(frameDates)
  var result=Dictionary(uniqueKeysWithValues:igSymbols.map{($0,[IslandGapRow]())})
  var pointers=Dictionary(uniqueKeysWithValues:igSymbols.map{($0,-1)})
  var lastConsumed=[String:String](),seen=[String:Set<String>](),expiries=[String:Int]()
  for i in frameDates.indices {for symbol in igSymbols {
   let s=series[symbol]!,r=s.raw,cut=sourceCuts[i]
   var j=pointers[symbol]!
   while j+1<s.available.count && s.available[j+1]<=cut {j+=1}
   pointers[symbol]=j
   try igNeed(j==igLatest(s.available,cut),"Native latest pointer/binary identity")
   let exists=j>=0,previous=j>=1,previousPrevious=j>=2
   var reasons=[String]()
   if !exists {reasons.append("NO_AVAILABLE_NATIVE_BAR")} else {
    try igNeed(s.available[j]<=cut,"Selected native availability")
    if !igValidBar(r,j) {reasons.append("CURRENT_OHLC_INVALID_OR_MISSING")}
    if !previous {reasons.append("NO_EXACT_PREVIOUS_NATIVE_INDEX")} else {
     try igNeed(s.available[j-1]<s.available[j] && s.available[j-1]<=cut,"Exact previous native availability")
     if !igValidBar(r,j-1) {reasons.append("PREVIOUS_OHLC_INVALID_OR_MISSING")}
    }
    if !previousPrevious {reasons.append("NO_EXACT_PREVIOUS_PREVIOUS_NATIVE_INDEX")} else {
     try igNeed(s.available[j-2]<s.available[j-1] && s.available[j-2]<=cut,"Exact previous-previous native availability")
     if !igValidBar(r,j-2) {reasons.append("PREVIOUS_PREVIOUS_OHLC_INVALID_OR_MISSING")}
    }
    if symbol=="csi300" && (r.dates[j]<"2005-04-08" || (previous && r.dates[j-1]<"2005-04-08") || (previousPrevious && r.dates[j-2]<"2005-04-08")) {
     reasons.append("CSI_USED_BAR_PREPUBLIC")
    }
   }
   let known=reasons.isEmpty
   var fresh=false,key:String?,u:Bool?,d:Bool?,e:Bool?,event=false
   if known {
    let middleLow=r.low_prices[j-1]!,leftHigh=r.high_prices[j-2]!,rightHigh=r.high_prices[j]!
    let up=middleLow>leftHigh,down=rightHigh<middleLow,island=up && down
    try igNeed(up==((middleLow-leftHigh)>0) && down==((rightHigh-middleLow)<0),"Strict U/D direct versus difference sign parity")
    let independentIsland=middleLow>max(leftHigh,rightHigh)
    try igNeed(island==independentIsland,"Two real full-range gaps equal independent isolated-middle-low comparison")
    if island {try igNeed(r.close_prices[j]!<r.close_prices[j-1]!,"Completed island entails strictly falling current close")}
    u=up;d=down;e=island
    let k=r.dates[j]+"|"+r.dates[j-1]+"|"+r.dates[j-2]
    key=k;fresh=lastConsumed[symbol] != k
    try igNeed(fresh == !(seen[symbol] ?? []).contains(k),"Three-native-tuple first consumption last-key/set parity")
    if fresh {lastConsumed[symbol]=k;seen[symbol,default:[]].insert(k)}
    // Pre21 consumes source identity but never opens a pause. All three
    // policies share the same legal three-bar qualification and event clock.
    event=i>=21 && fresh && (control==1 ? up : control==2 ? down : island)
    if event {expiries[symbol]=max(expiries[symbol] ?? -1,i+pause-1)}
   } else {
    // UNKNOWN restores this stock's parent intent; consumed keys survive.
    expiries.removeValue(forKey:symbol)
   }
   let expiry=expiries[symbol],veto=known && i>=21 && (expiry.map{i<=$0} ?? false)
   // Independent definition scans retained actual source rows, not expiry.
   // A recent UNKNOWN interrupts every previous pause, including repeated keys.
   var independentVeto=false
   if known && i>=21 {
    let first=max(21,i-pause+1)
    for priorIndex in stride(from:i,through:first,by:-1) {
     if priorIndex==i {if event {independentVeto=true;break}}
     else {
      let past=result[symbol]![priorIndex]
      if !past.known {break}
      if past.fresh && past.event {independentVeto=true;break}
     }
    }
   }
   try igNeed(veto==independentVeto,"Expiry veto equals actual-row tail-H events with UNKNOWN barrier")
   result[symbol]!.append(IslandGapRow(index:i,symbol:symbol,rawSymbol:r.symbol,venue:s.venue,civilDate:frameDates[i],sourceCutAt:cut,
    nativeIndex:exists ? j:nil,previousIndex:previous ? j-1:nil,previousPreviousIndex:previousPrevious ? j-2:nil,
    nativeDate:exists ? r.dates[j]:nil,previousDate:previous ? r.dates[j-1]:nil,previousPreviousDate:previousPrevious ? r.dates[j-2]:nil,
    availableAt:exists ? s.available[j]:nil,previousAvailableAt:previous ? s.available[j-1]:nil,previousPreviousAvailableAt:previousPrevious ? s.available[j-2]:nil,
    open:exists ? r.open_prices[j]:nil,high:exists ? r.high_prices[j]:nil,low:exists ? r.low_prices[j]:nil,close:exists ? r.close_prices[j]:nil,
    previousOpen:previous ? r.open_prices[j-1]:nil,previousHigh:previous ? r.high_prices[j-1]:nil,previousLow:previous ? r.low_prices[j-1]:nil,previousClose:previous ? r.close_prices[j-1]:nil,
    previousPreviousOpen:previousPrevious ? r.open_prices[j-2]:nil,previousPreviousHigh:previousPrevious ? r.high_prices[j-2]:nil,previousPreviousLow:previousPrevious ? r.low_prices[j-2]:nil,previousPreviousClose:previousPrevious ? r.close_prices[j-2]:nil,
    known:known,fresh:fresh,nativeTupleKey:key,upGap:u,downGap:d,island:e,event:event,veto:veto,expiry:expiry,pause:pause,control:control,reasons:reasons))
  }}
  return result
 }
}
