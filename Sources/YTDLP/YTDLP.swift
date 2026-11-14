import Foundation
import JavaScriptCore
import YTDLPCore

/// yt-dlp running inside your app on iOS, iPadOS and macOS: no subprocess, no Python or
/// JavaScript runtime to install. Calls take the same arguments as the `yt-dlp` command line.
///
/// ```swift
/// let result = try YTDLP.shared.run(["-J", "--no-playlist", "https://youtu.be/dQw4w9WgXcQ"])
/// let info = try JSONSerialization.jsonObject(with: Data(result.stdout.utf8))
/// ```
///
/// On iOS the app target needs the build phase from `scripts/install-python.sh`, which copies
/// Python's standard library into the app (see README).
public final class YTDLP: @unchecked Sendable {
    public static let shared = YTDLP()

    public struct Output: Decodable, Sendable {
        /// The exit code yt-dlp would have returned (0 = success, 130 = cancelled).
        public let code: Int32
        public let stdout: String
        public let stderr: String
        /// The last "ERROR:" line, for showing to people.
        public var errorMessage: String? {
            stderr.split(whereSeparator: \.isNewline).last(where: { $0.contains("ERROR") }).map(String.init)
                ?? (code == 0 ? nil : stderr.split(whereSeparator: \.isNewline).last.map(String.init))
        }
    }

    public enum Failure: Error, CustomStringConvertible {
        case startFailed(String)
        case callFailed(String)
        public var description: String {
            switch self {
            case .startFailed(let m): return "yt-dlp couldn't start: \(m)"
            case .callFailed(let m): return "yt-dlp failed: \(m)"
            }
        }
    }

    private let lock = NSLock()
    private var started = false

    private init() {}

    /// Starts Python (about a second, once). Every other call does this first if needed.
    public func start() throws {
        lock.lock()
        defer { lock.unlock() }
        if started { return }
        let home = try Self.pythonHome()
        let packages = try Self.packagesPath()
        // yt-dlp caches player JS and solved challenges; the container root isn't writable on iOS.
        if let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
            setenv("XDG_CACHE_HOME", caches.appendingPathComponent("yt-dlp-apple").path, 0)
        }
        // The embedded OpenSSL can't read the Apple keychain: use certifi's CA bundle.
        setenv("SSL_CERT_FILE", packages + "/certifi/cacert.pem", 0)
        #if os(macOS)
        // Python's _ssl module finds OpenSSL through the *host program's* search paths, which
        // test runners and some bundles don't set. Loading it from the framework first works for all.
        for lib in ["libcrypto.3.dylib", "libssl.3.dylib"] { _ = dlopen(home + "/lib/" + lib, RTLD_NOW | RTLD_GLOBAL) }
        #endif
        var error: UnsafeMutablePointer<CChar>?
        if ytdlp_core_start(home, packages, &error) != 0 {
            throw Failure.startFailed(Self.take(error) ?? "unknown error")
        }
        let address = UInt(bitPattern: unsafeBitCast(jsEval, to: UnsafeRawPointer.self))
        _ = try call("set_js_eval", String(address))
        started = true
    }

    /// Runs yt-dlp. `onLine` gets each output line as it's printed (e.g. `--newline` download
    /// progress), on the calling thread. Pass `id` to be able to `cancel(id:)` it. Blocks: call
    /// from a background thread.
    @discardableResult
    public func run(_ arguments: [String], id: String? = nil, onLine: ((String, _ isError: Bool) -> Void)? = nil) throws -> Output {
        try start()
        var request: [String: Any] = ["args": arguments]
        if let id { request["id"] = id }
        let json = String(decoding: try JSONSerialization.data(withJSONObject: request), as: UTF8.self)
        let text: String
        if let onLine {
            let box = LineBox(onLine)
            let context = Unmanaged.passRetained(box).toOpaque()
            defer { Unmanaged<LineBox>.fromOpaque(context).release() }
            text = try call("run", json, line: lineTrampoline, context: context)
        } else {
            text = try call("run", json)
        }
        return try JSONDecoder().decode(Output.self, from: Data(text.utf8))
    }

    /// Stops a `run` started with this id; it returns with code 130.
    public func cancel(id: String) {
        guard started else { return }
        _ = try? call("cancel", id)
    }

    /// `{"ytdlp_apple": "...", "yt_dlp": "...", "python": "..."}`
    public func versions() throws -> [String: String] {
        try start()
        let text = try call("version", "")
        return (try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: String]) ?? [:]
    }

    // MARK: - Plumbing

    private func call(_ function: String, _ argument: String, line: ytdlp_line_fn? = nil, context: UnsafeMutableRawPointer? = nil) throws -> String {
        var error: UnsafeMutablePointer<CChar>?
        guard let result = ytdlp_core_call(function, argument, line, context, &error) else {
            throw Failure.callFailed(Self.take(error) ?? "no result")
        }
        defer { ytdlp_core_free(result) }
        return String(cString: result)
    }

    private static func take(_ p: UnsafeMutablePointer<CChar>?) -> String? {
        guard let p else { return nil }
        defer { ytdlp_core_free(p) }
        return String(cString: p)
    }

    /// Python's home (its standard library).
    /// iOS: `<app>/python`, installed by the build phase. macOS: the linked Python.framework.
    static func pythonHome() throws -> String {
        if let custom = ProcessInfo.processInfo.environment["YTDLP_APPLE_PYTHON_HOME"] { return custom }
        #if os(iOS)
        let home = (Bundle.main.resourcePath ?? "") + "/python"
        guard FileManager.default.fileExists(atPath: home + "/lib") else {
            throw Failure.startFailed("Python's standard library isn't in the app (\(home)). Add the install-python build phase.")
        }
        return home
        #else
        // Wherever the framework got embedded (app Frameworks folder, SwiftPM build dir…).
        var info = Dl_info()
        guard dladdr(dlsym(UnsafeMutableRawPointer(bitPattern: -2), "Py_Initialize"), &info) != 0, let fname = info.dli_fname else {
            throw Failure.startFailed("Python.framework isn't loaded")
        }
        let binary = URL(fileURLWithPath: String(cString: fname)).resolvingSymlinksInPath()
        return binary.deletingLastPathComponent().path // …/Python.framework/Versions/3.14
        #endif
    }

    /// The folder with yt_dlp, yt_dlp_ejs, certifi and ytdlp_apple.
    static func packagesPath() throws -> String {
        let fm = FileManager.default
        if let custom = ProcessInfo.processInfo.environment["YTDLP_APPLE_PACKAGES"] { return custom }
        let bundleName = "ytdlp-apple_YTDLP.bundle"
        var candidates: [URL] = []
        for base in [Bundle.main.resourceURL, Bundle.main.bundleURL, Bundle.main.executableURL?.deletingLastPathComponent()] {
            if let base { candidates.append(base.appendingPathComponent(bundleName)) }
        }
        // SwiftPM's own lookup (also finds the bundle in the build folder during development).
        candidates.append(contentsOf: Bundle.allBundles.map(\.bundleURL).filter { $0.lastPathComponent == bundleName })
        for bundle in candidates {
            for sub in ["python-packages", "Contents/Resources/python-packages"] {
                let path = bundle.appendingPathComponent(sub).path
                if fm.fileExists(atPath: path + "/ytdlp_apple/__init__.py") { return path }
            }
        }
        return Bundle.module.resourceURL!.appendingPathComponent("python-packages").path
    }
}

// MARK: - Line callback

private final class LineBox {
    let handler: (String, Bool) -> Void
    init(_ handler: @escaping (String, Bool) -> Void) { self.handler = handler }
}

private let lineTrampoline: ytdlp_line_fn = { context, line, isError in
    guard let context, let line else { return }
    Unmanaged<LineBox>.fromOpaque(context).takeUnretainedValue().handler(String(cString: line), isError != 0)
}

// MARK: - JavaScriptCore

/// `char *eval(const char *script)`: runs yt-dlp's challenge solver script and returns what it
/// printed with console.log (malloc'd; Python frees it). Each call gets a fresh context.
private let jsEval: @convention(c) (UnsafePointer<CChar>?) -> UnsafeMutablePointer<CChar>? = { script in
    guard let script else { return nil }
    return autoreleasepool {
        guard let context = JSContext() else { return nil }
        var printed: [String] = []
        var failure: String?
        let log: @convention(block) () -> Void = {
            let parts = JSContext.currentArguments()?.compactMap { ($0 as? JSValue)?.toString() } ?? []
            printed.append(parts.joined(separator: " "))
        }
        let ignore: @convention(block) () -> Void = {}
        let console = JSValue(newObjectIn: context)!
        console.setObject(log, forKeyedSubscript: "log" as NSString)
        for name in ["warn", "error", "info", "debug"] { console.setObject(ignore, forKeyedSubscript: name as NSString) }
        context.setObject(console, forKeyedSubscript: "console" as NSString)
        context.exceptionHandler = { _, exception in failure = exception?.toString() ?? "JavaScript exception" }
        context.evaluateScript(String(cString: script))
        if let failure, printed.isEmpty {
            // The shape yt-dlp's solver reports errors in.
            let data = try? JSONSerialization.data(withJSONObject: ["type": "error", "error": failure])
            return strdup(String(decoding: data ?? Data(), as: UTF8.self))
        }
        return strdup(printed.joined(separator: "\n"))
    }
}
