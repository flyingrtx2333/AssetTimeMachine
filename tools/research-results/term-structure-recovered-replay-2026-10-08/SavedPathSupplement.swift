import Foundation

// Read-only reporting from immutable shared-App output. No targets, trades,
// account simulation, parameter choices, Sharpe or alternative metric engine.
struct State: Decodable { let date: Date; let cash: Double; let portfolioValue: Double; let holdingsBySymbol: [String:Double] }
struct Fill: Decodable { let date: Date; let symbol: String; let action: String; let price: Double; let units: Double; let cashAmount: Double }
struct Row: Decodable { let id: String; let dailyStates: [State]; let trades: [Fill] }
struct Frame: Decodable { let dates: [String]; let prices: [String:[Double]] }
let args=CommandLine.arguments
guard args.count==4 else { fatalError("RESULT FRAME OUTPUT") }
let raw=try Data(contentsOf:URL(fileURLWithPath:args[1])),frameRaw=try Data(contentsOf:URL(fileURLWithPath:args[2]))
let decoder=JSONDecoder();decoder.dateDecodingStrategy = .iso8601
let rows=try decoder.decode([Row].self,from:raw),frame=try decoder.decode(Frame.self,from:frameRaw)
guard rows.count==12,!FileManager.default.fileExists(atPath:args[3]) else { fatalError("preserve bounded saved output") }
let formatter=DateFormatter();formatter.timeZone=TimeZone(identifier:"Asia/Shanghai");formatter.dateFormat="yyyy-MM-dd"
func day(_ date:Date)->String { formatter.string(from:date) }
let indices=Dictionary(uniqueKeysWithValues:frame.dates.enumerated().map { ($0.element,$0.offset) })
var output:[[String:Any]]=[]
for row in rows {
    var years:[[String:Any]]=[],previous=row.dailyStates[0].portfolioValue
    for year in 2008...2026 {
        let observations=row.dailyStates.dropFirst().filter { day($0.date).hasPrefix(String(year)) }
        if let end=observations.last {
            years.append(["year":year,"end":day(end.date),"return_percent":(end.portfolioValue/previous-1)*100,
                "partial_final_year":year==2026]);previous=end.portfolioValue
        }
    }
    var peak=row.dailyStates[0],maxDD=0.0,peakDay=day(peak.date),troughDay=peakDay
    for state in row.dailyStates {
        if state.portfolioValue>peak.portfolioValue { peak=state }
        let dd=1-state.portfolioValue/peak.portfolioValue
        if dd>maxDD { maxDD=dd;peakDay=day(peak.date);troughDay=day(state.date) }
    }
    var fee=0.0,slippage=0.0,buys=0,sells=0,buyCash=0.0,sellCash=0.0
    for fill in row.trades {
        let gross=fill.units*fill.price,quoted=frame.prices[fill.symbol]![indices[day(fill.date)]!]
        if fill.action=="buy" {
            fee+=fill.cashAmount-gross;slippage+=fill.units*(fill.price-quoted);buys+=1;buyCash+=fill.cashAmount
        } else {
            guard fill.action=="sell" else { fatalError("invalid saved fill") }
            fee+=gross-fill.cashAmount;slippage+=fill.units*(quoted-fill.price);sells+=1;sellCash+=fill.cashAmount
        }
    }
    let states=Array(row.dailyStates.dropFirst()),exposures=states.map { $0.holdingsBySymbol.values.reduce(0,+)/$0.portfolioValue }
    output.append(["id":row.id,"yearly":years,"drawdown":["percent":maxDD*100,"peak":peakDay,"trough":troughDay],
        "minimum_cash":states.map(\.cash).min()!,"average_actual_gross":exposures.reduce(0,+)/Double(exposures.count),
        "maximum_actual_gross":exposures.max()!,"buy_count":buys,"sell_count":sells,"buy_cash_cny":buyCash,
        "sell_cash_cny":sellCash,"fee_cost_cny":fee,"adverse_slippage_cost_cny":slippage])
}
let object:[String:Any]=["evidence_class":"READONLY_SAVED_APP_PATH_REPORT_SUPPLEMENT","capital_runs":0,
    "new_targets":0,"primary_cagr_sharpe_source":"unchanged shared Swift result.json","rows":output]
try JSONSerialization.data(withJSONObject:object,options:[.prettyPrinted,.sortedKeys])
    .write(to:URL(fileURLWithPath:args[3]))
print("Saved path supplement: all 12 accounts, 19 annual records each; zero capital runs.")
