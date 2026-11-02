#!/bin/zsh
# Reproducible local build using the verified official Sparkle binary.
set -euo pipefail
cd "$(dirname "$0")/../.."
[[ ! -f .env ]] || { set -a; source .env; set +a; }
XCODEGEN_BIN="$(pwd)/.local/tools/xcodegen/2.46.0/bin/xcodegen"
if [[ ! -x "$XCODEGEN_BIN" ]]; then
  XCODEGEN_BIN="$(command -v xcodegen || true)"
fi
[[ -n "$XCODEGEN_BIN" ]] || { echo 'Install XcodeGen first: brew install xcodegen'; exit 1; }
mkdir -p .local
"$XCODEGEN_BIN" dump --type json --file .local/project-spec.json
python3 tools/local/project.py
"$XCODEGEN_BIN" generate --spec .local/project-local.json --project-root . --project .
case "${1:-mac}" in
  mac)
    [[ -d .local/dependencies/Sparkle.xcframework ]] || { echo 'Run tools/local/bootstrap.sh to download and verify Sparkle'; exit 1; }
    xcodebuild -project OpenSidecar.xcodeproj -scheme OpenSidecarMac \
      -configuration Debug -destination 'platform=macOS' -derivedDataPath build \
      CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO build
    ;;
  ios)
    xcodebuild -project OpenSidecar.xcodeproj -scheme OpenSidecariOS \
      -configuration Debug -destination 'generic/platform=iOS' -derivedDataPath build/ios \
      CODE_SIGNING_ALLOWED=NO build
    ;;
  ios-signed)
    xcodebuild -project OpenSidecar.xcodeproj -scheme OpenSidecariOS \
      -configuration Debug -destination 'generic/platform=iOS' -derivedDataPath build/ios-signed \
      -allowProvisioningUpdates build
    ;;
  test)
    xcodebuild -project OpenSidecar.xcodeproj -scheme LocalTests \
      -destination 'platform=macOS' -derivedDataPath build/tests CODE_SIGNING_ALLOWED=NO test
    ;;
  ios-test)
    xcodebuild -project OpenSidecar.xcodeproj -scheme LocaliOSLayoutTests \
      -destination 'platform=iOS Simulator,name=iPad Air 11-inch (M3)' \
      -derivedDataPath build/ios-tests CODE_SIGNING_ALLOWED=NO test
    ;;
  *) echo 'Usage: tools/local/build.sh mac|ios|ios-signed|test|ios-test'; exit 2 ;;
esac
