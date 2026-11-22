#!/bin/zsh
# Prints the Homebrew cask for a released version.
#   scripts/make-cask.sh 1.0.2 > /path/to/homebrew-tap/Casks/coreglance.rb
# The version must already be published on the GitHub Releases page.
set -e
VERSION="${1:?usage: make-cask.sh <version>}"
URL="https://github.com/amritadasbijoy/CoreGlance/releases/download/v${VERSION}/CoreGlance-${VERSION}.zip"
SHA=$(curl -fsSL "$URL" | shasum -a 256 | cut -d' ' -f1)

cat <<CASK
cask "coreglance" do
  version "${VERSION}"
  sha256 "${SHA}"

  url "https://github.com/amritadasbijoy/CoreGlance/releases/download/v#{version}/CoreGlance-#{version}.zip"
  name "CoreGlance"
  desc "Lightweight menu bar system monitor"
  homepage "https://github.com/amritadasbijoy/CoreGlance"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on arch: :arm64
  depends_on macos: :sonoma

  app "CoreGlance.app"

  zap trash: "~/Library/Preferences/io.github.amritadasbijoy.coreglance.plist"

  caveats <<~EOS
    CoreGlance is not notarized by Apple, so macOS blocks it the first time.
    Open System Settings > Privacy & Security and click "Open Anyway".
  EOS
end
CASK
