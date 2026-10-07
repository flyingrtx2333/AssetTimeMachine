import XCTest
import AssetTimeMachineResearchSupport

final class SPFGrowthRevisionTests: XCTestCase {
    func testSameTargetQuarterPublicDateAndZeroRevision() throws {
        let surveys = [
            SPFGrowthRevisionScreen.Survey(year: 2004, quarter: 1, releaseDate: "2004-02-13", deadlineDate: "2004-02-10", currentGrowth: 99, nextGrowth: 2),
            .init(year: 2004, quarter: 2, releaseDate: "2004-05-14", deadlineDate: "2004-05-11", currentGrowth: 3, nextGrowth: 4),
            .init(year: 2004, quarter: 3, releaseDate: "2004-08-13", deadlineDate: "2004-08-10", currentGrowth: 4, nextGrowth: 5),
            .init(year: 2004, quarter: 4, releaseDate: "2004-11-12", deadlineDate: "2004-11-09", currentGrowth: 1, nextGrowth: 6)]
        let days = ["2004-05-11","2004-05-14","2004-05-17","2004-08-13","2004-08-16","2004-11-12","2004-11-15"]
        let d = try SPFGrowthRevisionScreen.decisions(days: days, surveys: surveys)
        XCTAssertEqual(d.map(\.weight), [0,0,1,1,1,1,0])
        XCTAssertEqual(d[2].revisionPP, 1); XCTAssertEqual(d[4].revisionPP, 0)
        XCTAssertFalse(d[4].changed); XCTAssertEqual(d[6].revisionPP, -4)
        XCTAssertEqual(d[2].releaseDate, "2004-05-14")
        let opposite = try SPFGrowthRevisionScreen.decisions(days: days, surveys: surveys, inverse: true)
        XCTAssertEqual(opposite.map(\.weight), [0,0,0,0,0,0,1])
    }
    func testFutureSurveyDoesNotAlterPrefixAndNonAdjacentSurveyRejected() throws {
        let first = SPFGrowthRevisionScreen.Survey(year: 2025, quarter: 4, releaseDate: "2025-11-17", deadlineDate: "2025-11-11", currentGrowth: 1, nextGrowth: 2)
        let second = SPFGrowthRevisionScreen.Survey(year: 2026, quarter: 1, releaseDate: "2026-03-06", deadlineDate: "2026-03-02", currentGrowth: 3, nextGrowth: 4)
        let future = SPFGrowthRevisionScreen.Survey(year: 2026, quarter: 2, releaseDate: "2026-05-15", deadlineDate: "2026-05-12", currentGrowth: -100, nextGrowth: 999)
        let days = ["2026-02-13","2026-03-02","2026-03-06","2026-03-09"]
        let prefix = try SPFGrowthRevisionScreen.decisions(days: days, surveys: [first,second])
        XCTAssertEqual(prefix, try SPFGrowthRevisionScreen.decisions(days: days, surveys: [first,second,future]))
        XCTAssertEqual(prefix.map(\.weight), [0,0,0,1])
        XCTAssertThrowsError(try SPFGrowthRevisionScreen.decisions(days: days, surveys: [first,future]))
    }
}
