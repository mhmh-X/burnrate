# 安装：brew tap mhmh-X/byterate https://github.com/mhmh-X/byterate && brew install --cask byterate
# version 和 sha256 由 .github/workflows/release.yml 在每次发版时自动更新。
cask "byterate" do
  version "0.2.8"
  sha256 "cdec0d44102de297b3141ddae8a5a0741fe63d90cd0a8b4c2dd1efe88f82c42c"

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
