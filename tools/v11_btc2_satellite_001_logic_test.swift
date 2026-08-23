import Foundation
@main enum V11BTC2Satellite001LogicTest {
 static func req(_ c:@autoclosure()->Bool,_ m:String){if !c(){FileHandle.standardError.write(Data(("FAIL: "+m+"\n").utf8));exit(1)}}
 static func main(){
  let full=["gold_cny":0.4,"nasdaq":0.6]
  let o=V11BTC2Satellite001Logic.overlay(base:full)!
  req(abs((o["btc_cny"] ?? 0)-0.02)<1e-12,"BTC fixed 2%")
  req(abs((o["gold_cny"] ?? 0)-0.392)<1e-12,"core scaled 98%")
  req(abs(o.values.reduce(0,+)-1.0)<1e-12,"full base remains 100% gross")
  let defensive=V11BTC2Satellite001Logic.overlay(base:["gold_cny":0.2])!
  req(abs(defensive.values.reduce(0,+)-0.216)<1e-12,"de-risked V11 remains de-risked plus fixed satellite")
  req(V11BTC2Satellite001Logic.overlay(base:["bad":-0.1]) == nil,"short base rejected")
  print("V11_BTC2_SATELLITE_001_LOGIC_TEST_OK")
 }
}
