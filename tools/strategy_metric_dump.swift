// Compatibility source entry. Build with: swift run -c release AssetTimeMachineMetricDump
// Historical grids are replayed from their recorded Git version by scripts/replay_legacy_research.py.
import AssetTimeMachineResearchSupport
@main struct StrategyMetricDump {
    static func main() throws { try StrategyMetricDumpCLI.run() }
}
