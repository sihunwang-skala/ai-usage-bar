import Foundation

@main
struct ClaudeParserSmoke {
    static func main() throws {
        let data = Data(#"""
        {
          "version": 2,
          "samples": [
            {"t": 1700000000000, "org": "one", "u": {"fh": 88, "sd": 25}},
            {"t": 1700000300000, "org": "one", "u": {"fh": 12, "sd": 34}}
          ]
        }
        """#.utf8)
        let snapshot = try ClaudeDesktopUsageReader.parse(data)
        precondition(snapshot.fiveHour?.usedPercent == 12)
        precondition(snapshot.weekly?.usedPercent == 34)
        precondition(snapshot.updatedAt == Date(timeIntervalSince1970: 1_700_000_300))

        let clamped = try ClaudeDesktopUsageReader.parse(Data(#"""
        {"version":2,"samples":[{"t":1,"org":null,"u":{"fh":-5,"sd":140}}]}
        """#.utf8))
        precondition(clamped.fiveHour?.usedPercent == 0)
        precondition(clamped.weekly?.usedPercent == 100)

        do {
            _ = try ClaudeDesktopUsageReader.parse(Data(#"{"version":2,"samples":[]}"#.utf8))
            preconditionFailure("empty history must fail")
        } catch ClaudeDesktopUsageReader.ReadError.noSamples {
            // Expected.
        }

        print("Claude Desktop usage parser: OK")
    }
}
