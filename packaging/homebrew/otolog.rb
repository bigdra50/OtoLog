# Template for the Cask that lives in the bigdra50/homebrew-tap repo.
# Update version and sha256 on each release (the sha256 is printed in the Release body).
cask "otolog" do
  version "0.1.0"
  sha256 "REPLACE_WITH_RELEASE_ZIP_SHA256"

  url "https://github.com/bigdra50/OtoLog/releases/download/v#{version}/OtoLog.zip"
  name "OtoLog"
  desc "Menu bar app that transcribes Mac system audio in real time"
  homepage "https://github.com/bigdra50/OtoLog"

  depends_on macos: :tahoe # macOS 26+ (SpeechAnalyzer)

  app "OtoLog.app"

  # ad-hoc signed and not notarized: strip the quarantine attribute Homebrew adds
  # so Gatekeeper does not block the first launch.
  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-dr", "com.apple.quarantine", "#{appdir}/OtoLog.app"]
  end
end
