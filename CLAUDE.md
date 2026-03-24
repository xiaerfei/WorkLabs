# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

WorkLabs is a macOS application for video and audio capture/playback, with streaming capabilities using FFmpeg. The app captures from system cameras and microphones, decodes media files via FFmpeg, provides a live preview, and includes device management.

- **Platform**: macOS 15.2+
- **Language**: Objective‑C (ARC)
- **Dependency Manager**: CocoaPods
- **Workspace**: `WorkLabs.xcworkspace` (always use this, not the `.xcodeproj`)

## Build & Run

```bash
# Install dependencies (run after cloning or modifying Podfile)
pod install

# Build (Debug)
xcodebuild -workspace WorkLabs.xcworkspace -scheme WorkLabs -configuration Debug

# Build (Release)
xcodebuild -workspace WorkLabs.xcworkspace -scheme WorkLabs -configuration Release
```

No unit tests exist yet. The app logs device lists and event notifications to the console for debugging.

## Code Style

- Masonry for Auto Layout (programmatic constraints, not Interface Builder).
- Reactive patterns via ReactiveObjC and the custom `TVURSignal` local pod.
- Decoupled communication via the `WLEvent` event‑bus (`WLObserve()` / `WLSend()` macros).
- Comments in the codebase are primarily in Chinese.

## Architecture

### Data Flow: Two Video Pipelines

**1. Live Camera Capture** (`Video/`)
- `WLVideoManager` wraps `AVCaptureSession`; delivers `CMSampleBufferRef` to objects conforming to `WLCameraCaptureSubscriber`.
- `TVUVideoManager` is an alternative camera manager (TVUNetworks SDK); uses `TVUCameraManagerDelegate`.
- `WLDevicesManager` enumerates `AVCaptureDevice` instances.
- Frames are rendered via `WLViedoPreview` (note the typo is intentional in the codebase) which uses `AVSampleBufferDisplayLayer`.

**2. FFmpeg Media Playback** (`MediaSource/`)
- `WLMediaSource` is the main orchestrator: opens a file with `AVFormatContext`, finds best video/audio streams, sets up codec contexts (with VideoToolbox hardware acceleration when available), and spawns dedicated threads.
- Threading model (all `NSThread`):
  - **Parse thread** — reads packets via `av_read_frame`, routes to video/audio packet queues.
  - **Video decode thread** — pulls from video packet queue, decodes, pushes to video frame queue.
  - **Audio decode thread** — pulls from audio packet queue, decodes, pushes to audio frame queue.
  - **Video render thread** — pulls decoded frames for display.
  - **Audio render thread** — pulls decoded frames for audio output.
- `WLNodeQueue` — thread‑safe queue (with blocking dequeue support) connecting producers to consumers.
- `WLDecodeNode` — wraps an `AVPacket` or `AVFrame` as a linked‑list node; `flush` frees the underlying FFmpeg data.
- `WLResample` — stub for future audio resampling via `libswresample`.

### Event System

`WLEvent` is a lightweight event bus. Event types are defined as `WLObserve` enum values in `WLEventConst.h`. Usage pattern:

```objc
// Observe
WLObserve(@[@(WLObserveVideoDeviceChange)])
    .mainQueue()
    .dispose(self.bag)
    .block(^(WLObserve type, id payload) { ... });

// Send
WLSend().send(@(WLObserveVideoDeviceChange)).payload(data);
```

### Dependencies

- **ReactiveObjC** — reactive programming
- **Masonry** — Auto Layout DSL
- **ffmpeg‑kit‑local** — local pod in `LocalPodspecs/ffmpeg‑kit‑macos‑full/` providing FFmpeg frameworks (libavformat, libavcodec, libswscale, libswresample, etc.)
- **TVURSignal** — local pod in `LocalPodspecs/TVURSignal/`, a reactive signal library

### Key Stubs / Incomplete Areas

- `TVUAudioManager` — empty stub, needs implementation for live audio capture.
- `WLResample` — empty stub for audio resampling.
- `WLMediaSource.stop` — not yet implemented; currently only `doExit` cleans up resources.
- Video/audio render threads in `WLMediaSource` extract frames but don't yet push them to display/output.
