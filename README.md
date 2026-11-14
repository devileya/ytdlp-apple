# ytdlp-apple

[yt-dlp](https://github.com/yt-dlp/yt-dlp) as a Swift package for **iOS, iPadOS and macOS**: it
runs inside your app on an embedded Python, with no subprocess and nothing for the user to install.

- **iPhone / iPad**: apps can't start other programs, so yt-dlp runs in-process.
- **YouTube's JavaScript challenges** (n/sig) are solved by Apple's **JavaScriptCore** through a
  yt-dlp JS challenge provider (`javascriptcore`), instead of Deno/Node/Bun.
- **macOS**: the same library, plus an `ytdlp-apple` executable that takes the same arguments and
  prints the same output as `yt-dlp`. Apps that shell out to yt-dlp can bundle it instead of
  asking for `brew install yt-dlp`.

| Part | Version |
|---|---|
| Python | 3.14.10 ([BeeWare Python-Apple-support](https://github.com/beeware/Python-Apple-support) 3.14-b14) |
| yt-dlp | 2026.10.26 |
| yt-dlp-ejs (challenge solver scripts) | 0.8.0 |
| certifi (CA certificates for the embedded OpenSSL) | 2026.10.23 |

## Use it

```swift
// Package.swift
.package(url: "https://github.com/devileya/ytdlp-apple.git", from: "0.1.0"),
// target dependency
.product(name: "YTDLP", package: "ytdlp-apple"),
```

```swift
import YTDLP

// Blocks: call it off the main thread.
let out = try YTDLP.shared.run(["-J", "--no-playlist", "-f", "bestaudio[ext=m4a]/bestaudio",
                                "https://www.youtube.com/watch?v=dQw4w9WgXcQ"])
guard out.code == 0 else { throw MyError(out.errorMessage ?? "yt-dlp failed") }
let info = try JSONSerialization.jsonObject(with: Data(out.stdout.utf8))

// Downloads, with progress lines as they're printed, and cancellation.
try YTDLP.shared.run(["--newline", "-f", "bestaudio[ext=m4a]", "-o", dir + "/%(title)s.%(ext)s", url],
                     id: "job-1") { line, isError in print(line) }
YTDLP.shared.cancel(id: "job-1") // the run returns with code 130
```

### iOS / iPadOS: one build phase

Python's standard library has to be copied into the app (iOS doesn't allow loose `.so` files, so
each one becomes a signed framework). Add a **Run Script** phase after *Copy Bundle Resources*:

```sh
"${BUILD_DIR%/Build/*}/SourcePackages/checkouts/ytdlp-apple/scripts/install-python.sh"
```

Uncheck *Based on dependency analysis*, and set **User Script Sandboxing = No** for the target
(the script writes into the app bundle).

### macOS: the `ytdlp-apple` command

```sh
swift build -c release --product ytdlp-apple
.build/release/ytdlp-apple --ytdlp-apple-version
```

Ship it next to `Python.framework` (in `Contents/Frameworks`) and the `ytdlp-apple_YTDLP.bundle`
(in `Contents/Resources`); add `@executable_path/../Frameworks` to its rpath.

## Notes

- Size: about 40 MB (Python standard library ≈ 30 MB, yt-dlp ≈ 12 MB uncompressed).
- No ffmpeg is included: download formats that don't need merging or converting
  (e.g. `bestaudio[ext=m4a]`, or muxed `best[ext=mp4]`), or pass `--ffmpeg-location` if you have one.
- yt-dlp needs updating often to keep up with YouTube. Update the pinned versions in
  `scripts/vendor-python-packages.sh`, run it, and tag a new release.
- App Store review rejects apps that download from YouTube. This is for your own builds
  (development, Ad Hoc, TestFlight internal testing). Only download content you have the right to.

## Develop

```sh
scripts/build-python-xcframework.sh    # Frameworks/Python.xcframework + dist/Python.xcframework.zip
scripts/vendor-python-packages.sh      # yt-dlp, yt-dlp-ejs, certifi → Sources/YTDLP/Resources
YTDLP_NETWORK_TESTS=1 swift test       # includes real YouTube lookups and a cancelled download
```

With `Frameworks/Python.xcframework` present, `Package.swift` uses it; otherwise it downloads the
release asset `python-3.14-b14/Python.xcframework.zip`.

## Licenses

This package's own code: MIT ([LICENSE](LICENSE)). Bundled: yt-dlp and yt-dlp-ejs (Unlicense),
certifi (MPL-2.0), texts in [LICENSES/](LICENSES); Python (PSF License) ships inside Python.xcframework.
