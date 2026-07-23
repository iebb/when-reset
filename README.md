# When Reset

A small SwiftUI iOS monitor for AI coding usage limits and reset times.

## Features

- Multiple accounts with a provider-ready account model
- Codex-compatible ChatGPT device linking
- Claude Code-compatible PKCE OAuth linking with refresh-token rotation
- Kimi Code device linking with 5-hour and weekly limits
- GitHub Copilot device linking with chat and premium-request quotas
- Z.AI GLM Coding Plan quota monitoring with 5-hour, weekly, and monthly limits
- MiniMax Token Plan quota monitoring with 5-hour and weekly limits
- Provider marks in the app, widgets, and Live Activity
- Duration-classified 5-hour and weekly usage windows with live countdowns
- Nearest banked reset expiry with a day-aware countdown and exact local time
- Home Screen, Lock Screen, Dynamic Island, and Live Activity views
- Accounts and tokens synchronized through iCloud Keychain; sanitized snapshots in an App Group

## Build

1. Run `xcodegen generate`.
2. Open `WhenReset.xcodeproj`.
3. Select your development team for the app and widget targets.
4. The app uses `ad.neko.when`, its widget extension, and the `group.ad.neko.when` App Group.
5. Build on an iOS 17+ device or simulator.

Keep code signing enabled when testing account linking in Simulator. An unsigned build
(`CODE_SIGNING_ALLOWED=NO`) cannot access Keychain and fails with OSStatus `-34018` after
OAuth succeeds.

## Provider notes

- ChatGPT reads private `wham` usage and banked-reset endpoints.
- Claude uses the Claude Code OAuth client and usage endpoint.
- Kimi uses the public client embedded in the official Kimi Code client. Moonshot does not currently publish a third-party client-registration process.
- GitHub Copilot uses GitHub device authorization, but exact remaining quotas come from the undocumented `copilot_internal/user` endpoint. Its bundled VS Code client ID should be replaced with a separately registered client before distribution.
- Z.AI uses a user-provided GLM Coding Plan key to read the same quota data shown by Usage Statistics. The quota endpoint is not documented as a public API; general-purpose and pay-as-you-go keys are outside this app’s scope.
- MiniMax uses a user-provided Subscription Key and its documented Token Plan remaining-quota endpoint. When Reset tries the global service first, then the mainland-China service for regional keys. Standard pay-as-you-go keys are outside this app’s scope.

When Reset intentionally tracks recurring coding-plan allowances, not general pay-as-you-go API balances. The private and first-party-compatible integrations may change without notice. No provider token is written to app snapshots, logs, or user defaults.

The OpenAI Blossom is used only to identify the ChatGPT provider. OpenAI, ChatGPT, and the Blossom are trademarks of OpenAI; this project is not endorsed by or affiliated with OpenAI.
