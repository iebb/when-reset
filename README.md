# When Reset

A small SwiftUI iOS monitor for ChatGPT/Codex usage limits and banked resets.

## Features

- Multiple accounts with a provider-ready account model
- Codex-compatible ChatGPT device linking
- Claude Code-compatible PKCE OAuth linking with refresh-token rotation
- Duration-classified 5-hour and weekly usage windows with live countdowns
- Nearest banked reset expiry with a day-aware countdown and exact local time
- Home Screen, Lock Screen, Dynamic Island, and Live Activity views
- Tokens in Keychain; sanitized snapshots in an App Group

## Build

1. Run `xcodegen generate`.
2. Open `WhenReset.xcodeproj`.
3. Select your development team for the app and widget targets.
4. The app uses `ad.neko.when`, its widget extension, and the `group.ad.neko.when` App Group.
5. Build on an iOS 17+ device or simulator.

Keep code signing enabled when testing account linking in Simulator. An unsigned build
(`CODE_SIGNING_ALLOWED=NO`) cannot access Keychain and fails with OSStatus `-34018` after
OAuth succeeds.

The app reads `GET /backend-api/wham/usage` and `GET /backend-api/wham/rate-limit-reset-credits`. These are private ChatGPT backend endpoints and may change without notice.

The OpenAI Blossom is used only to identify the ChatGPT provider. OpenAI, ChatGPT, and the Blossom are trademarks of OpenAI; this project is not endorsed by or affiliated with OpenAI.
