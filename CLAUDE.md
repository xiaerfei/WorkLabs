# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

WorkLabs is a macOS, OBS‑like multi‑source compositor. It takes live camera and FFmpeg‑decoded media‑file sources, composites them onto a configurable canvas (drag / resize / z‑order, WYSIWYG), shows a live preview, plays audio, and records the composite to an mp4 via FFmpeg.

- **Platform**: macOS 15.2+
- **Language**: Objective‑C (ARC)
- **Dependency Manager**: CocoaPods
- **Project Generator**: XcodeGen (`project.yml` → `.xcodeproj`)
- **Workspace**: `WorkLabs.xcworkspace` (always use this, not the `.xcodeproj`)

Implemented: camera capture, media‑file decode (hardware VideoToolbox), canvas compositing, live preview, single‑channel audio playback, mp4 recording (video only), canvas‑resolution presets.
Planned / not yet wired: microphone capture + multi‑track audio mixing, recording with audio (AAC), RTMP push, filter UI (mirror / crop), network pull sources.

## Project Generation (XcodeGen)

The `.xcodeproj` is generated from `project.yml` — **do not hand‑edit the project file**. After adding, removing, or moving source files you MUST regenerate, then reinstall pods (which re‑integrates the workspace):

```bash
xcodegen generate && pod install
```

`sources: WorkLabs` in `project.yml` means the entire `WorkLabs/` directory tree is compiled — any `.h/.m/.mm/.metal` placed under it is picked up automatically on regeneration. `#import "X.h"` uses **bare filenames** resolved via Xcode's headermap, so source files can be moved between folders without editing any imports.

## Build & Run

```bash
# Install dependencies (run after cloning, editing the Podfile, or `xcodegen generate`)
pod install

# Build (Debug)
xcodebuild -workspace WorkLabs.xcworkspace -scheme WorkLabs -configuration Debug

# Build (Release)
xcodebuild -workspace WorkLabs.xcworkspace -scheme WorkLabs -configuration Release
```

No unit tests exist yet. The app logs to the console for debugging.

## Code Style

- Masonry for Auto Layout (programmatic constraints, not Interface Builder).
- ReactiveObjC for a few reactive flows (title‑bar show/hide in `WLMainWindowController`, device‑change observation in `WLDevicesManager`).
- Protocol + delegate / output‑block based decoupling between pipeline stages (see `Common/*Protocol.h`).
- Comments in the codebase are primarily in Chinese.

## Architecture

### Directory layout (by pipeline responsibility)

```
WorkLabs/
├─ App/      Entry + main window (main · AppDelegate · WLMainWindow/ViewController)
├─ Core/     Orchestration + canvas model (WLStreamsManager · WLCanvasModel)
├─ Source/   Input sources (WLSourceProtocol)
│  ├─ Camera/    WLCameraSource(+Config) · WLDevicesManager
│  └─ MediaFile/ WLMediaSource · WLMediaSourcePreview · WLMetalPreviewShaders.metal
├─ Mix/      Compositing (WLVideoMix)
├─ Output/   Outputs (WLRecorder mp4 · WLAudioRenderer playback)
├─ UI/       Canvas UI (WLStreamViewController · WLStreamPreview)
├─ Common/   Macros / queue primitives / protocols (WLDefines · WLNode(Queue) · ×4 Protocol)
└─ Utils/    Categories (NSArray+Function · NSWindow+WLExtend)
```

Storyboard entry: `Main.storyboard` → `WLMainWindowController` + `WLMainViewController`; the latter embeds `WLStreamViewController` (the actual canvas UI). The entire app's compositing pipeline lives behind that controller.

### Data flow

```
Source ──► WLStreamsManager ──► perStreamFilter ──┬─► WLStreamPreview   (per‑source live preview, AVSampleBufferDisplayLayer)
(Camera /                                          └─► WLVideoMix        (composite all sources onto canvas)
 MediaFile)                                                  │
                                                             ▼
                                            mixedFrameOutput(pixelBuffer, pts)
                                                             │
                                                             ▼
                                                       WLRecorder (mp4)
```

- **`WLStreamsManager`** (`Core/`) — the orchestrator. Registers sources, forks each source's frames to (a) its per‑source preview and (b) `WLVideoMix`. Owns z‑order, layout, background, canvas‑size operations, and the `WLAudioRenderer`. All background/layout/z‑order state is delegated to `WLCanvasModel`.
- **`WLCanvasModel`** (`Core/`) — single source of truth for canvas size, background (color/image), per‑stream layout rects (canvas pixel coords), and `streamOrder` (bottom→top). Shared by both the UI and `WLVideoMix` so preview, composite, and recording stay consistent.
- **`WLVideoMix`** (`Mix/`) — Core Image compositor. Composites background + all streams (by `streamOrder`) into a pooled `CVPixelBuffer`. Renders with an explicit **sRGB** output color space (rendering with `nil`/linear darkened the recording). Exposes `output(pixelBuffer, pts)`.
- **`WLStreamPreview`** (`UI/`) — an `AVSampleBufferDisplayLayer`‑backed overlay view: drag to move, 8‑handle aspect‑locked resize, selection (red border + handles), right‑click menu (z‑order + deselect). Reports geometry back via `WLStreamRenderingDelegate`; the controller converts view rects ↔ canvas pixel rects.
- **`WLRecorder`** (`Output/`) — FFmpeg mp4 muxer + `h264_videotoolbox` encoder + `swscale` (BGRA→NV12), VFR timestamps from real pts. Because VideoToolbox extradata (SPS/PPS) is only available after the first encoded frame, `avformat_write_header` is **delayed to the first packet**. Color declared BT.709 limited range.
- **`WLAudioRenderer`** (`Output/`) — AudioQueue player; configures the queue from the first sample buffer's `formatDescription` (dynamic sample rate / channels / format).

### FFmpeg media playback (`Source/MediaFile/WLMediaSource`)

`WLMediaSource` opens a file with `AVFormatContext`, finds best video/audio streams, sets up codec contexts (VideoToolbox HW accel when available), and spawns five `NSThread`s:

- **Parse thread** — `av_read_frame`, routes packets to video/audio packet queues.
- **Video / Audio decode threads** — pull packets, decode, push frames to frame queues.
- **Video / Audio render threads** — pull decoded frames, throttle by `baseTime + pts`, and output (video → pixel buffer to the pipeline; audio → sample buffer to `WLAudioRenderer`).

Supporting types in `Common/`:
- **`WLNodeQueue`** — thread‑safe queue (blocking dequeue) connecting producers to consumers.
- **`WLNode`** — wraps an `AVPacket` / `AVFrame` / `CVPixelBufferRef` / `CMSampleBufferRef` as a linked‑list node; `flush` frees the underlying data.

`WLMediaSourcePreview` (`Source/MediaFile/`) is a Metal‑backed preview view (uses `WLMetalPreviewShaders.metal`, loaded by shader **function name** via `newDefaultLibrary` — not via `#import`). It is currently instantiated by `WLMediaSource` but the canvas UI does not consume it (the pipeline previews via `WLStreamPreview`); a candidate for future simplification.

### Dependencies

- **ReactiveObjC** — reactive programming (limited use, see Code Style).
- **Masonry** — Auto Layout DSL.
- **ffmpeg‑kit‑local** — local pod in `LocalPodspecs/ffmpeg‑kit‑macos‑full/` providing FFmpeg frameworks (libavformat, libavcodec, libswscale, libswresample, …). LGPL build: VideoToolbox encoders (`h264_videotoolbox` / `hevc_videotoolbox`) and `aac_at` are available; there is **no** libx264. Use quoted includes (`#include "libavformat/avformat.h"`); the header search path is pre‑configured.
- **TPCircularBuffer** — lock‑free ring buffer.
- **TVURSignal** — local pod in `LocalPodspecs/TVURSignal/`; **currently unused by the code** (still listed in the Podfile).

### Key stubs / incomplete areas

- Microphone capture + multi‑track audio mixing — not implemented (audio is single‑channel media playback only).
- Recording with audio (AAC `aac_at` + a/v sync mux) — `WLRecorder` is video‑only.
- RTMP push, network pull sources, filter UI (mirror/crop) — planned; `WLStreamFilterProtocol` + `WLStreamsManager.setFilter:` exist but no concrete filter is wired in yet.
