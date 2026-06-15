# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

WorkLabs is a macOS, OBS‑like multi‑source compositor. It takes live camera, FFmpeg‑decoded media‑file, and microphone sources, composites the video onto a configurable canvas (drag / resize / z‑order, WYSIWYG) with optional per‑source filters, mixes multi‑track audio, shows a live preview, and encodes the result once to feed both mp4 recording and RTMP streaming via FFmpeg.

- **Platform**: macOS 15.2+
- **Language**: Objective‑C (ARC)
- **Dependency Manager**: CocoaPods
- **Project Generator**: XcodeGen (`project.yml` → `.xcodeproj`)
- **Workspace**: `WorkLabs.xcworkspace` (always use this, not the `.xcodeproj`)

Implemented: camera capture, media‑file decode (hardware VideoToolbox), microphone capture, Metal canvas compositing (tick‑driven), live preview, multi‑track audio mixing + playback, per‑source video filters (mirror / color correction / crop), seek / loop for media sources, mp4 recording **with audio** (AAC), RTMP streaming, a shared encoder (encode once → fan out to recorder + pusher), configurable encode params, canvas‑resolution presets, and an independent settings window.
Planned / not yet wired: network pull sources (RTMP/RTSP/HLS — `WLNetWorkSource`), screen capture, runtime source switching, audio denoise / AEC (`WLAudioFilter`), advanced filters (beauty / LUT / transitions); plus low‑priority AV polish (crystal‑oscillator drift compensation) and a proper performance/stability acceptance pass — see `Doc/规划/NewPlan/TaskPlanAndCriteria.md`.

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
├─ Source/   Input sources (WLStreamSourceProtocol)
│  ├─ Camera/    WLCameraSource(+Config) · WLDevicesManager
│  ├─ MediaFile/ WLMediaSource · WLMediaSourcePreview · WLMetalPreviewShaders.metal
│  └─ Mic/       WLMicSource
├─ Filter/   Per‑source video filter (WLBasicVideoFilter — mirror / color / crop)
├─ Mix/      Metal compositor, tick‑driven (WLVideoMix)
├─ Output/   Outputs (WLEncoder shared enc · WLEncodedPacket · WLEncoderConfig · WLRecorder mp4 · WLPusher rtmp · WLAudioMixer · WLAudioRenderer playback)
├─ UI/       Canvas UI + settings (WLStreamViewController · WLStreamPreview · WLSettingsWindowController)
├─ Common/   Macros / queue primitives / protocols (WLDefines · WLNode(Queue) · Protocols)
└─ Utils/    Categories (NSArray+Function · NSWindow+WLExtend)
```

Storyboard entry: `Main.storyboard` → `WLMainWindowController` + `WLMainViewController`; the latter embeds `WLStreamViewController` (the actual canvas UI). The entire app's compositing pipeline lives behind that controller.

### Data flow

```
                                  ┌─► WLStreamPreview  (per‑source live preview, AVSampleBufferDisplayLayer)
Source ─► WLStreamsManager ─► perStreamFilter (WLBasicVideoFilter)
(Camera/MediaFile/Mic)            └─► WLVideoMix  (Metal compositor, tick‑driven, all sources onto canvas)
                                          │ mixedFrameOutput(pixelBuffer, pts)
   audio ─► WLAudioMixer ─► WLAudioRenderer (playback)
                 │ audioBufferOutput
                 ▼   ▼
              WLEncoder  (encode once: h264_videotoolbox + aac_at)
                 │ packetOutput (WLEncodedPacket, by intent flags)
           ┌─────┴─────┐
           ▼           ▼
       WLRecorder    WLPusher
       (mp4 mux)     (rtmp/flv mux)
```

- **`WLStreamsManager`** (`Core/`) — the orchestrator. Registers sources, applies the per‑source `WLBasicVideoFilter`, then forks each source's frames to (a) its per‑source preview and (b) `WLVideoMix`. Routes all source audio into `WLAudioMixer` (mixed output → `WLAudioRenderer` for playback, and re‑exposed via `audioBufferOutput`). Owns z‑order, layout, background, canvas‑size, per‑source volume and per‑source filter operations. All background/layout/z‑order state is delegated to `WLCanvasModel`.
- **`WLCanvasModel`** (`Core/`) — single source of truth for canvas size, background (color/image), per‑stream layout rects (canvas pixel coords), and `streamOrder` (bottom→top). Shared by both the UI and `WLVideoMix` so preview, composite, and recording stay consistent.
- **`WLVideoMix`** (`Mix/`) — **Metal** compositor, **tick‑driven**: a `dispatch_source` timer on its serial queue pulls frames at the composite fps (replaces input‑event‑driven compositing); each source buffers a FIFO and a virtual clock picks the frame per tick (absorbs fps mismatch, OBS `ready_async_frame` style). Composites background + all streams (by `streamOrder`) into a pooled `CVPixelBuffer` via `CVMetalTextureCache`. `renderingEnabled` gates the tick, so pure preview (no record/stream) does zero compositing. Emits CFR pts (`ptsAccum`) via `output(pixelBuffer, pts)`. (NOTE: `WLVideoMix.h` comments still say "CoreImage" — stale; the `.m` is Metal + tick.)
- **`WLStreamPreview`** (`UI/`) — an `AVSampleBufferDisplayLayer`‑backed overlay view: drag to move, 8‑handle aspect‑locked resize, selection (red border + handles), right‑click menu (z‑order + deselect). Reports geometry back via `WLStreamRenderingDelegate`; the controller converts view rects ↔ canvas pixel rects.
- **`WLEncoder`** (`Output/`) — **shared encoder**: `h264_videotoolbox` + `aac_at` + `swscale`/`swresample`, encode once and fan out the same `WLEncodedPacket`s to both muxers (halves encode cost; supports start‑record‑mid‑stream / start‑stream‑mid‑record, and record‑continues‑when‑stream‑drops). Monotonic wall‑clock timeline; video + audio share one epoch. `WLEncoderConfig` holds the tunable params (bitrate / keyframe interval / fps / audio bitrate, persisted to NSUserDefaults). `WLEncodedPacket` is an immutable µs‑timebase packet wrapper retained independently by each muxer.
- **`WLRecorder`** (`Output/`) — pure **mp4 muxer** (no longer owns an encoder): receives `WLEncodedPacket`s via `writePacket:`. Because VideoToolbox extradata (SPS/PPS) is only available after the first encoded frame, `avformat_write_header` is **delayed to the first packet**; uses the first video keyframe as the common zero point. Color declared BT.709 limited range.
- **`WLPusher`** (`Output/`) — pure **flv/rtmp muxer** (`avio_open2` rtmp, `realtime`, 2s GOP); same packet interface as `WLRecorder` but on its own serial queue, so an rtmp stall isolates to streaming and leaves recording + the encoder unaffected.
- **`WLAudioMixer`** (`Output/`) — multi‑track mixer: each source's PCM is resampled (`swresample`) to 44.1kHz/stereo/Float32 into its own `TPCircularBuffer`; a ~23ms timer pulls 1024 samples per source, sums with per‑input gain + clipping, and emits one LPCM stream (gap → silence fill to avoid drift). Drives both playback and the encoder's audio.
- **`WLAudioRenderer`** (`Output/`) — AudioQueue player; configures the queue from the first sample buffer's `formatDescription` (dynamic sample rate / channels / format).

### FFmpeg media playback (`Source/MediaFile/WLMediaSource`)

`WLMediaSource` opens a file with `AVFormatContext`, finds best video/audio streams, sets up codec contexts (VideoToolbox HW accel when available), and spawns five `NSThread`s:

- **Parse thread** — `av_read_frame`, routes packets to video/audio packet queues.
- **Video / Audio decode threads** — pull packets, decode, push frames to frame queues.
- **Video / Audio render threads** — pull decoded frames, throttle by `baseTime + pts`, and output (video → pixel buffer to the pipeline; audio → sample buffer into `WLAudioMixer`). Supports seek (epoch generation drops stale frames) and loop (timeline flattened, baseTime not re‑anchored).

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

- Network pull sources (RTMP/RTSP/HLS — `WLNetWorkSource`) and screen capture — not implemented (only Camera / MediaFile / Mic exist).
- Runtime source switching — design only (`Doc/WorkLabs设计/可切源推流时间戳设计.md`), not wired.
- Independent audio filter (`WLAudioFilter`: denoise / AEC) — not implemented; gain + resample already live inside `WLAudioMixer`, but mic monitoring without AEC can howl on speakers.
- Advanced video filters (beauty / 3D LUT / transitions) — only reference notes in `Doc/基础知识`; the live filter is `WLBasicVideoFilter` (mirror / color / crop).
- Low‑priority AV polish — crystal‑oscillator drift compensation (currently passive water‑mark fill, "observe first"); no systematic performance / memory‑leak acceptance pass yet.
