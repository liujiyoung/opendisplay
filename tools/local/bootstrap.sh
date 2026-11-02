#!/bin/zsh
# Pin and verify the optional local Sparkle dependency; keep all downloads ignored.
set -euo pipefail
cd "$(dirname "$0")/../.."
TASK_ARCHIVE="$(pwd)/.local/downloads/Sparkle-2.8.1-SPM.zip"
TASK_SHA=995f913935fe903d50b3be5344fc52a638f56b39ef7984bf7a44244786d28638
TASK_URL=https://github.com/sparkle-project/Sparkle/releases/download/2.8.1/Sparkle-for-Swift-Package-Manager.zip
mkdir -p .local/downloads .local/dependencies
if [[ ! -f "$TASK_ARCHIVE" ]] || [[ "$(shasum -a 256 "$TASK_ARCHIVE" | cut -d ' ' -f 1)" != "$TASK_SHA" ]]; then
  curl --fail --location --retry 3 --connect-timeout 15 --continue-at - \
    --output "$TASK_ARCHIVE" "$TASK_URL"
fi
[[ "$(shasum -a 256 "$TASK_ARCHIVE" | cut -d ' ' -f 1)" == "$TASK_SHA" ]] || {
  echo 'Sparkle checksum mismatch; remove the cached ZIP and retry.'
  exit 1
}
# ditto preserves framework symlinks, executable modes and macOS bundle structure.
/usr/bin/ditto -x -k "$TASK_ARCHIVE" .local/dependencies
echo 'Verified Sparkle 2.8.1 is ready in .local/dependencies/Sparkle.xcframework'
