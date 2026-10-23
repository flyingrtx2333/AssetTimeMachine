import Foundation
import XCTest
import AssetTimeMachineBacktestCore
@testable import AssetTimeMachineResearchSupport

final class MeanVarianceUtilityCoreScreenTests: XCTestCase {
    typealias Screen = MeanVarianceUtilityCoreScreen
    private let first = BacktestSeriesAlignment.historicalSeriesDate(from: "2025-01-01")!
    private func dates(_ n: Int) -> [Date] { (0..<n).map { first.addingTimeInterval(Double($0)*86400) } }
    private func prices(_ n: Int) -> [String:[Double]] {
        var result: [String:[Double]] = [:]
        for a in 0..<3 {
            var row = [100.0 + Double(a)*32]
            for i in 1..<n {
                let perturb: Double
                switch a { case 0: perturb = i%2 == 0 ? 0.001 : -0.001
                case 1: perturb = Double(i%3-1)*0.0005
                default: perturb = Double(i%5-2)*0.00025 }
                row.append(row.last! * (1 + Double(a+1)*0.001 + perturb))
            }; result[Screen.coreSymbols[a]] = row
        }; return result
    }
    private func constant(_ n: Int) -> [String:[Double]] {
        Dictionary(uniqueKeysWithValues: Screen.coreSymbols.map { ($0,Array(repeating:100.0,count:n)) })
    }
    private func frame(_ p: [String:[Double]], dates d: [Date]? = nil) -> MarketDataFrame {
        let dates = d ?? self.dates(p["gold_cny"]!.count)
        return .init(dates:dates,pricesBySymbol:p,observedBySymbol:Dictionary(uniqueKeysWithValues: Screen.coreSymbols.map { ($0,Array(repeating:true,count:dates.count)) }),
            ohlcBySymbol:[:],tradableSymbols:Screen.coreSymbols,optionBySymbol:[:],simulationRange:0...(dates.count-1))
    }
    private func native(_ p: [String:[Double]], closed: [String:Set<Int>] = [:]) throws -> Screen.NativePreparation {
        let d=dates(p["gold_cny"]!.count), rate=0.125
        let bars=Dictionary(uniqueKeysWithValues: Screen.coreSymbols.map { symbol in
            (symbol,d.indices.filter { !(closed[symbol]?.contains($0) ?? false) }.map { Screen.PriceBar(date:d[$0],price:p[symbol]![$0]*(symbol=="gold_cny" ? 1:rate)) })
        })
        let fx=(-1..<d.count).map { Screen.FXPoint(date:first.addingTimeInterval(Double($0)*86400),usdPerCNY:rate) }
        return try Screen.nativePreparation(barsBySymbol:bars,fxPoints:fx,fundedDates:d)
    }
    private let diagonal = [[0.01,0,0],[0,0.01,0],[0,0,0.01]]
    private func fixtureFace(_ ordinal: Int, weights: [Double], value: Double) -> Screen.Face {
        let gross=weights.reduce(0,+)
        let objective=Screen.Objective(expectedProducts:[],expectedTerm:value,rowProducts:[],rowSums:[],outerProducts:[],quadraticTerm:0,riskTerm:0,value:value)
        return .init(ordinal:ordinal,mask:0,activeIndices:[],subsetSolveIndex:nil,solverLabel:"cash",economicLabel:"cash",lambda:0,
            rawWeights:weights,budgetClosure:nil,weights:weights,gross:gross,positiveSupportCount:weights.filter{$0>0}.count,
            activePositiveChecks:[],strictBudgetCheck:gross<=1,fullBudgetChecksumError:nil,fullBudgetChecksumCheck:nil,feasible:true,rejectReason:nil,objective:objective)
    }
    private func artificialRun(_ prep: Screen.NativePreparation, scheduled: Set<Int>, target: @escaping(Int)->[String:Double]) throws -> Screen.NativeRun {
        try Screen.simulate(preparation:prep,buyReason:"fixed artificial MVU ledger fixture",schedule:{scheduled.contains($0)},target:target)
    }
    private func ledger(_ run: Screen.NativeRun, _ prep: Screen.NativePreparation, file: StaticString=#filePath,line:UInt=#line) {
        var cash=100000.0,units:[String:Double]=[:],interest=0.0
        for (i,s) in run.simulation.dailyStates.enumerated() {
            if i>0 { let earned=max(cash,0)*CashYieldCNY.periodReturn(from:prep.frame.dates[i-1],to:s.date);cash+=earned;interest+=earned }
            for trade in run.simulation.trades.filter({$0.date==s.date}) {
                XCTAssertTrue(prep.frame.observedBySymbol[trade.assetSymbol]![i],file:file,line:line)
                XCTAssertEqual(trade.price,prep.executionPrices[trade.assetSymbol]![i],file:file,line:line)
                if trade.action == .buy {
                    cash-=trade.cashAmount;units[trade.assetSymbol,default:0]+=trade.units
                    XCTAssertEqual(trade.units*trade.price,trade.cashAmount*(1-0.00025),accuracy:1e-8,file:file,line:line)
                } else {
                    cash+=trade.cashAmount;units[trade.assetSymbol,default:0]-=trade.units
                    XCTAssertEqual(trade.cashAmount,trade.units*trade.price*(1-0.00025),accuracy:1e-8,file:file,line:line)
                }
            }
            let held=Screen.coreSymbols.reduce(0.0){$0+(units[$1] ?? 0)*prep.frame.pricesBySymbol[$1]![i]}
            XCTAssertEqual(s.cash,cash,accuracy:1e-7,file:file,line:line)
            XCTAssertEqual(s.portfolioValue,cash+held,accuracy:1e-7,file:file,line:line)
            XCTAssertGreaterThanOrEqual(s.cash,-1e-8,file:file,line:line)
            XCTAssertLessThanOrEqual(held,s.portfolioValue+1e-7,file:file,line:line)
        }
        XCTAssertEqual(run.simulation.cashYieldSummary.totalCashInterest,interest,accuracy:1e-7,file:file,line:line)
    }
    func testFrozenConstantsAndSourceClock() {
        XCTAssertEqual(Screen.window,252);XCTAssertEqual(Screen.gamma,20);XCTAssertEqual(Screen.cadence,21)
        XCTAssertEqual(Screen.coreSymbols,["gold_cny","nasdaq","sp500"])
        XCTAssertFalse(Screen.eligible(251));XCTAssertTrue(Screen.eligible(252));XCTAssertFalse(Screen.eligible(253));XCTAssertTrue(Screen.eligible(273))
    }
    func testRetained252CashRowsFirstFullSignalNoTrimming() throws {
        let rows=try Screen.signals(frame:frame(prices(255)))
        XCTAssertEqual(rows.count,255)
        XCTAssertTrue(rows.prefix(252).allSatisfy{$0.latentWeights==[0,0,0] && $0.estimator==nil && $0.optimization==nil && $0.cleanedTarget.isEmpty})
        XCTAssertEqual(rows[252].firstAllowedExecutionIndex,253)
        XCTAssertEqual(rows[252].estimator!.intervalIndices,Array(1...252))
        XCTAssertEqual(rows[253].latentWeights,rows[252].latentWeights);XCTAssertNil(rows[253].estimator)
        XCTAssertEqual(rows[253].retainedFromSignalIndex,252)
    }
    func test252SimpleExcessMeanUpperCovarianceSample251HandReference() throws {
        let f=frame(prices(253)),e=try Screen.estimate(frame:f,signalIndex:252)
        var ref:[[Double]]=[]
        for a in 0..<3 {
            var r:[Double]=[]
            for t in 1...252 { r.append(f.pricesBySymbol[Screen.coreSymbols[a]]![t]/f.pricesBySymbol[Screen.coreSymbols[a]]![t-1]-1-e.cashIntervals[t-1].periodReturn) }
            ref.append(r)
            XCTAssertEqual(e.meanSums[a],r.reduce(0,+))
            XCTAssertEqual(e.means[a],r.reduce(0,+)/252)
            XCTAssertNotEqual(e.simpleReturns[a][1],log(f.pricesBySymbol[Screen.coreSymbols[a]]![2]/f.pricesBySymbol[Screen.coreSymbols[a]]![1]))
        }
        XCTAssertEqual(e.covariancePairs.map{[$0.row,$0.column]},[[0,0],[0,1],[0,2],[1,1],[1,2],[2,2]])
        for a in 0..<3 { for b in a..<3 {
            var sum=0.0
            for t in 0..<252 { sum+=(ref[a][t]-e.means[a])*(ref[b][t]-e.means[b]) }
            XCTAssertEqual(e.covariance[a][b],sum/251);XCTAssertEqual(e.covariance[a][b],e.covariance[b][a])
            XCTAssertNotEqual(e.covariance[a][a],e.covarianceSums[a][a]/252)
        } }
    }
    func testCashUsesCompletedCalendarWeekendAndEffectiveChangeNotTrading252() throws {
        let end=ISO8601DateFormatter().date(from:"2012-07-05T00:00:00Z")!
        var d=(0..<252).map{end.addingTimeInterval(Double($0-251)*86400)}
        d.append(ISO8601DateFormatter().date(from:"2012-07-08T00:00:00Z")!)
        let e=try Screen.estimate(frame:frame(prices(253),dates:d),signalIndex:252),c=e.cashIntervals.last!
        var factor=1.0
        for rate in [0.004,0.0035,0.0035] { factor*=1+rate/365.25 }
        XCTAssertEqual(c.periodReturn,factor-1)
        XCTAssertEqual(c.effectiveRateSegments.count,2)
        XCTAssertEqual(c.effectiveRateSegments[1].effectiveDate,ISO8601DateFormatter().date(from:"2012-07-06T00:00:00Z"))
        XCTAssertTrue(c.effectiveRateSegments.allSatisfy{$0.effectiveDate < c.toDate})
        XCTAssertNotEqual(c.periodReturn,0.003/252)
    }
    func testNegativeExcessValidCovarianceChoosesCashNotInvalidFallback() throws {
        let o=try Screen.optimize(mu:[-0.02,-0.01,-0.03],covariance:diagonal)
        XCTAssertEqual(o.winningOrdinal,0);XCTAssertEqual(o.winningWeights,[0,0,0]);XCTAssertEqual(o.winningCashWeight,1)
        XCTAssertEqual(o.faces.count,15);XCTAssertEqual(o.subsets.count,7);XCTAssertTrue(o.kkt.valid)
        XCTAssertTrue(o.kkt.checks.prefix(3).allSatisfy{$0.direction=="less-or-equal"})
    }
    func testInteriorSlackHandSolvedResidualCashAndUtility() throws {
        let o=try Screen.optimize(mu:[0.02,0.04,0.06],covariance:diagonal)
        for (a,w) in [0.1,0.2,0.3].enumerated(){XCTAssertEqual(o.winningWeights[a],w,accuracy:1e-14)}
        XCTAssertEqual(o.winningGross,0.6,accuracy:1e-14);XCTAssertEqual(o.winningCashWeight,0.4,accuracy:1e-14)
        XCTAssertEqual(o.winningSolverLabel,"slack");XCTAssertEqual(o.winningLambda,0)
        XCTAssertEqual(o.winningObjective,0.014,accuracy:1e-14)
    }
    func testFullBudgetCornerOriginalMultiplierKKT() throws {
        let o=try Screen.optimize(mu:[1,-1,-1],covariance:diagonal)
        XCTAssertEqual(o.winningWeights,[1,0,0]);XCTAssertEqual(o.winningGross,1)
        XCTAssertEqual(o.winningSolverLabel,"full_budget");XCTAssertEqual(o.winningLambda,0.8,accuracy:1e-14)
        XCTAssertEqual(o.kkt.activeIndices,[0]);XCTAssertTrue(o.kkt.budgetBinding)
    }
    func testExactGrossOneSlackRetainsUAndZeroMultiplierClass() throws {
        let c=[[0.05,0,0],[0,0.05,0],[0,0,0.05]],o=try Screen.optimize(mu:[1,-1,-1],covariance:c)
        XCTAssertEqual(o.winningOrdinal,1);XCTAssertEqual(o.winningSolverLabel,"slack")
        XCTAssertEqual(o.winningEconomicLabel,"full_budget_unconstrained_lambda_zero")
        XCTAssertNil(o.faces[1].budgetClosure);XCTAssertEqual(o.winningLambda,0)
        XCTAssertEqual(o.faces[1].weights,o.faces[2].weights)
    }
    func testCrossCovarianceChangesInteriorComposition() throws {
        let mu=[0.02,0.04,0.06],a=try Screen.optimize(mu:mu,covariance:diagonal)
        let c=[[0.01,0.004,0],[0.004,0.01,0.002],[0,0.002,0.01]],b=try Screen.optimize(mu:mu,covariance:c)
        XCTAssertNotEqual(a.winningWeights,b.winningWeights)
        XCTAssertTrue(b.kkt.valid);XCTAssertEqual(b.subsets[6].matrixA[0][1],20*0.004)
    }
    func testAllSevenFacesOrderedSignedSolvesAndResidualEvidence() throws {
        let o=try Screen.optimize(mu:[0.02,0.04,0.06],covariance:diagonal)
        XCTAssertEqual(o.subsets.map(\.mask),Array(1...7));XCTAssertEqual(o.faces.map(\.ordinal),Array(0...14))
        XCTAssertEqual(o.subsets.map(\.activeIndices),[[0],[1],[0,1],[2],[0,2],[1,2],[0,1,2]])
        for s in o.subsets {
            XCTAssertTrue(s.uSolve.residuals.allSatisfy{abs($0)<1e-14})
            XCTAssertTrue(s.vSolve.residuals.allSatisfy{abs($0)<1e-14})
            XCTAssertEqual(s.fullBudgetLambda,(s.sumU-1)/s.sumV)
            XCTAssertEqual(s.cholesky.steps.count,s.activeIndices.count*(s.activeIndices.count+1)/2)
        }
    }
    func testOnlyFullFaceClosesHighestActiveCoordinateWithoutNormalization() throws {
        let o=try Screen.optimize(mu:[0.4,0.3,0.2],covariance:diagonal)
        for f in o.faces {
            if f.solverLabel=="full_budget" {
                let c=f.budgetClosure!
                XCTAssertEqual(c.coreIndex,f.activeIndices.last)
                XCTAssertEqual(c.closedCoordinate,1-c.earlierWeights.reduce(0,+))
                XCTAssertEqual(f.weights[c.coreIndex],c.closedCoordinate)
                for i in c.earlierCoreIndices{XCTAssertEqual(f.weights[i],f.rawWeights[i])}
                XCTAssertEqual(f.lambda,o.subsets[f.mask-1].fullBudgetLambda)
            } else {XCTAssertNil(f.budgetClosure);XCTAssertEqual(f.weights,f.rawWeights)}
        }
    }
    func testExactObjectiveTieGrossSupportLexicographicThenOrdinal() {
        let cash=fixtureFace(0,weights:[0,0,0],value:1),risky=fixtureFace(1,weights:[0.1,0,0],value:1)
        XCTAssertTrue(Screen.preferred(cash,over:risky).0)
        let one=fixtureFace(2,weights:[0.5,0,0],value:1),two=fixtureFace(3,weights:[0.25,0.25,0],value:1)
        XCTAssertTrue(Screen.preferred(one,over:two).0)
        let a=fixtureFace(4,weights:[0,0.5,0],value:1),b=fixtureFace(5,weights:[0.5,0,0],value:1)
        XCTAssertTrue(Screen.preferred(a,over:b).0)
        XCTAssertTrue(Screen.preferred(fixtureFace(4,weights:a.weights,value:1),over:fixtureFace(5,weights:a.weights,value:1)).0)
    }
    func testOneULPObjectiveDifferenceNeverUsesApproximateTieBand() {
        let a=fixtureFace(10,weights:[1,0,0],value:1.nextUp),b=fixtureFace(0,weights:[0,0,0],value:1)
        XCTAssertTrue(Screen.preferred(a,over:b).0);XCTAssertEqual(Screen.preferred(a,over:b).1,"objective_greater")
    }
    func testZeroPSDAndSingularCovarianceRejectBeforeCashChoice() {
        for c in [[[0.0,0,0],[0,0,0],[0,0,0]],[[1.0,1,0],[1,1,0],[0,0,1]],[[1.0,2,0],[2,1,0],[0,0,1]]] {
            XCTAssertThrowsError(try Screen.optimize(mu:[-1,-1,-1],covariance:c))
        }
    }
    func testSignedOffDiagonalAndTrueZeroCancellationLegal() throws {
        let f=try Screen.cholesky([[4,-2,0],[-2,4,0],[0,0,1]])
        XCTAssertEqual(f.lower[1][0],-1);XCTAssertEqual(f.lower[2][0],0)
        let o=try Screen.optimize(mu:[-0.0,0,0],covariance:diagonal)
        XCTAssertEqual(o.winningWeights,[0,0,0]);XCTAssertTrue(o.kkt.valid)
        XCTAssertEqual(o.subsets[6].uSolve.solution,[0,0,0])
    }
    func testObservableUnderflowNonfiniteAndNegativeQuadAbort() {
        XCTAssertThrowsError(try Screen.objective(mu:[0,0,0],covariance:[[Double.leastNonzeroMagnitude,0,0],[0,1,0],[0,0,1]],weights:[0.5,0,0]))
        XCTAssertThrowsError(try Screen.optimize(mu:[.infinity,0,0],covariance:diagonal))
        XCTAssertThrowsError(try Screen.optimize(mu:[.nan,0,0],covariance:diagonal))
        XCTAssertThrowsError(try Screen.objective(mu:[0,0,0],covariance:[[-1,0,0],[0,1,0],[0,0,1]],weights:[1,0,0]))
        do { _ = try Screen.cholesky([[1,.nan,0],[.nan,1,0],[0,0,1]]);XCTFail("NaN must preserve actual operand diagnostic before symmetry") }
        catch BacktestConfigurationError.invalidParameter(let text) {
            let start=text.range(of:"{")!
            let obj=try! JSONSerialization.jsonObject(with:Data(text[start.lowerBound...].utf8)) as! [String:Any]
            XCTAssertEqual(obj["reason"] as? String,"nonfinite")
            XCTAssertEqual(obj["field"] as? String,"matrix[0][1]")
            XCTAssertEqual((obj["operands"] as! [[String:Any]]).first!["category"] as? String,"NaN")
        } catch { XCTFail("Unexpected diagnostic type \(error)") }
    }
    func testWinnerKKTResidualToleranceVerifiesNeverRepairsWeights() throws {
        let k=try Screen.verifyKKT(mu:[0.02,0.04,0.06],covariance:diagonal,weights:[0.1,0.2,0.3],lambda:0)
        XCTAssertEqual(k.weights,[0.1,0.2,0.3])
        for c in k.checks{XCTAssertEqual(c.tolerance,1e-10+1e-10*max(abs(c.lhs),abs(c.rhs)))}
        XCTAssertThrowsError(try Screen.verifyKKT(mu:[0.02,0.04,0.06],covariance:diagonal,weights:[0.1,0.2,0.3],lambda:0.01))
        XCTAssertThrowsError(try Screen.verifyKKT(mu:[0,0,0],covariance:diagonal,weights:[0.5,0.25,0.25+1e-13],lambda:0))
    }
    func testPastPrefixInvariantToFuturePricesAndDates() throws {
        let p=prices(280),f=frame(p),rows=try Screen.signals(frame:f)
        let prefix=Dictionary(uniqueKeysWithValues: p.map{($0.key,Array($0.value.prefix(270)))})
        XCTAssertEqual(Array(rows.prefix(270)),try Screen.signals(frame:frame(prefix)))
        var future=p;for s in Screen.coreSymbols{future[s]![279]*=8}
        var d=dates(280);d[279]=d[279].addingTimeInterval(10*86400)
        XCTAssertEqual(Array(rows.prefix(279)),Array(try Screen.signals(frame:frame(future,dates:d)).prefix(279)))
    }
    func testStrictPriorQuoteDayFXOnceCarryCannotExecuteAndFutureFXIgnored() throws {
        let d=dates(3),bars=Dictionary(uniqueKeysWithValues: Screen.coreSymbols.map{ s in
            (s,[Screen.PriceBar(date:d[0],price:s=="gold_cny" ? 100:12.5),Screen.PriceBar(date:d[2],price:s=="gold_cny" ? 102:13)])
        })
        let prior=Screen.FXPoint(date:first.addingTimeInterval(-86400),usdPerCNY:0.125),today=Screen.FXPoint(date:first,usdPerCNY:0.25)
        let fx=[prior,today,Screen.FXPoint(date:d[2].addingTimeInterval(86400),usdPerCNY:999)]
        let prep=try Screen.nativePreparation(barsBySymbol:bars,fxPoints:fx,fundedDates:d)
        XCTAssertEqual(prep.frame.pricesBySymbol["nasdaq"]![0],100)
        XCTAssertEqual(prep.frame.pricesBySymbol["nasdaq"]![1],100);XCTAssertEqual(prep.executionPrices["nasdaq"]![1],0)
        XCTAssertEqual(prep.frame.pricesBySymbol["nasdaq"]![2],52)
        let q=prep.quotes.first{$0.symbol=="nasdaq" && $0.index==1}!
        XCTAssertEqual(q.fxDate,prior.date);XCTAssertFalse(q.quoteToday)
    }
    func testFourFixedBinaryCanonicalUnitRepresentationsPreserveModel() throws {
        let p=prices(275),base=try Screen.signals(frame:frame(p))
        for exponents in [[10,10,10],[-10,-10,-10],[8,-4,2],[-6,5,-2]] {
            let shadow=Dictionary(uniqueKeysWithValues: Screen.coreSymbols.enumerated().map{a,s in(s,p[s]!.map{$0*Double(sign:.plus,exponent:exponents[a],significand:1)})})
            let rows=try Screen.signals(frame:frame(shadow))
            for s in rows.indices {
                XCTAssertEqual(rows[s].latentWeights,base[s].latentWeights)
                XCTAssertEqual(rows[s].isEligible,base[s].isEligible)
                XCTAssertEqual(rows[s].estimator?.simpleReturns,base[s].estimator?.simpleReturns)
                XCTAssertEqual(rows[s].estimator?.means,base[s].estimator?.means)
                XCTAssertEqual(rows[s].estimator?.covariance,base[s].estimator?.covariance)
                XCTAssertEqual(rows[s].optimization,base[s].optimization)
            }
        }
    }
    func testGenuineSharedAccount252FormationFirst253AndFixed21Clock() throws {
        let prep=try native(prices(278)),signals=try Screen.signals(frame:prep.frame),run=try Screen.runAccount(preparation:prep,signals:signals,role:.candidate)
        XCTAssertEqual(run.simulation.dailyStates.count,278)
        XCTAssertEqual(run.decisions[0].signalIndex,0);XCTAssertEqual(run.decisions[0].signalDate,prep.frame.dates[0])
        XCTAssertEqual(run.decisions[0].sourceLatentTarget,["gold_cny":0,"nasdaq":0,"sp500":0])
        XCTAssertFalse(run.decisions.prefix(253).contains{$0.shouldRebalance})
        XCTAssertFalse(run.simulation.trades.contains{$0.date<prep.frame.dates[253]})
        XCTAssertEqual(run.decisions.filter(\.scheduledReview).map(\.index),[253,274])
        XCTAssertEqual(run.decisions[253].deliverySignalIndex,252)
        XCTAssertEqual(run.simulation.dailyStates[0].cash,100000);ledger(run,prep)
    }
    func testQuoteDelayAndCompletionNeverMoveSourceCadence() throws {
        let prep=try native(constant(285),closed:["sp500":[253,254,255]])
        let run=try artificialRun(prep,scheduled:[253,274]){_ in ["sp500":0.5]}
        XCTAssertTrue(run.decisions[254].transportOnly);XCTAssertTrue(run.decisions[256].completedToday)
        XCTAssertFalse(run.decisions[257].shouldRebalance)
        XCTAssertEqual(run.decisions.filter(\.scheduledReview).map(\.index),[253,274]);ledger(run,prep)
    }
    func testPendingOnlyRedeliversSavedMapWithoutSourceLookupOrReclean() throws {
        let prep=try native(constant(7),closed:["sp500":[1,2]])
        var calls=0
        let run=try artificialRun(prep,scheduled:[1]){_ in calls+=1;return ["sp500":0.7]}
        XCTAssertEqual(calls,1)
        for i in [2,3] {XCTAssertEqual(run.decisions[i].requestedTarget,run.decisions[i].pendingBefore);XCTAssertTrue(run.decisions[i].transportOnly)}
        XCTAssertFalse(run.decisions[4].shouldRebalance);ledger(run,prep)
    }
    func testCompletedOffcycleNoFreshRequestDuplicateScheduledStillRequests() throws {
        let prep=try native(constant(6)),run=try artificialRun(prep,scheduled:[1,3]){_ in ["gold_cny":0.4]}
        XCTAssertEqual(run.decisions.filter(\.providerCalled).map(\.index),[1,3])
        XCTAssertFalse(run.decisions[2].shouldRebalance);XCTAssertFalse(run.decisions[4].shouldRebalance)
        XCTAssertEqual(run.completions.map(\.index),[1,3]);ledger(run,prep)
    }
    func testRapidABAPendingReplacementNeverTradesStaleB() throws {
        let prep=try native(constant(8),closed:["sp500":[3,4]])
        let run=try artificialRun(prep,scheduled:[1,3,5]){s in s==2 ? ["sp500":0.8]:["gold_cny":0.8]}
        XCTAssertNotNil(run.decisions[4].pendingAfter)
        XCTAssertEqual(run.decisions[5].requestedTarget,["gold_cny":0.8])
        XCTAssertEqual(run.decisions[5].latestDeliverySignalIndexAfter,4)
        XCTAssertFalse(run.simulation.trades.contains{$0.assetSymbol=="sp500"});ledger(run,prep)
    }
    func testCashExitEmptyPendingDistinctFromNoRequestClosedHeldQuote() throws {
        let prep=try native(constant(8),closed:["gold_cny":[3,4]])
        let run=try artificialRun(prep,scheduled:[1,3]){s in s==0 ? ["gold_cny":0.5]:[:]}
        XCTAssertEqual(run.decisions[3].pendingAfter,[:]);XCTAssertTrue(run.decisions[4].transportOnly)
        XCTAssertTrue(run.decisions[5].completedToday);XCTAssertNil(run.decisions[5].pendingAfter)
        XCTAssertFalse(run.decisions[6].shouldRebalance);XCTAssertTrue(run.simulation.dailyStates[5].holdingsBySymbol.values.allSatisfy{abs($0)<1e-7});ledger(run,prep)
    }
    func testPriorSettledCashCanBuyButNewSaleWaitsNextSessionFeesExact() throws {
        let prep=try native(constant(7)),run=try artificialRun(prep,scheduled:[1,3]){s in s==0 ? ["gold_cny":0.8]:["sp500":0.8]}
        let same=run.simulation.trades.filter{$0.date==prep.frame.dates[3]},next=run.simulation.trades.filter{$0.date==prep.frame.dates[4]}
        XCTAssertTrue(same.contains{$0.action == .sell && $0.assetSymbol=="gold_cny"})
        XCTAssertTrue(same.contains{$0.action == .buy && $0.assetSymbol=="sp500"})
        XCTAssertLessThan(same.filter{$0.action == .buy}.reduce(0){$0+$1.cashAmount},25000)
        XCTAssertTrue(next.contains{$0.action == .buy && $0.assetSymbol=="sp500"})
        XCTAssertTrue(run.decisions[3].pendingAfter != nil);XCTAssertTrue(run.decisions[4].completedToday);ledger(run,prep)
    }
    func testNineGuardEquivalenceFirstFailureJSONWithoutThresholdChanges() throws {
        func state(_ cash:Double,_ nav:Double,_ target:[String:Double]) -> BacktestDailyState {
            .init(date:first,targetWeights:target,cash:cash,holdingsBySymbol:[:],portfolioValue:nav)
        }
        for s in [state(100,100,[:]),state(100,100,["gold_cny":1+2e-12]),state(-1,100,[:]),state(0,.infinity,[:]),state(100,100,["sp500":.nan])] {
            var original=false,fresh=false
            do{_ = try DailyScreenOutput.row("fixture",states:[s],trades:[],windows:[]);original=true}catch{}
            do{try Screen.validateAccounting("fixture",states:[s]);fresh=true}catch{}
            XCTAssertEqual(fresh,original)
        }
        let firstBad=state(-1,100,[:]),secondBad=state(1,0,[:])
        do{try Screen.validateAccounting("fixture",states:[firstBad,secondBad]);XCTFail("must reject")}
        catch BacktestConfigurationError.invalidParameter(let text) {
            let start=text.range(of:"{")!
            let obj=try JSONSerialization.jsonObject(with:Data(text[start.lowerBound...].utf8)) as! [String:Any]
            XCTAssertEqual(obj["cash"] as? Double,-1);XCTAssertEqual((obj["clauses"] as! [String:Bool]).count,9)
        }
    }
    func testOptionalSourceAndDecisionFieldsControlsBaselineAndSnapshotCopies() throws {
        let prep=try native(prices(255)),signals=try Screen.signals(frame:prep.frame),encoder=JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let objects=try Screen.signalObjects(signals,encoder:encoder)
        for s in [0,251,253] {for key in ["estimator","optimization","firstAllowedExecutionIndex"]{XCTAssertTrue(objects[s][key] is NSNull)}}
        XCTAssertTrue(objects[0]["retainedFromSignalIndex"] is NSNull)
        XCTAssertEqual(signals[252].incomingLatent,[0,0,0]);XCTAssertEqual(signals[253].incomingLatent,signals[252].latentWeights)
        XCTAssertEqual(signals[0].rawTarget,["gold_cny":0,"nasdaq":0,"sp500":0])
        let small=try native(constant(6)),warm=try Screen.signals(frame:small.frame)
        for role in [Screen.Role.equal,.cash] {
            let run=try Screen.runAccount(preparation:small,signals:warm,role:role)
            XCTAssertEqual(run.decisions.filter(\.scheduledReview).map(\.index),Array(1...5))
            XCTAssertEqual(run.simulation.dailyStates.first!.cash,100000)
            XCTAssertFalse(run.simulation.trades.contains{$0.date==first});ledger(run,small)
        }
    }
    func testExportFrozenSourceMath() throws {
        let env=ProcessInfo.processInfo.environment
        guard let path=env["ASSET_MVU_SOURCE_PRIMITIVES_PATH"],let dump=env["ASSET_MVU_SOURCE_DUMP_PATH"] else {
            throw XCTSkip("Root-controlled pure source export; builder never supplies these environments.")
        }
        struct Primitive:Decodable {
            struct Bar:Decodable{let date:String;let valuation_price:Double}
            struct FX:Decodable{let date:String;let usd_per_cny:Double}
            let schema:String;let cutoff:String;let baseline:String;let series:[String:[Bar]]
            let funded_union_calendar:[String];let original_strictprior_FX_observations:[FX]
        }
        let raw=try Data(contentsOf:URL(fileURLWithPath:path))
        guard ResearchRunEvidence.sha256(raw)=="290d8a36402dcc467b6450370b72e4baae6f222a6e432e927f123d732f546946" else {throw BacktestConfigurationError.invalidParameter("MVU source-only frozen primitive hash")}
        let input=try JSONDecoder().decode(Primitive.self,from:raw)
        guard input.schema=="fixed-rp63-core-source-primitives-v1",input.cutoff=="2026-10-06",input.baseline=="2001-06-25",input.funded_union_calendar.count==6452 else {throw BacktestConfigurationError.invalidParameter("MVU source-only primitive contract")}
        func date(_ s:String)throws->Date{try XCTUnwrap(BacktestSeriesAlignment.historicalSeriesDate(from:s))}
        var bars:[String:[Screen.PriceBar]]=[:]
        for symbol in Screen.coreSymbols{bars[symbol]=try XCTUnwrap(input.series[symbol]).map{.init(date:try date($0.date),price:$0.valuation_price)}}
        let fx=try input.original_strictprior_FX_observations.map{Screen.FXPoint(date:try date($0.date),usdPerCNY:$0.usd_per_cny)}
        let prep=try Screen.nativePreparation(barsBySymbol:bars,fxPoints:fx,fundedDates:input.funded_union_calendar.map(date))
        let encoder=JSONEncoder();encoder.dateEncodingStrategy = .iso8601;encoder.outputFormatting = [.sortedKeys]
        let outputs=[dump]+(1...4).map{dump+String(format:".unit-case%02d.json",$0)}
        guard outputs.allSatisfy({!FileManager.default.fileExists(atPath:$0)}) else {throw CocoaError(.fileWriteFileExists)}
        func write(_ f:MarketDataFrame,_ destination:String)throws{
            let signals=try Screen.signals(frame:f)
            let object=try Screen.signalObjects(signals,encoder:encoder)
            try JSONSerialization.data(withJSONObject:object,options:[.sortedKeys]).write(to:URL(fileURLWithPath:destination))
            XCTAssertEqual(signals.count,6452)
        }
        try write(prep.frame,dump)
        let exponents=[[10,10,10],[-10,-10,-10],[8,-4,2],[-6,5,-2]]
        for caseIndex in exponents.indices {
            let shadow=Dictionary(uniqueKeysWithValues: Screen.coreSymbols.enumerated().map{a,s in
                (s,prep.frame.pricesBySymbol[s]!.map{$0*Double(sign:.plus,exponent:exponents[caseIndex][a],significand:1)})})
            try write(frame(shadow,dates:prep.frame.dates),outputs[caseIndex+1])
        }
        print("MVU_SOURCE_EXPORT_COMPLETE " + String(data:try JSONSerialization.data(withJSONObject:["canonical":outputs[0],"unitSidecars":Array(outputs.dropFirst()),"rowCount":6452],options:[.sortedKeys]),encoding:.utf8)!)
        // Pure primitive preparation and source/cash interval math only.
        // No ACCOUNTS decode, real simulator/account interest/NAV/metrics call.
    }
}
