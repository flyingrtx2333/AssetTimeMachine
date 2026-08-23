import Foundation
@main enum FactorDuration001LogicTest {
 static func req(_ c:@autoclosure()->Bool,_ m:String){if !c(){FileHandle.standardError.write(Data(("FAIL: "+m+"\n").utf8));exit(1)}}
 static func main(){req(abs(FactorDuration001Logic.targetWeights.values.reduce(0,+)-1)<1e-12,"100% gross");req(FactorDuration001Logic.targetWeights.values.allSatisfy{abs($0 - 0.25)<1e-12},"equal 25% sleeves");req(FactorDuration001Logic.shouldRebalance(current:"2026-01-02",previous:"2025-12-31"),"annual boundary");req(!FactorDuration001Logic.shouldRebalance(current:"2026-03-02",previous:"2026-02-27"),"no monthly rebalance");print("FACTOR_DURATION_001_LOGIC_TEST_OK")}
}
