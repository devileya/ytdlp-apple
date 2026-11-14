import XCTest
@testable import YTDLP

final class YTDLPTests: XCTestCase {
    func testStartsAndReportsVersions() throws {
        let v = try YTDLP.shared.versions()
        XCTAssertEqual(v["python"]?.hasPrefix("3.14"), true)
        XCTAssertNotNil(v["yt_dlp"])
    }

    func testJavaScriptCoreProviderIsRegistered() throws {
        let out = try YTDLP.shared.run(["--version"])
        XCTAssertEqual(out.code, 0)
        XCTAssertFalse(out.stdout.isEmpty)
    }

    /// Network: a real YouTube lookup, which needs the n/sig challenges solved (JavaScriptCore).
    func testLooksUpYouTubeAudio() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["YTDLP_NETWORK_TESTS"] == nil, "set YTDLP_NETWORK_TESTS=1")
        var lines: [String] = []
        let out = try YTDLP.shared.run(
            ["-J", "--no-warnings", "--no-playlist", "-f", "bestaudio[ext=m4a]/bestaudio", "-v", "https://www.youtube.com/watch?v=dQw4w9WgXcQ"],
            onLine: { line, isError in if isError { lines.append(line) } })
        XCTAssertEqual(out.code, 0, out.stderr)
        let info = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(out.stdout.utf8)) as? [String: Any])
        XCTAssertEqual(info["id"] as? String, "dQw4w9WgXcQ")
        let url = try XCTUnwrap((info["url"] as? String) ?? ((info["requested_formats"] as? [[String: Any]])?.first?["url"] as? String))
        XCTAssertTrue(url.hasPrefix("https://"))
        XCTAssertTrue(lines.contains { $0.contains("javascriptcore") }, "challenges weren't solved with JavaScriptCore:\n" + lines.joined(separator: "\n"))
    }

    func testCancelStopsARun() throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["YTDLP_NETWORK_TESTS"] == nil, "set YTDLP_NETWORK_TESTS=1")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        DispatchQueue.global().asyncAfter(deadline: .now() + 6) { YTDLP.shared.cancel(id: "t") }
        let out = try YTDLP.shared.run(
            ["--newline", "-f", "18", "--limit-rate", "50K", "-o", dir.path + "/%(id)s.%(ext)s", "https://www.youtube.com/watch?v=dQw4w9WgXcQ"],
            id: "t")
        XCTAssertEqual(out.code, 130, out.stderr)
    }
}
