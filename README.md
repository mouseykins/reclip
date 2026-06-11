# Reclip

A native macOS app for downloading videos (and clips from videos) from YouTube, TikTok, Vimeo, and hundreds of other sites. Wraps [`yt-dlp`](https://github.com/yt-dlp/yt-dlp) in a SwiftUI interface with a built-in player so you can preview the video, pick an exact start/end with a range slider, and save just the part you want.

## Features

- **Paste a URL, preview the video** in a native AVPlayer — no browser, no iframe
- **Frame-accurate clip selection** via a dual-handle range slider; dragging seeks the video to that frame
- **Download full video or just a clip** — each clip gets a timestamped filename so it doesn't overwrite the full copy
- **Quality & format picker** — MP4 (multiple resolutions) or MP3 audio extraction
- **QuickTime-compatible output** — automatic repackaging; VP9 sources get hardware-accelerated HEVC transcoding with `hvc1` tagging
- **Built-in console** — every external command is logged with timestamps and color-coded levels
- **First-launch setup screen** — detects missing dependencies and installs them via Homebrew with one click

## Install

### One-line installer (recommended)

```bash
curl -fsSL https://raw.githubusercontent.com/mouseykins/reclip/main/install.sh | bash
```

This installs Homebrew (if needed), `yt-dlp`, `ffmpeg`, and `deno`, then drops the latest `Reclip.app` into `/Applications` and launches it.

### Manual install

1. Install [Homebrew](https://brew.sh) if you don't already have it:
   ```bash
   /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
   ```
2. Install dependencies:
   ```bash
   brew install yt-dlp ffmpeg deno
   ```
3. Download the latest `Reclip.zip` from the [releases page](https://github.com/mouseykins/reclip/releases), unzip, and drag `Reclip.app` into `/Applications`.
4. On first launch, if macOS says "Reclip can't be opened because Apple cannot check it for malicious software", right-click the app and choose **Open**, or run:
   ```bash
   xattr -dr com.apple.quarantine /Applications/Reclip.app
   ```

## Requirements

- macOS 14 (Sonoma) or newer
- Apple Silicon or Intel
- About 200 MB for dependencies (yt-dlp + ffmpeg + deno)

## Dependencies

| Tool     | Why it's needed                                                          |
|----------|--------------------------------------------------------------------------|
| yt-dlp   | Extracts videos from YouTube, TikTok, Vimeo, and hundreds of other sites |
| ffmpeg   | Merges separate video+audio streams and repackages clips for QuickTime   |
| deno     | JavaScript runtime that yt-dlp uses to decode modern YouTube signatures  |

All three are Homebrew packages; the app will offer to install them on first launch if they're missing.

## Usage

1. Paste a video URL into the top field and click **Fetch**.
2. Watch the low-res preview that loads in the embedded player.
3. Optionally drag the clip selection handles to pick a start/end. The video seeks to whichever handle you're dragging.
4. Pick a **Quality** from the dropdown (appears when metadata loads) and choose **MP4** or **MP3** format.
5. Click **Download Full** for the complete video, or **Download Clip** for just your selection.
6. Files land in `~/Movies/Reclip/` by default — click **Change…** at the bottom to pick somewhere else.

The console at the bottom of the window shows every `yt-dlp` / `ffmpeg` command as it runs, plus any warnings or errors, with a copy button so you can share logs when reporting issues.

## Build from source

You'll need Xcode 15+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```bash
brew install xcodegen
git clone https://github.com/mouseykins/reclip.git
cd reclip
xcodegen generate
open Reclip.xcodeproj
```

Or build and install from the command line:

```bash
xcodebuild -project Reclip.xcodeproj -scheme Reclip -configuration Release build
cp -R ~/Library/Developer/Xcode/DerivedData/Reclip-*/Build/Products/Release/Reclip.app /Applications/
```

Run the unit tests with:

```bash
xcodebuild test -project Reclip.xcodeproj -scheme Reclip
```

## Project layout

```
Reclip/
├── ReclipApp.swift              # @main entry point
├── ContentView.swift            # Top-level layout
├── Models/                      # VideoItem, VideoQuality, DownloadFormat, ConsoleLog
├── Services/                    # YTDLPService, ProcessRunner, ProcessRegistry, DependencyCheck
├── ViewModels/                  # DownloadListViewModel
├── Views/                       # VideoEmbedView, RangeSliderView, ConsoleView, SetupView
└── Resources/Assets.xcassets    # App icon
ReclipTests/                     # Unit tests (process I/O, parsing, models)
```

## Why these choices?

**Native AVPlayer instead of a YouTube iframe.** The web-embed approach is clunky — you get YouTube's UI chrome inside your app and limited JavaScript control. Reclip downloads a small (~10–30 MB) 360p h264 preview to a temp directory and plays it with `AVPlayer`, which gives frame-accurate seeking (`seek(to:toleranceBefore:.zero,toleranceAfter:.zero)`) and works with any site yt-dlp supports, not just YouTube.

**Homebrew for dependency management.** macOS doesn't ship with a package manager. Bundling yt-dlp/ffmpeg binaries into the `.app` would balloon the download and leave them unupdatable. Homebrew is the de facto standard for Mac developers and keeps everything current with `brew upgrade`.

**Unsandboxed.** Reclip runs external processes (`yt-dlp`, `ffmpeg`, `brew`) and writes to user-chosen folders. The macOS App Sandbox is incompatible with both. The app is ad-hoc signed for local use.

## Credits

- [yt-dlp](https://github.com/yt-dlp/yt-dlp) — the heavy lifting
- [FFmpeg](https://ffmpeg.org/) — video processing
- [Deno](https://deno.com/) — JS runtime for yt-dlp
- Inspired by [averygan/reclip](https://github.com/averygan/reclip)

## License

MIT — see [LICENSE](LICENSE).
