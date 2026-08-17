Pod::Spec.new do |s|
  s.name         = "TVURSignal"
  s.version      = "1.0.0"
  s.summary      = "TVURSignal 框架"
  s.description  = <<-DESC
    包含本地的 TVURSignal 相关核心框架。
  DESC

  s.homepage     = "https://github.com/your-repo/TVURSignal"
  s.authors      = { "Your Name" => "your@email.com" }
  s.license      = { type: "MIT", file: "LICENSE.md" }

  # 平台配置
  s.platform     = :osx
  s.osx.deployment_target = "10.15"
  s.requires_arc = true

  # 源文件配置
  s.source       = { :path => "." }
  s.source_files = "Classes/**/*.{h,m}"

  # 系统框架依赖
  s.osx.frameworks = [
    "Cocoa"
  ]
end
