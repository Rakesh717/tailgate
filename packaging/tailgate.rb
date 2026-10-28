# Homebrew cask template. Copy into your tap (homebrew-<tap>/Casks/tailgate.rb),
# fill in <OWNER> and the sha256 from dist/SHA256SUMS (the .zip line).
cask "tailgate" do
  version "1.0.0"
  sha256 "REPLACE_WITH_ZIP_SHA256"

  url "https://github.com/<OWNER>/tailgate/releases/download/v#{version}/Tailgate-#{version}.zip"
  name "Tailgate"
  desc "Menu bar app: keep the Mac awake with the lid closed and share T3 Code over Tailscale"
  homepage "https://github.com/<OWNER>/tailgate"

  depends_on macos: ">= :ventura"

  app "Tailgate.app"

  zap trash: [
    "~/Library/LaunchAgents/com.rakesh717.tailgate.plist",
  ]
end
