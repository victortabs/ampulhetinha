cask "ampulhetinha" do
  version "1.1"
  sha256 "07c7077c558fcde152ce0aa550ecaed10dfa4cd2eacb01718ecc98e65beeb831"

  url "https://github.com/victortabs/ampulhetinha/releases/download/v#{version}/Ampulhetinha.zip"
  name "Ampulhetinha"
  desc "Timer de barra de menus: arraste a ampulheta para baixo para criar um timer"
  homepage "https://github.com/victortabs/ampulhetinha"

  depends_on macos: :sonoma

  app "Ampulhetinha.app"

  # Assinatura ad-hoc (sem notarização): tira a quarentena para o macOS abrir sem bloquear.
  postflight_steps do
    run "/usr/bin/xattr", args:           ["-dr", "com.apple.quarantine", "{{appdir}}/Ampulhetinha.app"],
                          writable_paths: ["{{appdir}}/Ampulhetinha.app"]
  end

  uninstall quit: "com.victortaborda.ampulhetinha"

  zap trash: [
    "~/Library/Application Support/Ampulhetinha",
    "~/Library/Preferences/com.victortaborda.ampulhetinha.plist",
  ]
end
