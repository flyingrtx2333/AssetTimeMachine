"""Check the shared API date parser, including repeated and uncached dates."""
from pathlib import Path
import subprocess
import tempfile


def test_api_date_parser():
    root = Path(__file__).resolve().parents[1]
    source = (root / "AssetTimeMachine/Services/BackgroundTaskWork.swift").read_text()
    parser = source[source.index("nonisolated final class FlexibleAPIDateParser:"):source.index("/// Synchronously observes")]
    checks = r'''
let parser = FlexibleAPIDateParser()
let epoch = Date(timeIntervalSince1970: 0)
for value in ["1970-01-01T00:00:00Z", "1970-01-01T00:00:00.000Z",
              "1970-01-01T08:00:00+08:00", "1970-01-01T08:00:00"] {
    precondition(parser.date(from: value) == epoch)
    precondition(parser.date(from: value) == epoch)
}
precondition(parser.date(from: "invalid-date") == nil)
let formatter = ISO8601DateFormatter()
for offset in 1...9000 {
    let expected = Date(timeIntervalSince1970: Double(offset))
    let value = formatter.string(from: expected)
    precondition(parser.date(from: value) == expected)
    precondition(parser.date(from: value) == expected)
}
precondition(parser.date(from: "1970-01-01T00:00:00.125Z") == epoch.addingTimeInterval(0.125))
print("PASS: UTC, offset, local dates, fractions, repeated dates and bounded-cache overflow")
'''
    with tempfile.TemporaryDirectory(prefix="atm-api-dates-") as folder:
        main = Path(folder) / "main.swift"
        executable = Path(folder) / "probe"
        main.write_text("import Foundation\n" + parser + checks)
        subprocess.run(["swiftc", "-O", str(main), "-o", str(executable)], check=True, cwd=root)
        subprocess.run([str(executable)], check=True)


if __name__ == "__main__":
    test_api_date_parser()
