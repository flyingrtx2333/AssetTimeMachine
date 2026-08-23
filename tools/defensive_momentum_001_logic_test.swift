import Foundation
@main enum DefensiveMomentum001LogicTest {
 static func req(_ c:@autoclosure()->Bool,_ m:String){if !c(){FileHandle.standardError.write(Data(("FAIL: "+m+"\n").utf8));exit(1)}}
 static func main(){
  req(abs(DefensiveMomentum001Logic.targetWeights.values.reduce(0,+)-1.0)<1e-12,"100% gross")
  req(abs((DefensiveMomentum001Logic.targetWeights["splv_tr"] ?? 0)-0.5)<1e-12,"SPLV 50%")
  req(abs((DefensiveMomentum001Logic.targetWeights["mtum_tr"] ?? 0)-0.5)<1e-12,"MTUM 50%")
  req(DefensiveMomentum001Logic.shouldRebalance(current:"2026-01-02",previous:"2025-12-31"),"year boundary")
  req(!DefensiveMomentum001Logic.shouldRebalance(current:"2026-07-01",previous:"2026-06-30"),"same year")
  print("DEFENSIVE_MOMENTUM_001_LOGIC_TEST_OK")
 }
}
