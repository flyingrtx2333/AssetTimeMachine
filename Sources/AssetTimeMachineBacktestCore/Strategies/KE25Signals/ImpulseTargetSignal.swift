import Foundation

struct ImpulseTargetRow: Codable {
 let index:Int, symbol:String, civilDate:String, known:Bool, control:Int
 let selectedBlock:Bool?, eDown:Bool?, hDown:Bool?, red:Bool?
 let Eprev:Double?, Ecur:Double?, Fprev:Double?, Fcur:Double?, Sprev:Double?, Scur:Double?
 let Gprev:Double?, Gcur:Double?, Hprev:Double?, Hcur:Double?
 let independentEprev:Double?, independentEcur:Double?, independentFprev:Double?, independentFcur:Double?
 let independentSprev:Double?, independentScur:Double?, independentGprev:Double?, independentGcur:Double?
 let independentHprev:Double?, independentHcur:Double?
 let windowStartIndex:Int?, windowEndIndex:Int?, previousStateIndex:Int?
 let windowStartDate:String?, windowEndDate:String?, previousStateDate:String?
 let reasons:[String]
}

private struct ITState {
 let e:Double,f:Double,s:Double,g:Double,h:Double
 var values:[Double] {[e,f,s,g,h]}
}
private func itFail(_ message:String,_ symbol:String,_ index:Int,_ detail:[String:Any] = [:])throws -> Never {
 var witness=detail;witness["symbol"]=symbol;witness["index"]=index;witness["error"]=message
 let data=try JSONSerialization.data(withJSONObject:witness,options:[.sortedKeys])
 throw NSError(domain:"ImpulseTargetSignal",code:1,userInfo:[NSLocalizedDescriptionKey:String(data:data,encoding:.utf8)!])
}
private func itWitness(_ states:[String:ITState])->[String:Any] {
 var d:[String:Any]=[:]
 for(k,v)in states {d[k]=v.values.map{["value":String($0),"bits":String($0.bitPattern)] as [String:Any]}}
 return d
}
private func itClose(_ a:Double,_ b:Double,_ scale:Double)->Bool {
 a.isFinite && b.isFinite && abs(a-b)<=1e-10*max(1,scale)
}
// Explicit anchored geometric price EMA; no recursive EMA accumulator.
private func itExpandedPrice(_ x:[Double],_ end:Int,_ alpha:Double)->Double {
 let origin=x[0],q=1-alpha
 var sum=0.0
 if end>0 {for k in 1...end {sum += alpha*pow(q,Double(end-k))*(x[k]-origin)}}
 return origin+sum
}
private func itExpandedSignal(_ macd:[Double],_ end:Int)->Double {
 let a=2.0/10.0,q=1-a
 var sum=pow(q,Double(end))*macd[0]
 if end>0 {for k in 1...end {sum += a*pow(q,Double(end-k))*macd[k]}}
 return sum
}

enum ImpulseTargetSignal {
 static let symbols=["sp500","nasdaq","csi300","shanghai_composite"]
 // Raw history is metadata only: retain every series and every date-aligned
 // array, truncating by civil date; no raw-price feature is constructed.
 static func truncateHistory(historyData data:Data,cutoffCivilDate:String)throws->Data {
  guard var root=try JSONSerialization.jsonObject(with:data) as? [String:Any],let series=root["series"] as? [[String:Any]] else {
   try itFail("Malformed metadata history","metadata",-1)
  }
  root["series"]=try series.map { original -> [String:Any] in
   guard let dates=original["dates"] as? [String],dates==dates.sorted(),Set(dates).count==dates.count else {try itFail("Invalid metadata date arrays","metadata",-1)}
   let count=dates.prefix(while:{$0<=cutoffCivilDate}).count
   var row=original
   for key in Array(row.keys) {if let values=row[key] as? [Any],values.count==dates.count {row[key]=Array(values.prefix(count))}}
   return row
  }
  return try JSONSerialization.data(withJSONObject:root,options:[.sortedKeys])
 }
 static func build(frameDates:[String],pricesBySymbol:[String:[Double]],observedBySymbol:[String:[Bool]],pause:Int,control:Int)throws->[String:[ImpulseTargetRow]] {
  guard pause==0,(0...2).contains(control),frameDates==frameDates.sorted(),Set(frameDates).count==frameDates.count else {try itFail("Fixed pause/control and ordered unique frame","frame",-1)}
  var output:[String:[ImpulseTargetRow]]=[:]
  for symbol in symbols {
   guard let prices=pricesBySymbol[symbol],let observed=observedBySymbol[symbol],prices.count==frameDates.count,observed.count==frameDates.count else {try itFail("Missing/misaligned own canonical source",symbol,-1)}
   var rows:[ImpulseTargetRow]=[]
   for i in frameDates.indices {
    let start=i-312
    var reasons:[String]=[]
    if start<0 {reasons.append("FORMATION_313")}
    if start>=0 {
     if !(start...i).allSatisfy({observed[$0] && prices[$0].isFinite && prices[$0]>0}) {reasons.append("UNOBSERVED_OR_INVALID_OWN_CANONICAL_PRICE")}
     if symbol=="csi300" && frameDates[start]<"2005-04-08" {reasons.append("CSI_PUBLIC_WINDOW")}
    }
    guard reasons.isEmpty else {
     rows.append(ImpulseTargetRow(index:i,symbol:symbol,civilDate:frameDates[i],known:false,control:control,selectedBlock:nil,eDown:nil,hDown:nil,red:nil,Eprev:nil,Ecur:nil,Fprev:nil,Fcur:nil,Sprev:nil,Scur:nil,Gprev:nil,Gcur:nil,Hprev:nil,Hcur:nil,independentEprev:nil,independentEcur:nil,independentFprev:nil,independentFcur:nil,independentSprev:nil,independentScur:nil,independentGprev:nil,independentGcur:nil,independentHprev:nil,independentHcur:nil,windowStartIndex:start>=0 ? start:nil,windowEndIndex:i,previousStateIndex:i>0 ? i-1:nil,windowStartDate:start>=0 ? frameDates[start]:nil,windowEndDate:frameDates[i],previousStateDate:i>0 ? frameDates[i-1]:nil,reasons:reasons));continue
    }
    let x=Array(prices[start...i]),origin=x[0]
    let ae=2.0/14.0,af=2.0/13.0,aslow=2.0/27.0,ag=2.0/10.0
    var e=origin,f=origin,s=origin,g=0.0
    var de=0.0,df=0.0,ds=0.0,dg=0.0
    var direct:[ITState]=[],shifted:[ITState]=[],macds:[Double]=[]
    for k in x.indices {
     if k>0 {
      e += ae*(x[k]-e);f += af*(x[k]-f);s += aslow*(x[k]-s)
      let y=x[k]-origin
      de += ae*(y-de);df += af*(y-df);ds += aslow*(y-ds)
     }
     let m=f-s,dm=df-ds
     if k>0 {g += ag*(m-g);dg += ag*(dm-dg)}
     let a=ITState(e:e,f:f,s:s,g:g,h:m-g),b=ITState(e:origin+de,f:origin+df,s:origin+ds,g:dg,h:dm-dg)
     let priceScale=max(abs(x[k]),abs(origin),abs(e),abs(f),abs(s))
     let momentumScale=max(1,abs(m),abs(dm),abs(g),abs(dg),abs(a.h),abs(b.h))
     guard zip(a.values,b.values).enumerated().allSatisfy({item in itClose(item.element.0,item.element.1,item.offset<3 ? priceScale:momentumScale)}) else {try itFail("Independent shift-origin all-state mismatch",symbol,i,itWitness(["direct":a,"shifted":b]).merging(["windowLocalIndex":k,"windowStart":start]){$1})}
     direct.append(a);shifted.append(b);macds.append(m)
    }
    let prev=direct[311],cur=direct[312],ip=shifted[311],ic=shifted[312]
    for end in [311,312] {
     let actual=direct[end]
     let expanded=[itExpandedPrice(x,end,ae),itExpandedPrice(x,end,af),itExpandedPrice(x,end,aslow)]
     for j in 0..<3 {guard itClose(actual.values[j],expanded[j],max(abs(actual.values[j]),abs(expanded[j]),abs(origin))) else {try itFail("Anchored closed price EMA mismatch",symbol,i,["windowLocalIndex":end,"operand":j,"direct":actual.values[j],"expanded":expanded[j],"directBits":String(actual.values[j].bitPattern),"expandedBits":String(expanded[j].bitPattern)])}}
     let independentG=itExpandedSignal(macds,end)
     guard itClose(actual.g,independentG,max(1,macds.prefix(end+1).map{abs($0)}.max() ?? 1)) else {try itFail("Expanded MACD signal mismatch",symbol,i,["windowLocalIndex":end,"directG":actual.g,"expandedG":independentG,"directBits":String(actual.g.bitPattern),"expandedBits":String(independentG.bitPattern)])}
    }
    let ed=cur.e<prev.e,hd=cur.h<prev.h,red=ed && hd
    let independentED=ic.e<ip.e,independentHD=ic.h<ip.h,independentRed=independentED && independentHD
    guard ed==independentED,hd==independentHD,red==independentRed,red == !(cur.e>=prev.e || cur.h>=prev.h) else {
     try itFail("EXACT independent strict E/H decline or red mismatch",symbol,i,itWitness(["previous":prev,"current":cur,"independentPrevious":ip,"independentCurrent":ic]).merging(["eDown":ed,"hDown":hd,"red":red,"independentEDown":independentED,"independentHDown":independentHD,"independentRed":independentRed,"windowStart":start]){$1})
    }
    rows.append(ImpulseTargetRow(index:i,symbol:symbol,civilDate:frameDates[i],known:true,control:control,selectedBlock:control==0 ? red:(control==1 ? ed:hd),eDown:ed,hDown:hd,red:red,Eprev:prev.e,Ecur:cur.e,Fprev:prev.f,Fcur:cur.f,Sprev:prev.s,Scur:cur.s,Gprev:prev.g,Gcur:cur.g,Hprev:prev.h,Hcur:cur.h,independentEprev:ip.e,independentEcur:ic.e,independentFprev:ip.f,independentFcur:ic.f,independentSprev:ip.s,independentScur:ic.s,independentGprev:ip.g,independentGcur:ic.g,independentHprev:ip.h,independentHcur:ic.h,windowStartIndex:start,windowEndIndex:i,previousStateIndex:i-1,windowStartDate:frameDates[start],windowEndDate:frameDates[i],previousStateDate:frameDates[i-1],reasons:[]))
   }
   output[symbol]=rows
  }
  return output
 }
}
