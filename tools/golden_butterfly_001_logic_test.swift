import Foundation
@main enum GoldenButterfly001LogicTest {
 static func req(_ c:@autoclosure()->Bool,_ m:String){if !c(){FileHandle.standardError.write(Data(("FAIL: "+m+"\n").utf8));exit(1)}}
 static func main(){
  req(abs(GoldenButterfly001Logic.targetWeights.values.reduce(0,+)-1.0)<1e-12,"gross target 100%")
  req(GoldenButterfly001Logic.targetWeights.values.allSatisfy{abs($0-0.20)<1e-12},"all five sleeves fixed 20%")
  req(GoldenButterfly001Logic.shouldRebalance(current:"2026-01-02",previous:"2025-12-31"),"year boundary")
  req(!GoldenButterfly001Logic.shouldRebalance(current:"2026-06-01",previous:"2026-05-29"),"same year")
  print("GOLDEN_BUTTERFLY_001_LOGIC_TEST_OK")
 }
}
