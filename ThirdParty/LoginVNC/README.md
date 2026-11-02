# Mac login client sources

The iPad receiver's optional Mac login screen embeds these unmodified sources:

- [noVNC-ARD](https://github.com/peetinc/noVNC-ARD), commit
  `d699293635083c9e0c30c8f9480993865653772a`, Copyright (c) 2026 Peet, Inc., MPL-2.0.
- Its [noVNC](https://github.com/novnc/noVNC) submodule, commit
  `8e1ebdffba02e651c399dacef841f8941f6ad6e4`, MPL-2.0 and the per-file licenses
  listed in `noVNC/LICENSE.txt`. The pako sources retain their original notices.

Only JavaScript runtime sources and licenses are vendored. The original apps,
network relays, tests, and media services are not installed or started.

`iOS/LoginResources/login.js` supplies the OpenDisplay integration. Rebuild its
offline bundle with `tools/local/build-login-web.sh`. The normal Xcode build uses
the checked-in bundle and needs no npm access. Full tunnel encryption must become
active before the integration enables remote input. Credentials are kept only in
the ephemeral login view; no credentials are placed in URLs or logs.
