import Foundation
@main enum FedPolicyDirection001LogicTest {
 static func req(_ c:@autoclosure()->Bool,_ m:String){if !c(){FileHandle.standardError.write(Data(("FAIL: "+m+"\n").utf8));exit(1)}}
 static func main(){
  let events=[FedPolicyDirection001Logic.Event(dateKey:"2024-09-19",state:.easing),FedPolicyDirection001Logic.Event(dateKey:"2025-12-11",state:.easing),FedPolicyDirection001Logic.Event(dateKey:"2026-09-17",state:.tightening)]
  req(FedPolicyDirection001Logic.state(executionDateKey:"2024-09-19",events:events) == nil,"same-day event unavailable")
  req(FedPolicyDirection001Logic.state(executionDateKey:"2024-09-20",events:events) == .easing,"next day sees easing")
  req(FedPolicyDirection001Logic.state(executionDateKey:"2026-09-17",events:events) == .easing,"same-day tightening unavailable")
  req(FedPolicyDirection001Logic.state(executionDateKey:"2026-09-18",events:events) == .tightening,"next day sees tightening")
  print("FED_POLICY_DIRECTION_001_LOGIC_TEST_OK")
 }
}
