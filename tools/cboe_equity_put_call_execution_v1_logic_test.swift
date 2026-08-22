import Foundation

@main
struct CboeEquityPutCallExecutionV1LogicTest {
    static func main() {
        let points = [
            CboeEquityPutCallExecutionV1Logic.Point(tradeDate: "2012-06-11", availableDate: "2012-06-12", ratio: 0.60),
            CboeEquityPutCallExecutionV1Logic.Point(tradeDate: "2012-06-12", availableDate: "2012-06-13", ratio: 0.70),
            CboeEquityPutCallExecutionV1Logic.Point(tradeDate: "2012-12-31", availableDate: "2013-01-01", ratio: 0.80),
            CboeEquityPutCallExecutionV1Logic.Point(tradeDate: "2013-01-02", availableDate: "2013-01-03", ratio: 0.50),
        ]
        precondition(CboeEquityPutCallExecutionV1Logic.highPutCallState(points: points, executionDate: "2012-12-31") == nil)
        precondition(CboeEquityPutCallExecutionV1Logic.highPutCallState(points: points, executionDate: "2013-01-01") == true)
        precondition(CboeEquityPutCallExecutionV1Logic.highPutCallState(points: points, executionDate: "2013-01-03") == false)
        precondition(CboeEquityPutCallExecutionV1Logic.latestPoint(points: points, executionDate: "2013-01-01")?.tradeDate == "2012-12-31")

        let prior = ["gold_cny": 0.35, "nasdaq": 0.10, "sp500": 0.10, "csi300": 0.15]
        let current = ["gold_cny": 0.25, "nasdaq": 0.20, "sp500": 0.15, "csi300": 0.10]
        precondition(CboeEquityPutCallExecutionV1Logic.hasUSRiskIncrease(priorBase: prior, currentBase: current))
        let delayed = CboeEquityPutCallExecutionV1Logic.delayedUSIncreaseTarget(
            priorBase: prior,
            currentBase: current,
            delay: true
        )
        precondition(abs((delayed["nasdaq"] ?? 0) - 0.10) < 1e-12)
        precondition(abs((delayed["sp500"] ?? 0) - 0.10) < 1e-12)
        precondition(abs((delayed["gold_cny"] ?? 0) - 0.25) < 1e-12)
        precondition(abs((delayed["csi300"] ?? 0) - 0.10) < 1e-12)

        let immediate = CboeEquityPutCallExecutionV1Logic.delayedUSIncreaseTarget(
            priorBase: prior,
            currentBase: current,
            delay: false
        )
        precondition(abs((immediate["nasdaq"] ?? 0) - 0.20) < 1e-12)
        precondition(abs((immediate["sp500"] ?? 0) - 0.15) < 1e-12)
        print("CBOE_EQUITY_PUT_CALL_EXECUTION_V1_LOGIC_TEST_OK")
    }
}
