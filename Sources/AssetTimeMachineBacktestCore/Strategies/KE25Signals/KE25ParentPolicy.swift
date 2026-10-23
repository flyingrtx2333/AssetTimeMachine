import Foundation

// Original CDF252/streak3 P math, with only the documented forward clock extension.
// The frozen final streak block still expires at index5753; future source5758,5763,... resume normally.
struct KE25PolicyFrame {
 let dates:[String], simulationRange:[Int], tradableSymbols:[String]
 let pricesBySymbol:[String:[Double]], observedBySymbol:[String:[Bool]]
}
private struct KE25PolicyTarget: Codable {
 let sourceOrdinal:Int,sourceFrameIndex:Int,sourceDate:Date,sourceCivilDate:String,availability:String
 let earliestExecutionIndex:Int?,earliestExecutionDate:Date?,featureEpochFrameIndex:Int,modelAvailableFrameIndex:Int?
 let targetWeights:[String:Double]
}
private func require(_ ok:Bool,_ message:String)throws {
 if !ok {throw BacktestConfigurationError.invalidParameter("KE25: "+message)}
}
enum KE25ParentPolicy {
 static func weights(_ frame:KE25PolicyFrame,_ dates:[Date])throws->[[String:Double]] {
  try makeBooks(makeSource(frame),frame,dates)[1].map(\.targetWeights)
 }
}
private let plans=["blend-h126-cdf75","blend-h252-cdf75-primary","blend-h504-cdf75","blend-h252-cdf60","blend-h252-cdf90","cdf252-unchanged-control","streak3-unchanged-control","cdf252-cash25-control"]
private let mixH=[0,1,2,1,1],mixCDF=[0.75,0.75,0.75,0.6,0.9]
private enum CDF {
static let plans=["reset126","reset252-primary","reset504","constant-remaining252-control","flat-half-control","full-base-control"]
static let horizons=[126,252,504]
static func closeMath(_ a:Double,_ b:Double,_ msg:String)throws{try require(a.isFinite && b.isFinite && abs(a-b)<=1e-11*max(1,abs(a),abs(b)),msg)}
static func cdf(_ d:Double)throws->Double{
 let p=0.5*erfc(-d/sqrt(2.0)),other=0.5*(1+erf(d/sqrt(2.0))),reflection=0.5*erfc(d/sqrt(2.0))
 try require(d.isFinite && p.isFinite && p>=0 && p<=1,"Finite bounded normal CDF on actual source parameter")
 try closeMath(p,other,"Actual CDF erf/erfc forms");try closeMath(p+reflection,1,"Actual CDF complement identity")
 return p
}
struct Point:Codable{let horizon:Int,anchor:Int,age:Int,remaining:Int;let anchorPrice:Double,logRatio:Double,d:Double,annualFormD:Double,participation:Double}
struct AssetState:Codable{let asset:String,activation:Int;let logSigma63:Double,constantRemainingD:Double,constantRemainingParticipation:Double;let points:[Point]}
struct Epoch:Codable{let source:Int,date:String,known:Bool,assets:[String],unavailableAssets:[String];let base:[String:Double],assetStates:[AssetState],targets:[[String:Double]]}
static func legal(_ f:KE25PolicyFrame,_ s:String,_ i:Int)->Bool{let p=f.pricesBySymbol[s]![i];return f.observedBySymbol[s]![i] && p>0 && p.isFinite && (s != "csi300" || f.dates[i]>="2005-04-08")}
static func makeModels(_ f:KE25PolicyFrame)throws->[Epoch]{
 if f.dates.count<=63{return []}
 let groups=[["gold_cny"],["sp500","nasdaq"],["csi300","shanghai_composite"]];var activation=[String:Int](),out=[Epoch]()
 for i in 63..<f.dates.count{
  var sd=[String:Double]()
  for s in f.tradableSymbols{if !(i-63...i).allSatisfy({legal(f,s,$0)}){continue};let ps=f.pricesBySymbol[s]!,rs=(i-62...i).map{log(ps[$0]/ps[$0-1])},mean=rs.reduce(0,+)/63,variance=rs.reduce(0){$0+pow($1-mean,2)}/62
   if variance>0 && variance.isFinite{sd[s]=sqrt(variance)}
  }
  let complete=groups.filter{$0.allSatisfy{sd[$0] != nil}},assets=f.tradableSymbols.filter{s in complete.contains{$0.contains(s)}}
  try require(assets.contains("gold_cny") && assets.contains("sp500") && assets.contains("nasdaq"),"Prespecified complete public gold/US64-price positive logvariance source domain")
  for s in f.tradableSymbols where !assets.contains(s){activation[s]=nil}
  var base=[String:Double](),states=[AssetState](),targets=Array(repeating:[String:Double](),count:6)
  for s in assets{
   if activation[s]==nil{activation[s]=i};let start=activation[s]!,ps=f.pricesBySymbol[s]!,sigma=sd[s]!,group=complete.first{$0.contains(s)}!,budget=1/Double(complete.count)/Double(group.count);base[s]=budget
   var points=[Point]()
   for (k,h) in horizons.enumerated(){let age=(i-start)%h,anchor=i-age,remaining=h-age,K=ps[anchor],ratio=log(ps[i]/K),scale=sigma*sqrt(Double(remaining)),d=ratio/scale+0.5*scale,annual=sigma*sqrt(252),tau=Double(remaining)/252,dAnnual=(ratio+0.5*annual*annual*tau)/(annual*sqrt(tau)),differenceForm=(log(ps[i])-log(K))/scale+0.5*scale
    try require(anchor>=start && anchor<=i && legal(f,s,anchor) && age>=0 && age<h && remaining>=1 && remaining<=h,"Actual known anchor and positive remaining joint-observation count")
    try closeMath(d,dAnnual,"Observation and annualized variance/time units cancel");try closeMath(d,differenceForm,"Actual source log ratio versus log price difference")
    if age==0{try require(anchor==i && K==ps[i] && ratio==0,"Exact contemporaneous reset, no future fixed strike or derivative price")}
    let part=try cdf(d);points.append(.init(horizon:h,anchor:anchor,age:age,remaining:remaining,anchorPrice:K,logRatio:ratio,d:d,annualFormD:dAnnual,participation:part));if part>0{targets[k][s]=budget*part}
   }
   let point=points[1],scale=sigma*sqrt(252),constantD=point.logRatio/scale+0.5*scale,constantPart=try cdf(constantD)
   if constantPart>0{targets[3][s]=budget*constantPart};targets[4][s]=budget*0.5;targets[5][s]=budget
   if point.age==0{try require(constantD.bitPattern==point.d.bitPattern && constantPart.bitPattern==point.participation.bitPattern,"Constant-remaining control and primary exactly coincide at actual252 reset")}
   states.append(.init(asset:s,activation:start,logSigma63:sigma,constantRemainingD:constantD,constantRemainingParticipation:constantPart,points:points))
  }
  try require(abs(base.values.reduce(0,+)-1)<1e-12,"Complete public groups equal region/member base before CDF participation")
  for j in plans.indices{try require(targets[j].values.allSatisfy{$0.isFinite && $0>=0} && targets[j].values.reduce(0,+)<=1+1e-12,"Unlevered price-only participation fractions, no redistribution of cash budget")}
  out.append(.init(source:i,date:f.dates[i],known:true,assets:assets,unavailableAssets:f.tradableSymbols.filter{!assets.contains($0)},base:base,assetStates:states,targets:targets))
 }
 return out
}
static func makeBooks(_ models:[Epoch],_ f:KE25PolicyFrame,_ dates:[Date])throws->[[KE25PolicyTarget]]{
 var outputs=Array(repeating:[KE25PolicyTarget](),count:6),latest=Array(repeating:[String:Double](),count:6),epoch=21,available:Int?
 let by=Dictionary(uniqueKeysWithValues:models.map{($0.source,$0)})
 for i in 21..<f.dates.count{if let m=by[i]{latest=m.targets;epoch=i;available=i}
  for j in plans.indices{outputs[j].append(.init(sourceOrdinal:i-21,sourceFrameIndex:i,sourceDate:dates[i],sourceCivilDate:f.dates[i],availability:available==nil ? "64_PUBLIC_PRICE_FORMATION_CASH":"FROZEN_RESET_HORIZON_PRICE_CDF_POLICY",earliestExecutionIndex:i+1<f.dates.count ? i+1:nil,earliestExecutionDate:i+1<f.dates.count ? dates[i+1]:nil,featureEpochFrameIndex:epoch,modelAvailableFrameIndex:available,targetWeights:latest[j]))}
 }
 return outputs
}

}
private enum Negative {
 struct Feature:Codable{let asset:String;let source:Int;let down:[Bool];let streak:Int;let norm:Double;let weight:Double}
 static func produce(_ f:KE25PolicyFrame)throws->[Feature]{
  if f.dates.count<=63{return []}
  let symbols=f.tradableSymbols,thresholds=[2,3,4]
  func group(_ s:String)->String{s=="gold_cny" ? "gold":(["sp500","nasdaq"].contains(s) ? "us":"china")}
  var features:[Feature]=[],records:[[String:Any]]=[],epochs:[[String:Any]]=[]
  let sourceIndices=Array(stride(from:63,through:f.dates.count-1,by:5)).filter { $0 != 5753 }
  for i in sourceIndices{
   var legal:[String:Bool]=[:],norms:[String:Double]=[:],downs:[String:[Bool]]=[:],streaks:[String:Int]=[:]
   for s in symbols{
    let ps=f.pricesBySymbol[s]!
    let ok=((i-63)...i).allSatisfy{f.observedBySymbol[s]![$0] && ps[$0]>0 && ps[$0].isFinite && (s != "csi300" || f.dates[$0]>="2005-04-08")};legal[s]=ok
    if !ok{continue}
    let rs=((i-62)...i).map{ps[$0]/ps[$0-1]-1},mean=rs.reduce(0,+)/63
    let sigma=sqrt(rs.reduce(0){$0+pow($1-mean,2)}/62)
    if sigma<=0 || !sigma.isFinite{legal[s]=false;continue}
    let ds=(0..<4).map{ps[i-$0]<ps[i-$0-1]}
    let streak=ds.prefix(while:{$0}).count
    norms[s]=sigma*sqrt(5);downs[s]=ds;streaks[s]=streak
   }
   for members in [["gold_cny"],["sp500","nasdaq"],["csi300","shanghai_composite"]]{let complete=members.allSatisfy{legal[$0]!};for s in members{legal[s]=complete}}
   let available=symbols.filter{legal[$0]!},groups=Set(available.map{group($0)})
   try require(!groups.isEmpty,"At leastone knownpublic sourcegroup")
   for s in symbols{
    if !legal[s]!{for k in thresholds{records.append(["asset":s,"streakThreshold":k,"sourceIndex":i,"sourceDate":f.dates[i],"available":false,"reason":"Completegroup64publicobservedprices/positive63variance unavailable"])};continue}
    let members=available.filter{group($0)==group(s)}.count,w=1/Double(groups.count)/Double(members)
    features.append(.init(asset:s,source:i,down:downs[s]!,streak:streaks[s]!,norm:norms[s]!,weight:w))
   }
  }

  return features
 }
}

private struct SourceBook:Codable{let cdf:[CDF.Epoch],negative:[Negative.Feature]}
private func makeSource(_ f:KE25PolicyFrame)throws->SourceBook{.init(cdf:try CDF.makeModels(f),negative:try Negative.produce(f))}
private func streakBooks(_ source:SourceBook,_ f:KE25PolicyFrame,_ dates:[Date])throws->[KE25PolicyTarget]{
 var out=[KE25PolicyTarget](),latest=[String:Double](),epoch=21,available:Int?;let by=Dictionary(grouping:source.negative,by:{$0.source})
 for i in 21..<f.dates.count{
  if let xs=by[i]{try require(abs(xs.reduce(0.0){$0+$1.weight}-1)<1e-12,"Original complete group capital before streak filter");latest=Dictionary(uniqueKeysWithValues:xs.filter{$0.streak>=3}.map{($0.asset,$0.weight)});epoch=i;available=i}
  if i==5753{latest=[:];epoch=i;available=i}
  out.append(.init(sourceOrdinal:i-21,sourceFrameIndex:i,sourceDate:dates[i],sourceCivilDate:f.dates[i],availability:available==nil ? "ORIGINAL_FIXED_CLOCK_FORMATION_CASH":(i>=5753 && i<5758 ? "KNOWN_FIXED_FIVE_RETURN_BLOCK_EXPIRY_CASH":"ORIGINAL_FIVE_FRAME_SOURCE_POLICY"),earliestExecutionIndex:i+1<f.dates.count ? i+1:nil,earliestExecutionDate:i+1<f.dates.count ? dates[i+1]:nil,featureEpochFrameIndex:epoch,modelAvailableFrameIndex:available,targetWeights:latest))
 };return out
}
private func makeBooks(_ source:SourceBook,_ f:KE25PolicyFrame,_ dates:[Date])throws->[[KE25PolicyTarget]]{
 let cc=try CDF.makeBooks(source.cdf,f,dates),nn=try streakBooks(source,f,dates);var books=Array(repeating:[KE25PolicyTarget](),count:8)
 for j in plans.indices{if j==5{books[j]=cc[1];continue};if j==6{books[j]=nn;continue}
  for k in nn.indices{let i=k+21,cdfRow=cc[j==7 ? 1:mixH[j]][k],negativeRow=nn[k],a=j==7 ? 0.75:mixCDF[j],b=j==7 ? 0.0:1-a;var target=[String:Double]()
   for s in f.tradableSymbols{let cv=cdfRow.targetWeights[s] ?? 0,nv=negativeRow.targetWeights[s] ?? 0,w=a*cv+b*nv;try require(w.isFinite && w>=0,"Nonnegative component target mixture");try CDF.closeMath(w,j==7 ? a*cv:nv+a*(cv-nv),"Independent algebraic merged asset target identity");if w>0{target[s]=w}}
   let cGross=cdfRow.targetWeights.values.reduce(0,+),nGross=negativeRow.targetWeights.values.reduce(0,+),gross=target.values.reduce(0,+)
   try require(gross<=1+1e-12,"No leverage across complete merged portfolio");try CDF.closeMath(1-gross,a*(1-cGross)+b*(1-nGross)+(1-a-b),"Component idle cash stays cash without redistribution")
   books[j].append(.init(sourceOrdinal:k,sourceFrameIndex:i,sourceDate:dates[i],sourceCivilDate:f.dates[i],availability:i<63 ? "ORIGINAL64_FORMATION_CASH":"FROZEN_NETTED_CDF_AND_STREAK_COMPONENT_CAPITAL",earliestExecutionIndex:i+1<f.dates.count ? i+1:nil,earliestExecutionDate:i+1<f.dates.count ? dates[i+1]:nil,featureEpochFrameIndex:i<63 ? 21:i,modelAvailableFrameIndex:i<63 ? nil:i,targetWeights:target))
  }
 };return books
}
