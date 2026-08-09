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
- Synthetic rolling 5-hour and weekly quota monitoring
- Ollama Cloud session and weekly quota monitoring from an on-device browser session
- Warp monthly request-credit monitoring
- Experimental Antigravity OAuth quota monitoring for Gemini, Claude, and GPT pools
- A generic on-device HTTPS usage adapter, including Sub2API-style `/v1/usage` responses
- Provider marks in the app, widgets, and Live Activity
- Duration-classified 5-hour and weekly usage windows with live countdowns
- Nearest banked reset expiry with a day-aware countdown and exact local time
- Home Screen, Lock Screen, Dynamic Island, and Live Activity views
- Accounts and tokens synchronized through iCloud Keychain; sanitized snapshots in an App Group
- Optional encrypted server-side quota monitoring and hourly silent refresh hints through a self-hosted Cloudflare Worker
- Per-quota usage charts for the last 24 hours, 7 days, or 30 days

## Build

1. Run `xcodegen generate`.
2. Open `WhenReset.xcodeproj`.
3. Select your development team for the app and widget targets.
4. The app uses `ad.neko.when`, its widget extension, and the `group.ad.neko.when` App Group.
5. Enable Push Notifications for the app identifier and regenerate the development and App Store provisioning profiles.
6. Build on an iOS 17+ device or simulator.

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
- Synthetic and Warp use user-provided API keys with fixed quota endpoints. Both can opt in to self-hosted Worker monitoring.
- Ollama Cloud currently exposes quota windows on its signed-in settings page, not through its API-key endpoints. Its session cookie therefore remains on-device.
- Antigravity uses Google OAuth and internal Cloud Code Assist quota endpoints. The mobile callback is completed by pasting the localhost URL, and its tokens remain on-device because the protocol is experimental.
- Compatible API accounts issue only `GET` requests to the exact user-entered HTTPS endpoint (or loopback HTTP), send a bearer key, cap responses at 1 MiB, and require explicit percentages or counters plus future reset timestamps. Their URL and key remain on-device.

When Reset intentionally tracks recurring coding-plan allowances, not general pay-as-you-go API balances. The private and first-party-compatible integrations may change without notice. No provider token is written to app snapshots, logs, or user defaults.

The OpenAI Blossom is used only to identify the ChatGPT provider. OpenAI, ChatGPT, and the Blossom are trademarks of OpenAI; this project is not endorsed by or affiliated with OpenAI.

## Push refresh server

The optional [Cloudflare Worker](server/README.md) is self-hosted in the user’s Cloudflare account. It sends hourly silent refresh hints and can, only for accounts individually opted in by the user, encrypt provider credentials in D1 and record quota every 5 minutes or longer. The app merges those server samples into its 24-hour, 7-day, and 30-day usage charts. Credential upload is write-only through the Worker API, and overlapping client accounts are fetched once per credential scope and cron occurrence. When Reset does not operate an official server.

[![Deploy to Cloudflare](https://deploy.workers.cloudflare.com/button)](https://deploy.workers.cloudflare.com/?url=https://github.com/iebb/when-reset/tree/master/server)
