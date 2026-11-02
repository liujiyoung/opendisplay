#!/bin/zsh
set -euo pipefail
cd "$(dirname "$0")/../.."
ESBUILD="$(pwd)/.local/tools/login-web/node_modules/.bin/esbuild"
if [[ ! -x "$ESBUILD" ]]; then
  echo 'Install the pinned bundler: npm install --prefix .local/tools/login-web --no-audit --no-fund esbuild@0.25.12'
  exit 1
fi
node tools/local/bundle-login-web.mjs
