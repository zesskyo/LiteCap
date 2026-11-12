# LiteCap

[![Build](https://github.com/zesskyo/LiteCap/actions/workflows/build.yml/badge.svg)](https://github.com/zesskyo/LiteCap/actions/workflows/build.yml)

A lightweight recorder and streamer for Apple Silicon Macs (macOS 15+), built on Apple's hardware video encoder and Metal.

## What it does

**Scenes and sources**
- Multiple scenes. When you switch, the next scene's sources start first and the cut happens once they have a picture, so you don't get a black flash.
- Source types: Display Capture, Window Capture (as many as you want), Browser (transparent background, custom CSS, "Interact…" to log in), Image, and Camera / Capture Card.
- Live preview. Click a source to select it, drag to move it, and drag a corner to resize (hold ⇧ to ignore the aspect ratio). Edges and centers snap to the canvas and to other sources (hold ⌘ to place freely). Right-click for Fit, Stretch, Center, Reset, Lock and Hide.
- The preview can be hidden. When it's hidden and you're not live, video capture stops completely.
- Crop and exact position/size are in each source's Properties (double-click it in the Sources list).
- Window and display capture rebuild themselves automatically if macOS stops sending frames (the freeze fix from v1).

**Audio mixer**
- Audio source types: Desktop Audio, Application Audio (a single app), and any Microphone / Input (audio interfaces and capture-card audio too).
- Each source is a vertical strip with a fader (double-click for 0 dB), a stereo meter, mute, and a 🎧 monitor button.
- There are 6 tracks, and each source can go to any combination of them. Set this in the Tracks window (the sliders button in the mixer header), which works like OBS's Advanced Audio Properties.
- **Filters**: Audio Unit plugins (AUv2 and AUv3), including third-party ones and Apple's built-ins (compressor/gate, EQ, limiter, …). Each plugin opens its own editor, and its settings are saved.

**Outputs**
- Recording: MKV, MP4 or MOV with multiple audio tracks, using the hardware H.264 or H.265 encoder at a bitrate you type in.
  - MKV is crash-safe: if the app or your Mac crashes, the file is still playable up to about a second before the crash. It can be remuxed to MP4 automatically after each recording (Settings → Recording, needs `brew install ffmpeg`).
  - MOV is written in 5-second fragments, so a crash loses at most a few seconds.
  - MP4 is only readable once recording stops cleanly.
- Streaming: RTMP or RTMPS to Twitch, YouTube, Kick or any custom server.
  - Bitrate is typeable, with an optional CBR mode and an optional downscale for the stream.
  - Auto-reconnect.
  - When the connection is too slow, it drops video frames until the next keyframe, like OBS does.
- **Twitch VOD track**: a second audio track that only ends up in your VODs, sent the same way OBS sends it.
- Settings live in their own window (⌘, or the Settings button).
- The status bar shows CPU (LiteCap's share of the whole Mac), GPU (whole GPU), fps, skipped (render) frames, and while live, bitrate and dropped (network) frames.

**Power use:** with the preview hidden, only the audio mixer runs until you go live. Closing the window quits LiteCap; any recording is finished cleanly first.

### About VST plugins
macOS plugins come as **Audio Units**, and almost every VST maker also installs an AU version on Mac (FabFilter, Waves, iZotope, Valhalla, TDR, …). LiteCap hosts those. Hosting the VST3 format itself would need Steinberg's SDK and its license.

## Install

1. Download the latest `.dmg` from **[Releases](https://github.com/zesskyo/LiteCap/releases)**. Numbered releases are stable; **Latest build (main)** is rebuilt on every push.
2. Open the `.dmg` and drag **LiteCap** into **Applications**.
3. On first launch, macOS will say it can't verify the app, because it isn't signed with a paid Apple Developer ID. Open **System Settings → Privacy & Security**, scroll down, and click **Open Anyway** next to LiteCap. You only have to do this once per version.
4. Allow Screen Recording when asked (plus Microphone / Camera when you add those sources), then quit and reopen LiteCap.

> Each new unsigned build counts as a different app to macOS, so it may ask for permissions again after you update.

## Updates

LiteCap updates itself with [Sparkle](https://sparkle-project.org). It checks once a day (you can switch this off in Settings → General), and you can check any time with **LiteCap → Check for Updates…** or from the menu bar icon. It never checks or shows update prompts while you're recording or streaming.

Only numbered releases (`v*` tags) are offered as updates; the "Latest build (main)" pre-release isn't. Each update is signed with the project's private key, and the app refuses any update that isn't.

**One-time setup for maintainers.** On your Mac, from the repo folder, after building once:

```bash
./scripts/setup-sparkle-keys.sh
```

This creates the signing key in your Keychain and writes the public half to `Resources/SparklePublicKey.txt`. It saves the private half as the `SPARKLE_PRIVATE_KEY` repository secret if the `gh` CLI is logged in; otherwise it prints it for you to add by hand. Commit the public key file, and every tag from then on publishes an `appcast.xml` (the feed of available versions) alongside its `.dmg`.

> Until the app is signed with a paid Apple Developer ID, macOS may ask for Screen Recording permission again after an update.

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
| `Resources/` | App icon, entitlements, update public key |
| `scripts/` | Update key setup and appcast generation |
| `Sources/LiteCapCore/` | Platform-independent, tested on Linux against ffmpeg: RTMP client, AMF0, FLV tags (including multitrack audio), Matroska writer, audio FIFO |
| `Studio.swift` | The brain: scenes, sources, outputs, start/stop |
| `Compositor.swift` | Metal renderer for the canvas, plus the preview |
| `VideoSources.swift` | Display/window (ScreenCaptureKit), camera, image, browser (WebKit) |
| `AudioEngine.swift`, `AudioCaptures.swift`, `AudioPlugins.swift` | Mixer graph, tracks, meters, monitoring, inputs, Audio Unit hosting |
| `Encoders.swift`, `Outputs.swift` | VideoToolbox H.264/HEVC, AAC, MKV recording, RTMP streaming |
| `MainView.swift`, `MixerView.swift`, `Sheets.swift`, `SettingsView.swift` | UI |

Your scenes and settings are saved in `~/Library/Application Support/LiteCap/project.json`.
