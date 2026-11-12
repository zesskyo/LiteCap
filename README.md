# LiteCap

[![Build](https://github.com/zesskyo/LiteCap/actions/workflows/build.yml/badge.svg)](https://github.com/zesskyo/LiteCap/actions/workflows/build.yml)

A lightweight recorder and streamer for Apple Silicon Macs (macOS 15+), built on Apple's hardware video encoder and Metal.

## What it does

**Scenes and sources**
- Multiple scenes. When you switch, the next scene's sources start first and the cut happens once they have a picture, so you don't get a black flash.
- Source types: Display Capture, Window Capture (as many as you want), Browser (transparent background, custom CSS, "Interact…" to log in), Image, and Camera / Capture Card.
- Live preview. Click a source to select it, drag to move it, and drag a corner to resize (hold ⇧ to ignore the aspect ratio). Edges snap. Right-click for Fit, Stretch, Center, Reset, Lock and Hide.
- Crop and exact position/size are in each source's Properties (double-click it in the Sources list).
- Window and display capture rebuild themselves automatically if macOS stops sending frames (the freeze fix from v1).

**Audio mixer**
- Audio source types: Desktop Audio, Application Audio (a single app), and any Microphone / Input (audio interfaces and capture-card audio too).
- Each source has a volume fader, a stereo meter, mute, and a 🎧 monitor button.
- There are 6 tracks, and each source can go to any combination of them (⚙︎ ▸ Tracks).
- **Listen**: pick a track at the top of the mixer to hear exactly that mix on your headphones.
- **Filters**: Audio Unit plugins (AUv2 and AUv3), including third-party ones and Apple's built-ins (compressor/gate, EQ, limiter, …). Each plugin opens its own editor, and its settings are saved.

**Outputs**
- Recording: MKV with multiple audio tracks, encoded by the hardware H.264 or HEVC encoder at a bitrate you type in. MKV is crash-safe: if the app or your Mac crashes, the file is still playable up to about a second before the crash. "Remux Last to MP4" converts the file for editors that don't open MKV (needs `brew install ffmpeg`).
- Streaming: RTMP or RTMPS to Twitch, YouTube, Kick or any custom server.
  - Bitrate is typeable, with an optional CBR mode and an optional downscale for the stream.
  - Auto-reconnect.
  - When the connection is too slow, it drops video frames until the next keyframe, like OBS does.
- **Twitch VOD track**: a second audio track that only ends up in your VODs, sent the same way OBS sends it.
- Settings live in their own window (⌘, or the Settings button).
- Global hotkeys: ⌃⌥⌘R record, ⌃⌥⌘S stream. There's also a menu bar icon with scene switching.

**Power use:** when the main window is closed and you're not live, nothing runs.

### About VST plugins
macOS plugins come as **Audio Units**, and almost every VST maker also installs an AU version on Mac (FabFilter, Waves, iZotope, Valhalla, TDR, …). LiteCap hosts those. Hosting the VST3 format itself would need Steinberg's SDK and its license.

## Install

1. Download the latest `.dmg` from **[Releases](https://github.com/zesskyo/LiteCap/releases)**. Numbered releases are stable; **Latest build (main)** is rebuilt on every push.
2. Open the `.dmg` and drag **LiteCap** into **Applications**.
3. On first launch, macOS will say it can't verify the app, because it isn't signed with a paid Apple Developer ID. Open **System Settings → Privacy & Security**, scroll down, and click **Open Anyway** next to LiteCap. You only have to do this once per version.
4. Allow Screen Recording when asked (plus Microphone / Camera when you add those sources), then quit and reopen LiteCap.

> Each new unsigned build counts as a different app to macOS, so it may ask for permissions again after you update.

## Build it yourself

You need Xcode 16 or newer, or its Command Line Tools.

```bash
./build-app.sh --open        # build and launch
./build-app.sh --dmg         # also make build/LiteCap-<version>.dmg
swift test                   # core tests (MKV/RTMP tests need ffmpeg: brew install ffmpeg)
```

## Releases and CI

Every push to `main` builds the app on a GitHub macOS runner, runs the tests, and updates the **Latest build (main)** pre-release.

To publish a numbered release:

```bash
git tag v0.3.0
git push origin v0.3.0
```

**Optional: signed and notarized builds.** These need a paid Apple Developer account. Add these repository secrets: `MACOS_CERT_P12` (a base64 Developer ID Application certificate), `MACOS_CERT_PASSWORD`, `NOTARY_APPLE_ID`, `NOTARY_TEAM_ID`, and `NOTARY_PASSWORD` (an app-specific password). Builds then open without the "Open Anyway" step and keep their permissions across updates.

## Code map

| Path | What it does |
|---|---|
| `Tests/LiteCapCoreTests/` | Unit and integration tests for the core (run on Linux and macOS in CI) |
| `Resources/` | App icon and entitlements |
| `Sources/LiteCapCore/` | Platform-independent, tested on Linux against ffmpeg: RTMP client, AMF0, FLV tags (including multitrack audio), Matroska writer, audio FIFO |
| `Studio.swift` | The brain: scenes, sources, outputs, start/stop |
| `Compositor.swift` | Metal renderer for the canvas, plus the preview |
| `VideoSources.swift` | Display/window (ScreenCaptureKit), camera, image, browser (WebKit) |
| `AudioEngine.swift`, `AudioCaptures.swift`, `AudioPlugins.swift` | Mixer graph, tracks, meters, monitoring, inputs, Audio Unit hosting |
| `Encoders.swift`, `Outputs.swift` | VideoToolbox H.264/HEVC, AAC, MKV recording, RTMP streaming |
| `MainView.swift`, `MixerView.swift`, `Sheets.swift`, `SettingsView.swift` | UI |

Your scenes and settings are saved in `~/Library/Application Support/LiteCap/project.json`.
