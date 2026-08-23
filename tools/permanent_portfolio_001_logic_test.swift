import Foundation
@main enum PermanentPortfolio001LogicTest {
 static func req(_ c:@autoclosure()->Bool,_ m:String){if !c(){FileHandle.standardError.write(Data(("FAIL: "+m+"\n").utf8));exit(1)}}
 static func main(){
  req(abs(PermanentPortfolio001Logic.targetWeights.values.reduce(0,+)-0.75)<1e-12,"gross target 75% leaving 25% cash")
  req(PermanentPortfolio001Logic.shouldRebalance(current:"2026-01-02",previous:"2025-12-31"),"year boundary")
  req(!PermanentPortfolio001Logic.shouldRebalance(current:"2026-06-01",previous:"2026-05-29"),"same year")
  print("PERMANENT_PORTFOLIO_001_LOGIC_TEST_OK")
 }
}
