import Foundation
@main enum BTCHalving001LogicTest {
 static func req(_ c:@autoclosure()->Bool,_ m:String){if !c(){FileHandle.standardError.write(Data(("FAIL: "+m+"\n").utf8));exit(1)}}
 static func main(){
  req(BTCHalving001Logic.active(executionDateKey:"2020-05-11")==false,"same-day halving unavailable")
  req(BTCHalving001Logic.active(executionDateKey:"2020-05-12")==true,"next day active")
  req(BTCHalving001Logic.active(executionDateKey:"2021-05-11")==true,"365th calendar day active")
  req(BTCHalving001Logic.active(executionDateKey:"2021-05-12")==false,"day 366 inactive")
  req(BTCHalving001Logic.active(executionDateKey:"2024-04-20")==false,"2024 same-day unavailable")
  req(BTCHalving001Logic.active(executionDateKey:"2024-04-22")==true,"next common-session-style date active")
  req(BTCHalving001Logic.active(executionDateKey:"2025-04-21")==false,"after 365 days inactive")
  print("BTC_HALVING_001_LOGIC_TEST_OK")
 }
}
