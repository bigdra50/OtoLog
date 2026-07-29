# 自前 tap（bigdra50/homebrew-tap）に置く Cask 定義のテンプレート。
# リリースごとに version と sha256 を更新する（sha256 は Release の本文に出力される）。
cask "otolog" do
  version "0.1.0"
  sha256 "REPLACE_WITH_RELEASE_ZIP_SHA256"

  url "https://github.com/bigdra50/OtoLog/releases/download/v#{version}/OtoLog.zip"
  name "OtoLog"
  desc "Mac のシステム音声をリアルタイム文字起こしするメニューバーアプリ"
  homepage "https://github.com/bigdra50/OtoLog"

  depends_on macos: ">= :tahoe" # macOS 26 以降（SpeechAnalyzer 必須）

  app "OtoLog.app"

  # ad-hoc 署名・未公証のため、Homebrew が付与する quarantine 属性を外す。
  # 付いたままだと Gatekeeper が起動を拒む（`--no-quarantine` を付けなくても済むようにする）。
  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-dr", "com.apple.quarantine", "#{appdir}/OtoLog.app"]
  end
end
