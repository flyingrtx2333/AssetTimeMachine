import Foundation
@main enum BTCSMA200001LogicTest {
 static func req(_ c:@autoclosure()->Bool,_ m:String){if !c(){FileHandle.standardError.write(Data(("FAIL: "+m+"\n").utf8));exit(1)}}
 static func main(){
  var rising=(1...205).map(Double.init)
  req(BTCSMA200001Logic.active(signalIndex:199,prices:rising)==true,"rising price above 200-day SMA")
  var falling=(1...205).map{Double(206-$0)}
  req(BTCSMA200001Logic.active(signalIndex:199,prices:falling)==false,"falling price below 200-day SMA")
  let before=BTCSMA200001Logic.active(signalIndex:199,prices:rising)
  rising[200]=1_000_000
  req(BTCSMA200001Logic.active(signalIndex:199,prices:rising)==before,"future price cannot affect signal")
  req(BTCSMA200001Logic.active(signalIndex:198,prices:rising)==nil,"need full 200 completed observations")
  print("BTC_SMA200_001_LOGIC_TEST_OK")
 }
}
