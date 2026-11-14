// `ytdlp-apple`: the yt-dlp command line, running on the embedded Python.
// Same arguments and output as `yt-dlp`, so apps that shell out to yt-dlp can bundle this instead.
import Foundation
import YTDLP

setvbuf(stdout, nil, _IOLBF, 0)
let arguments = Array(CommandLine.arguments.dropFirst())
if arguments == ["--ytdlp-apple-version"] {
    let v = (try? YTDLP.shared.versions()) ?? [:]
    print("ytdlp-apple \(v["ytdlp_apple"] ?? "?") (yt-dlp \(v["yt_dlp"] ?? "?"), Python \(v["python"] ?? "?"))")
    exit(0)
}

// Ctrl-C / kill -INT: stop yt-dlp cleanly (partial files are removed like the real one).
signal(SIGINT, SIG_IGN)
signal(SIGTERM, SIG_IGN)
let runID = UUID().uuidString
for sig in [SIGINT, SIGTERM] {
    let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
    source.setEventHandler { YTDLP.shared.cancel(id: runID) }
    source.resume()
    _ = Unmanaged.passRetained(source as AnyObject)
}

do {
    let output = try YTDLP.shared.run(arguments, id: runID) { line, isError in
        let data = Data((line + "\n").utf8)
        (isError ? FileHandle.standardError : FileHandle.standardOutput).write(data)
    }
    exit(output.code)
} catch {
    FileHandle.standardError.write(Data("ERROR: \(error)\n".utf8))
    exit(1)
}
