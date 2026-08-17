Pod::Spec.new do |s|
  s.name         = "ffmpeg-kit-local"
  s.version      = "1.0.0"
  s.summary      = "本地集成的 FFmpeg Kit 框架"
  s.description  = <<-DESC
    包含本地的 ffmpegkit 及相关 FFmpeg 核心框架，用于音视频处理。
  DESC

  s.homepage     = "https://github.com/your-repo/ffmpeg-kit-local"
  s.authors      = { "Your Name" => "your@email.com" }
  # s.license      = { :type => "LGPL-3.0", :file => "LICENSE" }  # 保持与官方一致的许可证

  # 平台配置（根据实际需求选择 macOS 或 iOS）
  s.platform     = :osx
  s.osx.deployment_target = "10.15"
  s.requires_arc = true

  # 依赖的系统库
  s.libraries    = "z", "bz2", "c++", "iconv"

  # 关键修复：添加 source 字段（本地路径）
  s.source       = { :path => "." }  # 表示与 podspec 同目录

  # 本地 frameworks 路径
  s.vendored_frameworks = [
    "ffmpegkit.xcframework",
    "libavcodec.xcframework",
    "libavdevice.xcframework",
    "libavfilter.xcframework",
    "libavformat.xcframework",
    "libavutil.xcframework",
    "libswresample.xcframework",
    "libswscale.xcframework"
  ]

  # 系统框架依赖
  s.osx.frameworks = [
    "AudioToolbox",
    "CoreAudio",
    "CoreMedia",
    "VideoToolbox",
    "OpenGL"
  ]
end