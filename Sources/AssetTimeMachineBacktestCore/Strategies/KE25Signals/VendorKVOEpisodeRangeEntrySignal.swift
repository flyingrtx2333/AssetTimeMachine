// Numerical kernel and lifecycle ported from the frozen 2026-10-22 KVO research helper.
// Research-only disk witnesses and target-template copying are omitted; all numeric/sign guards remain.
import Foundation

// Conditional current-vintage vendor quantity, NOT certified index turnover or observed PIT.
struct VendorKVOEpisodeRangePath:Codable {
 let force:Double,fastEMA:Double,slowEMA:Double,kvo:Double,signalEMA:Double,histogram:Double
 let decimalForce:String,decimalFastEMA:String,decimalSlowEMA:String,decimalKVO:String,decimalSignalEMA:String,decimalHistogram:String
 let intermediates:[String:Double],decimalIntermediates:[String:String]
 let histogramSign:Int,decimalHistogramSign:Int,signAgrees:Bool
}
struct VendorKVOEpisodeRangeNativeEvent:Codable {
 let nativeIndex:Int,civilDate:String,assumedAvailableAt:Date
 let token:String?,status:String,integerDecimal:String?,quantityDouble:Double?
 let high:Double?,low:Double?,close:Double?,hlc:Double?,dm:Double?
 let publicPriceKnown:Bool,positiveQuantityKnown:Bool,anchor:Bool,reset:Bool,scoreKnown:Bool
 let segmentStartNativeIndex:Int?,forceOrdinal:Int?,trendTag:Int?,effectiveSign:Int?
 let previousHLC:Double?,previousDM:Double?,cmBefore:Double?,cm:Double?,ratio:Double?,factor:Double?
 let decimalHLC:String?,decimalDM:String?,decimalCM:String?,decimalRatio:String?,decimalFactor:String?
 let coefficientDoubled:Double?,coefficientCentered:Double?,decimalCoefficientDoubled:String?,decimalCoefficientCentered:String?,decimalTrendTag:Int?
 let stateBefore:[String:String],paths:[VendorKVOEpisodeRangePath],decimalStatusCounts:[String:Int],reasons:[String]
}
struct VendorKVOEpisodeRangeScores:Codable {
 let qHistogram:Double,unitHistogram:Double,signedHistogram:Double
 let histogramSigns:[Int],decimalHistogramSigns:[Int],allSignsAgree:Bool
 let paths:[VendorKVOEpisodeRangePath]
}
struct VendorKVOEpisodeRangeEntryRow:Codable {
 let index:Int,symbol:String,civilDate:String,mode:Int
 let originalPriceRow:BreakoutSARExitRow
 let appliesQuantity:Bool,scoreSupportKnown:Bool,positiveQuantityWindowKnown:Bool,scoreKnown:Bool
 let qHistogram:Double?,unitHistogram:Double?,signedHistogram:Double?,selectedGate:Bool
 let window:[VendorKVOEpisodeRangeNativeEvent],scores:VendorKVOEpisodeRangeScores?
 let entryAllowed:Bool,entryFallback:Bool,entryRejected:Bool
 let holdingBefore:Bool,holdingAfter:Bool,entered:Bool,exited:Bool,permission:Bool
 let floorBefore:Double?,floorAfter:Double?,episodeID:String?,entryNativeIndex:Int?
 let reasons:[String]
}
private struct VQHistory:Decodable {let series:[VQHistorySeries]}
private struct VQHistorySeries:Decodable {
 let symbol:String,dates:[String],low_prices:[Double?],high_prices:[Double?],close_prices:[Double?]
 enum CodingKeys:String,CodingKey {case symbol,dates,low_prices,high_prices,close_prices}
 init(from decoder:Decoder)throws {
  let c=try decoder.container(keyedBy:CodingKeys.self)
  symbol=try c.decode(String.self,forKey:.symbol)
  if ["csi300","shanghai_composite"].contains(symbol) {
   dates=try c.decode([String].self,forKey:.dates)
   low_prices=try c.decode([Double?].self,forKey:.low_prices)
   high_prices=try c.decode([Double?].self,forKey:.high_prices)
   close_prices=try c.decode([Double?].self,forKey:.close_prices)
  } else {dates=[];low_prices=[];high_prices=[];close_prices=[]}
 }
}
enum VendorKVOEpisodeRangeEntrySignal {
 private static let cn=Set(["csi300","shanghai_composite"])
 private struct Episode {let floor:Double,id:String,nativeIndex:Int}
 private struct Quantity {let token:String?,value:UInt64?,status:String}
 private final class Context {
  let mode:Int
  var stage="configuration", sourceIndex:Int?, symbol:String?, nativeIndex:Int?, rawDay:String?, rawToken:String?
  var window=[VendorKVOEpisodeRangeNativeEvent](), completed=[[VendorKVOEpisodeRangeEntryRow]]()
  var numericWitness=[String:String]()
  var nativeEvents=[VendorKVOEpisodeRangeNativeEvent]()
  init(_ mode:Int){self.mode=mode}
  func need(_ okay:Bool,_ message:String)throws {
   if !okay {throw NSError(domain:"VendorKVOEpisodeRangeEntrySignal",code:1,userInfo:[NSLocalizedDescriptionKey:message])}
  }

 }
 private static func dayEnd(_ civil:String)throws->Date {
  var c=Calendar(identifier:.gregorian);c.timeZone=TimeZone(identifier:"Asia/Shanghai")!
  let f=DateFormatter();f.calendar=c;f.timeZone=c.timeZone;f.locale=Locale(identifier:"en_US_POSIX");f.dateFormat="yyyy-MM-dd";f.isLenient=false
  guard civil.utf8.count==10,let date=f.date(from:civil),f.string(from:date)==civil,let next=c.date(byAdding:.day,value:1,to:date) else {throw NSError(domain:"VendorQuantityCivilDate",code:1,userInfo:[NSLocalizedDescriptionKey:civil])}
  return next
 }
 private static func rawRows(_ data:Data)throws->[[String:Any]] {
  guard let rows=try JSONSerialization.jsonObject(with:data) as? [[String:Any]] else {throw NSError(domain:"VendorQuantityRawArray",code:1)}
  return rows
 }
 // Physical date-record crop, retaining all original fields in surviving records.
 // Price fields are opaque here and never consumed by the signal builder.
 static func truncateQuantity(rawData:Data,cutoffCivilDate:String)throws->Data {
  _=try dayEnd(cutoffCivilDate)
  var result=[[String:Any]]()
  for row in try rawRows(rawData) {
   guard let day=row["day"] as? String else {throw NSError(domain:"VendorQuantityMissingDay",code:1)}
   _=try dayEnd(day)
   if day<=cutoffCivilDate {result.append(row)}
  }
  return try JSONSerialization.data(withJSONObject:result,options:[.sortedKeys])
 }
 private static func quantities(_ data:Data,_ context:Context)throws->[String:Quantity] {
  var result=[String:Quantity]()
  for row in try rawRows(data) {
   guard let day=row["day"] as? String else {throw NSError(domain:"VendorQuantityMissingDay",code:1)}
   context.rawDay=day;context.rawToken=row["volume"] as? String
   _=try dayEnd(day)
   try context.need(result[day]==nil,"Duplicate quantity day; do not aggregate or select one")
   let q:Quantity
   if row["volume"]==nil || row["volume"] is NSNull {q=Quantity(token:nil,value:nil,status:"ABSENT_OR_NULL_UNKNOWN")}
   else {
    guard let token=row["volume"] as? String else {throw NSError(domain:"VendorQuantityTokenType",code:1,userInfo:[NSLocalizedDescriptionKey:"Expected original string volume token"])}
    if token.isEmpty {q=Quantity(token:token,value:nil,status:"EMPTY_UNKNOWN")}
    else {
     let bytes=Array(token.utf8)
     try context.need(!bytes.isEmpty && bytes.allSatisfy{(48...57).contains($0)},"Malformed unsigned ASCII quantity token")
     var value:UInt64=0
     for byte in bytes {
      let product=value.multipliedReportingOverflow(by:10)
      let addition=product.partialValue.addingReportingOverflow(UInt64(byte-48))
      try context.need(!product.overflow && !addition.overflow,"UInt64 quantity parse overflow")
      value=addition.partialValue
     }
     try context.need(UInt64(token)==value,"Independent standard UInt64 token parse identity")
     q=Quantity(token:token,value:value==0 ? nil:value,status:value==0 ? "VENDOR_ZERO_UNKNOWN":"POSITIVE_VENDOR_INTEGER")
    }
   }
   result[day]=q
  }
  context.rawDay=nil;context.rawToken=nil
  return result
 }
 private static func sign(_ x:Double)->Int {x>0 ? 1:x<0 ? -1:0}
 private static func text(_ x:Decimal)->String {var v=x;return NSDecimalString(&v,Locale(identifier:"en_US_POSIX"))}
 private static func dsign(_ x:Decimal)->Int {
  var a=x,z=Decimal(0);let c=NSDecimalCompare(&a,&z)
  return c == .orderedAscending ? -1:c == .orderedDescending ? 1:0
 }
 private static func din(_ token:String,_ context:Context)throws->Decimal {
  guard var x=Decimal(string:token,locale:Locale(identifier:"en_US_POSIX")),!NSDecimalIsNotANumber(&x) else {throw NSError(domain:"KVODecimalInput",code:1,userInfo:[NSLocalizedDescriptionKey:token])}
  guard let original=Double(token),let back=Double(text(x)) else {throw NSError(domain:"KVODecimalInputRoundtrip",code:1)}
  try context.need(original.isFinite && back.isFinite && original.bitPattern==back.bitPattern,"Decimal input shortest decimal roundtrip preserves supplied canonical Double or exact-convertible UInt64 token")
  return x
 }
 private static func dop(_ a:Decimal,_ b:Decimal,_ op:String,_ counts:inout [String:Int],_ context:Context)throws->Decimal {
  var x=a,y=b,r=Decimal(0)
  let status = op=="+" ? NSDecimalAdd(&r,&x,&y,.plain):op=="-" ? NSDecimalSubtract(&r,&x,&y,.plain):op=="*" ? NSDecimalMultiply(&r,&x,&y,.plain):NSDecimalDivide(&r,&x,&y,.plain)
  let name:String
  switch status {
  case .noError:name="noError"
  case .lossOfPrecision:name="lossOfPrecision"
  case .underflow:name="underflow"
  case .overflow:name="overflow"
  case .divideByZero:name="divideByZero"
  default:name="unknown"
  }
  counts[name,default:0]+=1
  let valid=(status == .noError || status == .lossOfPrecision) && !NSDecimalIsNotANumber(&r)
  let supported = !(op=="*" || op=="/") || dsign(a)==0 || (op=="*" && dsign(b)==0) || dsign(r) != 0
  if !valid || !supported {
   context.numericWitness["decimalOperation"]=op;context.numericWitness["decimalLeft"]=text(a);context.numericWitness["decimalRight"]=text(b)
   context.numericWitness["decimalResult"]=text(r);context.numericWitness["decimalStatus"]=name
  }
  try context.need(valid && supported,"Decimal finite reference: overflow/underflow/divideByZero/NaN or silently zero nonzero product/quotient STOP")
  return r
 }
 private static func checked(_ x:Double,_ label:String,_ context:Context)throws->Double {
  if !x.isFinite {context.numericWitness["doubleOperation"]=label;context.numericWitness["doubleValue"]=String(x);context.numericWitness["doubleBits"]=String(x.bitPattern)}
  try context.need(x.isFinite,"Finite binary64 KVO operation "+label);return x
 }
 private static func mul(_ a:Double,_ b:Double,_ label:String,_ context:Context)throws->Double {
  let r=try checked(a*b,label,context)
  if a != 0 && b != 0 && r==0 {context.numericWitness["doubleOperation"]=label;context.numericWitness["doubleLeft"]=String(a);context.numericWitness["doubleRight"]=String(b)}
  try context.need(a==0 || b==0 || r != 0,"Nonzero binary64 product cannot silently underflow "+label);return r
 }
 private struct Filter {var fast:Double,slow:Double,signal:Double;var dfast:Decimal,dslow:Decimal,dsignal:Decimal}
 private struct NativeState {
  var anchorIndex:Int,previousHLC:Double,previousDM:Double,cm:Double,trend:Int,dtrend:Int,forceCount:Int
  var dpreviousHLC:Decimal,dpreviousDM:Decimal,dcm:Decimal
  var filters:[Filter]
 }
 // Causal scan through the largest actually selected j-1 only; no current/future quantity admission.
 private static func events(_ s:VQHistorySeries,_ quantities:[String:Quantity],_ limit:Int,_ context:Context)throws->[VendorKVOEpisodeRangeNativeEvent] {
  if limit<0 {return []}
  try context.need(limit<s.dates.count,"Selected prior native index within physical price prefix")
  let alphaFast=try checked(2.0/35.0,"precomputed alpha34",context),alphaSlow=try checked(2.0/56.0,"precomputed alpha55",context),alphaSignal=try checked(2.0/14.0,"precomputed alpha13",context)
  var counts=[String:Int]()
  let daFast=try dop(Decimal(2),Decimal(35),"/",&counts,context),daSlow=try dop(Decimal(2),Decimal(56),"/",&counts,context),daSignal=try dop(Decimal(2),Decimal(14),"/",&counts,context)
  context.nativeEvents=[]
  var state:NativeState?
  for k in 0...limit {
   context.stage="causal-native-KVO-common-checks";context.nativeIndex=k;context.rawDay=s.dates[k];context.numericWitness=[:]
   let date=s.dates[k],available=try dayEnd(date),q=quantities[date] ?? Quantity(token:nil,value:nil,status:"MISSING_NATIVE_DATE_UNKNOWN")
   context.rawToken=q.token
   let h=s.high_prices[k],l=s.low_prices[k],c=s.close_prices[k]
   let publicPrice=(s.symbol != "csi300" || date>="2005-04-08") && h != nil && l != nil && c != nil && h!.isFinite && l!.isFinite && c!.isFinite && h!>0 && l!>0 && c!>0 && h!>=l! && c!>=l! && c!<=h!
   let positive=q.value != nil
   var qDouble:Double?,hlc:Double?,dm:Double?,previousHLC:Double?,previousDM:Double?,cmBefore:Double?,cm:Double?,ratio:Double?,factor:Double?
   var dhlc:Decimal?,ddm:Decimal?,dcm:Decimal?,dratio:Decimal?,dfactor:Decimal?,ddoubled:Decimal?,dcentered:Decimal?
   var doubled:Double?,centered:Double?,dtrend:Int?
   var stateBefore=[String:String]()
   if let held=state {
    stateBefore=["anchorIndex":String(held.anchorIndex),"trendTag":String(held.trend),"decimalTrendTag":String(held.dtrend),"forceCount":String(held.forceCount),"previousHLC":String(held.previousHLC),"previousDM":String(held.previousDM),"cm":String(held.cm),"decimalPreviousHLC":text(held.dpreviousHLC),"decimalPreviousDM":text(held.dpreviousDM),"decimalCM":text(held.dcm)]
    for (r,f) in held.filters.enumerated() {
     stateBefore["role\(r).fastEMA"]=String(f.fast);stateBefore["role\(r).slowEMA"]=String(f.slow);stateBefore["role\(r).signalEMA"]=String(f.signal)
     stateBefore["role\(r).decimalFastEMA"]=text(f.dfast);stateBefore["role\(r).decimalSlowEMA"]=text(f.dslow);stateBefore["role\(r).decimalSignalEMA"]=text(f.dsignal)
    }
   }
   context.numericWitness=stateBefore
   context.numericWitness["high"]=h.map{String($0)} ?? "null";context.numericWitness["low"]=l.map{String($0)} ?? "null";context.numericWitness["close"]=c.map{String($0)} ?? "null"
   var anchor=false,reset=false,known=false,paths=[VendorKVOEpisodeRangePath](),reasons=[String](),anchorIndex:Int?,forceOrdinal:Int?,trend:Int?,effectiveSign:Int?
   if !publicPrice || !positive {
    reset=true;state=nil;reasons.append(!publicPrice ? "INVALID_OR_PREPUBLIC_NATIVE_HLC_COMMON_SEGMENT_RESET":"QUANTITY_UNKNOWN_COMMON_SEGMENT_RESET")
   } else {
    guard let exact=Double(exactly:q.value!) else {throw NSError(domain:"KVOExactQuantityDouble",code:1,userInfo:[NSLocalizedDescriptionKey:"Common all-role positive UInt64 quantity including anchor must convert exactly to binary64"])}
    try context.need(UInt64(exactly:exact)==q.value!,"Exact common UInt64 to Double to UInt64 roundtrip including anchors and all roles")
    qDouble=exact
    hlc=try checked(try checked(h!+l!,"H+L",context)+c!,"H+L+C",context);dm=try checked(h!-l!,"H-L",context)
    context.numericWitness["canonicalHLC"]=String(hlc!);context.numericWitness["canonicalDM"]=String(dm!)
    dhlc=try din(String(hlc!),context);ddm=try din(String(dm!),context)
    if var held=state {
     previousHLC=held.previousHLC;previousDM=held.previousDM;cmBefore=held.cm
     // Literal Tulip -1 initial tag is truthy; tie keeps tag and does not prepend previous DM.
     let cmp=hlc!>held.previousHLC ? 1:hlc!<held.previousHLC ? -1:0
     var a=dhlc!,b=held.dpreviousHLC
     let dcmp=NSDecimalCompare(&a,&b) == .orderedAscending ? -1:NSDecimalCompare(&a,&b) == .orderedDescending ? 1:0
     try context.need(cmp==dcmp,"Canonical HLC ordering versus Decimal canonical-shortest HLC ordering")
     if cmp>0 && held.trend != 1 {held.trend=1;held.cm=held.previousDM}
     else if cmp<0 && held.trend != 0 {held.trend=0;held.cm=held.previousDM}
     if dcmp>0 && held.dtrend != 1 {held.dtrend=1;held.dcm=held.dpreviousDM}
     else if dcmp<0 && held.dtrend != 0 {held.dtrend=0;held.dcm=held.dpreviousDM}
     try context.need(held.trend==held.dtrend,"Independent Decimal versus canonical trend tag/tie/reset branches agree")
     dtrend=held.dtrend
     held.cm=try checked(held.cm+dm!,"CM+=DM",context);held.dcm=try dop(held.dcm,ddm!,"+",&counts,context)
     cm=held.cm;dcm=held.dcm;trend=held.trend;effectiveSign=held.trend != 0 ? 1:-1;anchorIndex=held.anchorIndex
     try context.need(held.cm>=0 && dsign(held.dcm)>=0,"Common cumulative range nonnegative in both references")
     try context.need((held.cm==0)==(dsign(held.dcm)==0),"Common cumulative range zero support agrees")
     if held.cm==0 {
      reset=true;state=nil;reasons.append("CM_ZERO_COMMON_SEGMENT_RESET_CURRENT_NOT_REANCHORED")
     } else {
      ratio=try checked(dm!/held.cm,"DM/CM",context)
      try context.need(dm! == 0 || ratio! != 0,"Nonzero binary64 DM/CM cannot silently underflow")
      doubled=try mul(ratio!,2,"ratio*2",context);centered=try checked(doubled!-1,"ratio*2-1",context)
      factor=try checked(abs(centered!),"absolute range factor",context)
      dratio=try dop(ddm!,held.dcm,"/",&counts,context)
      ddoubled=try dop(dratio!,Decimal(2),"*",&counts,context);dcentered=try dop(ddoubled!,Decimal(1),"-",&counts,context)
      dfactor=dsign(dcentered!)<0 ? try dop(Decimal(0),dcentered!,"-",&counts,context):dcentered!
      let rawDecimal=try din(q.token!,context),sgn=Double(effectiveSign!),dsgn=Decimal(held.dtrend != 0 ? 1:-1)
      let quantities=[exact,1.0,exact],factors=[factor!,factor!,1.0],dquantities=[rawDecimal,Decimal(1),rawDecimal],dfactors=[dfactor!,dfactor!,Decimal(1)]
      var forceParts=[[String:Double]](),dforceParts=[[String:String]](),computedForces=[Double](),computedDForces=[Decimal]()
      for r in 0..<3 {
       context.numericWitness["forceRole"]=String(r)
       let first=try mul(quantities[r],factors[r],"role force q*factor",context),hundred=try mul(first,100,"role force *100",context),force=try mul(hundred,sgn,"role force *sign",context)
       let dfirst=try dop(dquantities[r],dfactors[r],"*",&counts,context),dhundred=try dop(dfirst,Decimal(100),"*",&counts,context),dforce=try dop(dhundred,dsgn,"*",&counts,context)
       forceParts.append(["quantityOperand":quantities[r],"factorOperand":factors[r],"quantityTimesFactor":first,"times100":hundred,"effectiveSign":sgn,"alphaFast":alphaFast,"alphaSlow":alphaSlow,"alphaSignal":alphaSignal])
       dforceParts.append(["quantityOperand":text(dquantities[r]),"factorOperand":text(dfactors[r]),"quantityTimesFactor":text(dfirst),"times100":text(dhundred),"effectiveSign":text(dsgn),"alphaFast":text(daFast),"alphaSlow":text(daSlow),"alphaSignal":text(daSignal)])
       computedForces.append(force);computedDForces.append(dforce)
      }
      let forces=computedForces,dforces=computedDForces
      try context.need(held.forceCount==0 ? held.filters.isEmpty:held.filters.count==3,"Native shared filter seed/state cardinality")
      for role in 0..<3 {
       context.numericWitness["filterRole"]=String(role)
       let f=forces[role],df=dforces[role]
       var filter:Filter,intermediates=forceParts[role],dintermediates=dforceParts[role]
       if held.forceCount==0 {filter=Filter(fast:f,slow:f,signal:0,dfast:df,dslow:df,dsignal:Decimal(0))}
       else {
        let old=held.filters[role]
        let fd=try checked(f-old.fast,"fast force-old",context),fs=try mul(fd,alphaFast,"fast delta*alpha",context),fast=try checked(fs+old.fast,"fast EMA",context)
        let sd=try checked(f-old.slow,"slow force-old",context),ss=try mul(sd,alphaSlow,"slow delta*alpha",context),slow=try checked(ss+old.slow,"slow EMA",context)
        let dfd=try dop(df,old.dfast,"-",&counts,context),dfs=try dop(daFast,dfd,"*",&counts,context),dfast=try dop(old.dfast,dfs,"+",&counts,context)
        let dsd=try dop(df,old.dslow,"-",&counts,context),dss=try dop(daSlow,dsd,"*",&counts,context),dslow=try dop(old.dslow,dss,"+",&counts,context)
        intermediates.merge(["oldFast":old.fast,"oldSlow":old.slow,"oldSignal":old.signal,"fastDelta":fd,"fastStep":fs,"slowDelta":sd,"slowStep":ss]){_,new in new}
        dintermediates.merge(["oldFast":text(old.dfast),"oldSlow":text(old.dslow),"oldSignal":text(old.dsignal),"fastDelta":text(dfd),"fastStep":text(dfs),"slowDelta":text(dsd),"slowStep":text(dss)]){_,new in new}
        filter=Filter(fast:fast,slow:slow,signal:old.signal,dfast:dfast,dslow:dslow,dsignal:old.dsignal)
       }
       let kval=try checked(filter.fast-filter.slow,"K fast-slow",context),dk=try dop(filter.dfast,filter.dslow,"-",&counts,context)
       if held.forceCount==0 {filter.signal=kval;filter.dsignal=dk}
       else {
        let delta=try checked(kval-filter.signal,"K-old signal",context),step=try mul(delta,alphaSignal,"signal delta*alpha13",context)
        filter.signal=try checked(step+filter.signal,"signal EMA13",context)
        let ddelta=try dop(dk,filter.dsignal,"-",&counts,context),dstep=try dop(daSignal,ddelta,"*",&counts,context)
        filter.dsignal=try dop(filter.dsignal,dstep,"+",&counts,context)
        intermediates["signalDelta"]=delta;intermediates["signalStep"]=step;dintermediates["signalDelta"]=text(ddelta);dintermediates["signalStep"]=text(dstep)
       }
       let hist=try checked(kval-filter.signal,"hist K-signal",context),dh=try dop(dk,filter.dsignal,"-",&counts,context)
       paths.append(VendorKVOEpisodeRangePath(force:f,fastEMA:filter.fast,slowEMA:filter.slow,kvo:kval,signalEMA:filter.signal,histogram:hist,decimalForce:text(df),decimalFastEMA:text(filter.dfast),decimalSlowEMA:text(filter.dslow),decimalKVO:text(dk),decimalSignalEMA:text(filter.dsignal),decimalHistogram:text(dh),intermediates:intermediates,decimalIntermediates:dintermediates,histogramSign:sign(hist),decimalHistogramSign:dsign(dh),signAgrees:sign(hist)==dsign(dh)))
       if held.forceCount==0 {held.filters.append(filter)}else{held.filters[role]=filter}
      }
      context.numericWitness["cm"]=String(held.cm);context.numericWitness["decimalCM"]=text(held.dcm)
      try context.need(paths.count==3 && paths.allSatisfy{$0.signAgrees},"ALL three role histogram strict signs agree with finite-precision Decimal references before selecting any role; no epsilon or rescue")
      held.forceCount+=1;forceOrdinal=held.forceCount;known=true
      held.previousHLC=hlc!;held.previousDM=dm!;held.dpreviousHLC=dhlc!;held.dpreviousDM=ddm!;state=held
      reasons.append(held.forceCount==1 ? "FIRST_VALID_FORCE_SEEDS_FAST_SLOW_FORCE_AND_SIGNAL_ZERO_K_HIST_KNOWN_ZERO":"CAUSAL_CONTIGUOUS_SEGMENT_KVO34_55_SIGNAL13")
     }
    } else {
     anchor=true;anchorIndex=k;trend = -1;dtrend = -1;effectiveSign=1
     state=NativeState(anchorIndex:k,previousHLC:hlc!,previousDM:dm!,cm:0,trend:-1,dtrend:-1,forceCount:0,dpreviousHLC:dhlc!,dpreviousDM:ddm!,dcm:Decimal(0),filters:[])
     reasons.append("FIRST_VALID_SEGMENT_ANCHOR_NO_FORCE_NO_SCORE_TULIP_NEGATIVE_ONE_TAG_IS_TRUTHY")
    }
   }
   let event=VendorKVOEpisodeRangeNativeEvent(nativeIndex:k,civilDate:date,assumedAvailableAt:available,token:q.token,status:q.status,integerDecimal:q.value.map{String($0)},quantityDouble:qDouble,high:h,low:l,close:c,hlc:hlc,dm:dm,publicPriceKnown:publicPrice,positiveQuantityKnown:positive,anchor:anchor,reset:reset,scoreKnown:known,segmentStartNativeIndex:anchorIndex,forceOrdinal:forceOrdinal,trendTag:trend,effectiveSign:effectiveSign,previousHLC:previousHLC,previousDM:previousDM,cmBefore:cmBefore,cm:cm,ratio:ratio,factor:factor,decimalHLC:dhlc.map{text($0)},decimalDM:ddm.map{text($0)},decimalCM:dcm.map{text($0)},decimalRatio:dratio.map{text($0)},decimalFactor:dfactor.map{text($0)},coefficientDoubled:doubled,coefficientCentered:centered,decimalCoefficientDoubled:ddoubled.map{text($0)},decimalCoefficientCentered:dcentered.map{text($0)},decimalTrendTag:dtrend,stateBefore:stateBefore,paths:paths,decimalStatusCounts:counts,reasons:reasons)
   context.nativeEvents.append(event)
  }
  context.rawDay=nil;context.rawToken=nil
  return context.nativeEvents
 }
 static func permissions(frameDates:[String],historyData:Data,baselineBySymbol:[String:[BreakoutSARExitRow]],quantityRawBySymbol:[String:Data])throws->[String:[Bool]] {
  let mode=0
  let context=Context(mode)
  do {
   try context.need([0,1,2].contains(mode) && frameDates.count>=22,"Modes 0=KVO quantity/range Q, 1=unit quantity U, 2=signed quantity without CM B; original source21 horizon")
   try context.need(Set(quantityRawBySymbol.keys)==cn,"Exactly the two authorized same-index vendor raw inputs")
   let decoder=JSONDecoder();decoder.dateDecodingStrategy = .iso8601
   context.stage="original-E-literal-rebuild"
   let baseline=frameDates.indices.map{i in BreakoutSARExitSignal.symbols.map{baselineBySymbol[$0]![i]}}
   let history=try decoder.decode(VQHistory.self,from:historyData)
   var native=[String:VQHistorySeries](), quantity=[String:[String:Quantity]]()
   for symbol in cn.sorted() {
    context.symbol=symbol;context.stage="raw-quantity-parse"
    let matches=history.series.filter{$0.symbol==symbol}
    try context.need(matches.count==1,"Exactly one bound original CN native history")
    let series=matches[0]
    try context.need(series.dates.count==series.low_prices.count && series.dates.count==series.high_prices.count && series.dates.count==series.close_prices.count,"Native floor/date array alignment")
    for j in series.dates.indices { _=try dayEnd(series.dates[j]);if j>0 {try context.need(series.dates[j-1]<series.dates[j],"Native dates unique and ordered")} }
    native[symbol]=series
    let cut=try truncateQuantity(rawData:quantityRawBySymbol[symbol]!,cutoffCivilDate:frameDates.last!)
    quantity[symbol]=try quantities(cut,context)
   }
   var nativeEvents=[String:[VendorKVOEpisodeRangeNativeEvent]]()
   for symbol in cn.sorted() {
    context.symbol=symbol;context.nativeEvents=[]
    let limit=baseline.flatMap{$0}.filter{$0.symbol==symbol}.compactMap{$0.nativeIndex.map{$0-1}}.max() ?? -1
    nativeEvents[symbol]=try events(native[symbol]!,quantity[symbol]!,limit,context)
   }
   context.nativeEvents=[]
   var episodes=[String:Episode](), priceEpisodes=[String:Episode]()
   for i in frameDates.indices {
    context.sourceIndex=i;context.stage="source-FSM";var dayRows=[VendorKVOEpisodeRangeEntryRow]()
    for price in baseline[i] {
     let symbol=price.symbol;context.symbol=symbol;context.nativeIndex=price.nativeIndex;context.window=[];context.numericWitness=[:]
     let applies=cn.contains(symbol),before=episodes[symbol]
     var window=[VendorKVOEpisodeRangeNativeEvent](),scores:VendorKVOEpisodeRangeScores?
     var scoreSupportKnown=false,positiveQuantityWindowKnown=false
     var reasons=[String](),allowed=true,fallback=false,rejected=false,entered=false,exited=false,state=before
     if applies {
      let s=native[symbol]!
      if let j=price.nativeIndex,j>=1 {
       try context.need(j<s.dates.count && price.nativeDate==s.dates[j],"Original E native row aligns to unchanged native price date")
       let event=nativeEvents[symbol]![j-1]
       try context.need(event.nativeIndex==j-1 && event.civilDate==s.dates[j-1] && event.assumedAvailableAt<=price.sourceCutAt,"Exactly prior native j-1 event is assumed day-end available by original D0")
       window=[event];context.window=window
       scoreSupportKnown=event.publicPriceKnown;positiveQuantityWindowKnown=event.positiveQuantityKnown
       if event.scoreKnown {
        try context.need(event.paths.count==3 && event.paths.allSatisfy{$0.signAgrees},"Shared three-role native checks complete before source role choice")
        scores=VendorKVOEpisodeRangeScores(qHistogram:event.paths[0].histogram,unitHistogram:event.paths[1].histogram,signedHistogram:event.paths[2].histogram,histogramSigns:event.paths.map{$0.histogramSign},decimalHistogramSigns:event.paths.map{$0.decimalHistogramSign},allSignsAgree:true,paths:event.paths)
        allowed=event.paths[mode].histogram>0
       } else if price.known {fallback=true;reasons.append("EXTRA_KVO_COMMON_SEGMENT_UNKNOWN_ORIGINAL_PRICE_ENTRY_FALLBACK")}
       else {reasons.append("ORIGINAL_PRICE_UNKNOWN_OWN_FSM_RESET_NATIVE_INDICATOR_NOT_RESET_BY_SOURCE_UNKNOWN")}
       if !price.known {reasons.append("ORIGINAL_PRICE_UNKNOWN_ONLY_OWN_FSM_RESET") }
      } else if price.known {fallback=true;reasons.append("PRIOR_NATIVE_KVO_NOT_READY_ORIGINAL_PRICE_ENTRY_FALLBACK")}
      else {reasons.append("ORIGINAL_PRICE_UNKNOWN_OWN_FSM_RESET")}
      context.stage="source-FSM";context.rawDay=nil;context.rawToken=nil
      // Reconstruct an ungated shadow FSM to verify the literal original E lifecycle itself.
      let priceBefore=priceEpisodes[symbol]
      var priceState=priceBefore,priceEntered=false,priceExited=false
      if !price.known {priceState=nil;state=nil}
      else if price.fresh {
       let j=price.nativeIndex!
       guard let floor=s.low_prices[j] else {throw NSError(domain:"VendorQuantityMissingQualifiedLow",code:1)}
       try context.need(floor.isFinite && floor>0,"Original qualified native low is positive finite")
       let id=symbol+"|"+s.dates[j]+"|source:"+String(i)
       if let held=priceState {if floor<=held.floor {priceState=nil;priceExited=true}}
       else if price.breakout==true {priceState=Episode(floor:floor,id:id,nativeIndex:j);priceEntered=true}
       if let held=state {if floor<=held.floor {state=nil;exited=true}}
       else if price.breakout==true {
        if allowed {state=Episode(floor:floor,id:id,nativeIndex:j);entered=true}
        else {rejected=true;reasons.append("KNOWN_QUANTITY_REJECTS_NEW_ENTRY")}
       }
      }
      try context.need((priceBefore != nil)==price.holdingBefore && (priceState != nil)==price.holdingAfter && priceEntered==price.entered && priceExited==price.exited,"Independent ungated price FSM exactly matches original E events/state")
      try context.need(priceBefore?.floor.bitPattern==price.stopBefore?.bitPattern && priceState?.floor.bitPattern==price.stopAfter?.bitPattern,"Independent ungated fixed floor Float64 bits")
      try context.need((priceState?.id ?? priceBefore?.id)==price.episodeID,"Independent ungated original episode identity")
      if let priceState {priceEpisodes[symbol]=priceState}else{priceEpisodes.removeValue(forKey:symbol)}
      if !price.known {try context.need(state==nil,"Price UNKNOWN clears quantity policy episode")}
      if price.known && !price.fresh {try context.need(state?.id==before?.id && state?.floor.bitPattern==before?.floor.bitPattern,"Nonfresh retains own episode; no quantity event")}
      try context.need(!(entered && exited) && (!entered || (price.known && price.fresh && before==nil && price.breakout==true && allowed)),"Exit priority/no same-row reentry/quantity gate only new entry")
      if let state {episodes[symbol]=state}else{episodes.removeValue(forKey:symbol)}
     }
     let permission=applies ? price.known && state != nil:price.permission
     dayRows.append(VendorKVOEpisodeRangeEntryRow(index:i,symbol:symbol,civilDate:frameDates[i],mode:mode,originalPriceRow:price,appliesQuantity:applies,scoreSupportKnown:scoreSupportKnown,positiveQuantityWindowKnown:positiveQuantityWindowKnown,scoreKnown:scores != nil,qHistogram:scores?.qHistogram,unitHistogram:scores?.unitHistogram,signedHistogram:scores?.signedHistogram,selectedGate:applies ? allowed:true,window:window,scores:scores,entryAllowed:applies ? allowed:true,entryFallback:applies && fallback,entryRejected:rejected,holdingBefore:applies ? before != nil:price.holdingBefore,holdingAfter:applies ? state != nil:price.holdingAfter,entered:applies ? entered:price.entered,exited:applies ? exited:price.exited,permission:permission,floorBefore:applies ? before?.floor:price.stopBefore,floorAfter:applies ? state?.floor:price.stopAfter,episodeID:applies ? state?.id ?? before?.id:price.episodeID,entryNativeIndex:applies ? state?.nativeIndex:price.indices["entryNativeIndex"],reasons:reasons))
    }
    context.completed.append(dayRows)

   }
   return Dictionary(uniqueKeysWithValues:BreakoutSARExitSignal.symbols.map{symbol in
    (symbol,context.completed.map{rows in rows.first{$0.symbol==symbol}!.permission})
   })
  } catch { throw error }
 }
}
