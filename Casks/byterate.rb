# 安装：brew tap mhmh-X/byterate https://github.com/mhmh-X/byterate && brew install --cask byterate
# version 和 sha256 由 .github/workflows/release.yml 在每次发版时自动更新。
cask "byterate" do
  version "0.2.12"
  sha256 "e9101a9e0faaac9916298b27cf19f894e34e9b42652c3f40b3ff3cbe0216a7e4"

  url "https://github.com/mhmh-X/byterate/releases/download/v#{version}/ByteRate-#{version}.zip"
  name "ByteRate"
  desc "菜单栏查看 Claude Code 与 Codex 的小时/周剩余额度"
  homepage "https://github.com/mhmh-X/byterate"

  depends_on macos: :ventura

  app "ByteRate.app"

  # 未做 Apple 公证（ad-hoc 签名），安装后去除 quarantine 以便直接运行；
  # 介意此行为请改用源码安装（make install）
  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-dr", "com.apple.quarantine", "#{appdir}/ByteRate.app"],
                   sudo: false
  end

  zap trash: []
end
