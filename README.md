# Blinky

[![Stars](https://img.shields.io/github/stars/harrisliangsu/blinky-ios)](https://github.com/harrisliangsu/blinky-ios/stargazers) [![Last commit](https://img.shields.io/github/last-commit/harrisliangsu/blinky-ios)](https://github.com/harrisliangsu/blinky-ios/commits/master) [![iOS](https://img.shields.io/badge/iOS-17%2B-black?logo=apple)](https://github.com/harrisliangsu/blinky-ios) [![SwiftUI](https://img.shields.io/badge/SwiftUI-iOS-orange?logo=swift&logoColor=white)](https://github.com/harrisliangsu/blinky-ios)

iOS 用量/重置监控（ChatGPT、Claude、Grok、Kimi、智谱等），适合在 iPhone 上查看 AI 编程额度与重置时间。

An iOS usage and reset monitor (ChatGPT, Claude, Grok, Kimi, Zhipu, and more) for people checking AI coding quotas on iPhone.

**分支：** [harrisliangsu/blinky-ios](https://github.com/harrisliangsu/blinky-ios) 是上游 [When Reset（iebb/when-reset）](https://github.com/iebb/when-reset) 的分支，不是原项目。上游没有 LICENSE；本分支保留原作者署名，并使用 Harris 自己的 Bundle ID 前缀，以便用他的 Apple Developer 团队签名。

**Fork:** [harrisliangsu/blinky-ios](https://github.com/harrisliangsu/blinky-ios) is a fork of upstream [When Reset (iebb/when-reset)](https://github.com/iebb/when-reset), not the original project. Upstream ships no LICENSE. This fork keeps the original attribution and a Harris-owned bundle-id prefix for his Apple Developer team.

[Releases](https://github.com/harrisliangsu/blinky-ios/releases) · [Mac 姊妹应用 blinky-mac](https://github.com/harrisliangsu/blinky-mac) · [支持 / Sponsor](https://afdian.com/a/sharkchiligaga)

## 当前状态

TestFlight 与 App Store 仍被挡住：Apple Developer 注册和上传所需的仓库 secrets 还没齐，今天没有 TestFlight。[Releases](https://github.com/harrisliangsu/blinky-ios/releases) 目前没有安装包。要现在运行，按 [Build](#build) 从源码构建。

TestFlight and the App Store are still blocked pending Apple Developer enrollment and repository secrets. There is no TestFlight build today, and [Releases](https://github.com/harrisliangsu/blinky-ios/releases) has no installable build yet. Build from source: [Build](#build).

## 此分支 / This fork

- **ChatGPT / Codex** 与 **Kimi Code** 保持原有设备登录与小组件。
- **智谱 GLM（Z.AI / BigModel）**：除 `https://api.z.ai` 外，增加中国大陆 `https://open.bigmodel.cn`，额度路径仍是 `/api/monitor/usage/quota/limit`。HTTP 200 也会带 `code` / `success` 信封。添加账号时可选 Automatic / Global / 中国大陆；成功的主机按账号记住，避免用错区域的 key 反复打到另一台主机。
- **Grok**：按 [Pulse](https://github.com/qunqin24/Pulse)（Apache-2.0）核对过的每周额度池。RFC 8628 设备码，scope 为 `openid email offline_access grok-cli:access`，然后 `GET https://cli-chat-proxy.grok.com/v1/billing?format=credits` 与 `/v1/settings`，请求头 `x-xai-token-auth: xai-grok-cli`。访问令牌大约 6 小时，用 refresh token 续期。
- ChatGPT, Kimi Code, 智谱 GLM, and Grok each publish quota windows that the home-screen and Lock Screen widgets, plus Live Activity, render with that provider's mark.

## Features

- Multiple accounts with a provider-ready account model
- Codex-compatible ChatGPT device linking
- Claude Code-compatible PKCE OAuth linking with refresh-token rotation
- Grok device linking for the weekly account credit pool, with refresh-token rotation
- Kimi Code device linking with 5-hour and weekly limits
- GitHub Copilot device linking with chat and premium-request quotas
- 智谱 GLM / Z.AI Coding Plan quota monitoring, including mainland BigModel (`open.bigmodel.cn`) and international `api.z.ai`
- MiniMax Token Plan quota monitoring with 5-hour and weekly limits
- Synthetic rolling 5-hour and weekly quota monitoring
- Ollama Cloud session and weekly quota monitoring from an on-device browser session
- Warp monthly request-credit monitoring
- OpenRouter per-key credit-limit and reset-period monitoring
- Fireworks AI account quota and monthly spend-limit monitoring
- DeepSeek API balance monitoring in the provider-reported currency
- Poe API point-balance monitoring
- OpenAI and Anthropic organization API spend, with optional monthly balance budgets
- New API-compatible key allowance, usage, remaining balance, and expiry
- Experimental Antigravity OAuth quota monitoring for Gemini, Claude, and GPT pools
- A generic on-device HTTPS usage adapter, including Sub2API-style `/v1/usage` responses
- Provider marks in the app, widgets, and Live Activity
- Duration-classified 5-hour and weekly usage windows with live countdowns
- Nearest banked reset expiry with a day-aware countdown and exact local time
- Home Screen widgets in selectable Market chart, Quota ring, Quota board, Gauge, and Heatmap styles, with automatic family-aware layouts
- Small, medium, and large Home Screen widgets on iOS and macOS, plus Lock Screen, Dynamic Island, and Live Activity views
- Accounts and tokens synchronized through iCloud Keychain; sanitized snapshots in an App Group
- Optional encrypted server-side quota monitoring and hourly silent refresh hints through Cloudflare Workers or your own Linux server
- Optional WebAuthn passkey access to the private dashboard, including iCloud Keychain-backed passkeys on Apple devices
- Per-quota usage charts for the last 24 hours, 7 days, or 30 days

## Build

1. Run `xcodegen generate` (or `xcodegen generate --spec project.yml`).
2. Open `WhenReset.xcodeproj`.
3. Defaults live in `Config/WhenReset.xcconfig`. Override `APP_BUNDLE_IDENTIFIER`, `WIDGET_BUNDLE_IDENTIFIER`, `APP_GROUP_IDENTIFIER`, `KEYCHAIN_GROUP_SUFFIX`, or `DEVELOPMENT_TEAM` there, in gitignored `Config/Local.xcconfig`, or on the `xcodebuild` command line.
4. The Harris defaults are `com.harrisliangsu.whenreset`, widget `com.harrisliangsu.whenreset.widgets`, and App Group `group.com.harrisliangsu.whenreset`. Upstream `ad.neko.when` belongs to the original author and is not used.
5. In the Apple Developer portal, register those identifiers, enable App Groups on both, and enable Push Notifications on the app id. Then set `DEVELOPMENT_TEAM` to Harris's Team ID.
6. Build on an iOS 17+ device or simulator.

Keep code signing enabled when testing account linking in Simulator. An unsigned build
(`CODE_SIGNING_ALLOWED=NO`) cannot access Keychain and fails with OSStatus `-34018` after
OAuth succeeds.

## Continuous integration and App Store uploads

GitHub Actions replaces Xcode Cloud for this repository:

- `CI` runs on every pull request and push to `master`. On a macOS runner it installs XcodeGen, regenerates the project, runs the iOS unit tests, and builds unsigned iOS and universal macOS release configurations. Simulator tests are ad-hoc signed on the runner so Keychain tests can run; that signature does not use an Apple team. The job does not need Apple secrets. The Worker and Linux server jobs stay on Ubuntu.
- `App Store Release` archives and uploads an iOS TestFlight build when a version tag `v*` (or `testflight-*`) is pushed, and supports a manual iOS/macOS dispatch. It uses Xcode automatic signing with an App Store Connect API key. If the secrets below are missing, that workflow stops before archiving and names the missing secrets. Pull-request CI still passes.

### TestFlight secrets and Apple-side setup

Pull-request CI does not read these. The tag workflow cannot upload until they exist as repository secrets:

| Secret | What to put in it |
| --- | --- |
| `APP_STORE_CONNECT_KEY_ID` | App Store Connect API key id (Users and Access → Integrations → App Store Connect API). Role: Admin or App Manager. |
| `APP_STORE_CONNECT_ISSUER_ID` | The issuer id shown on that same page. |
| `APP_STORE_CONNECT_PRIVATE_KEY` | The full `AuthKey_XXXX.p8` file contents, including the BEGIN/END lines. |
| `APPLE_TEAM_ID` | Harris's 10-character Apple Developer Team ID. Do not use upstream `7P8CLHDH5G`. |

Optional repository **variables** (not secrets) if the defaults should change: `APP_BUNDLE_IDENTIFIER`, `WIDGET_BUNDLE_IDENTIFIER`, `APP_GROUP_IDENTIFIER`, `KEYCHAIN_GROUP_SUFFIX`.

Apple Developer steps before the first signed upload:

1. Create an explicit App ID `com.harrisliangsu.whenreset` with Push Notifications and App Groups.
2. Create an explicit App ID `com.harrisliangsu.whenreset.widgets` with App Groups. Do not enable Push on the widget.
3. Create the App Group `group.com.harrisliangsu.whenreset` and enable it on both App IDs.
4. Create the App Store Connect app record for `com.harrisliangsu.whenreset`.
5. Create an internal TestFlight group named `Internal Testers` (the workflow adds the processed build to that group).
6. Create the App Store Connect API key and store the three values above. Xcode cloud signing creates the distribution certificate and provisioning profiles on the runner; you do not upload a `.p12` or a provisioning profile. Before each archive, the workflow revokes development certificates whose subject is `Apple Development: Created via API (<team id>)` and deletes the Xcode-managed development team profiles for the app and widget. A hosted runner throws away that private key, and a later archive cannot replace the certificate until it is revoked. Personal development certificates and distribution certificates are not removed.

Push from the self-hosted server is separate. The vendored APNs key under `server/apns/` is the upstream author's production key and is topic-specific to `ad.neko.when`. It cannot send to `com.harrisliangsu.whenreset`. For Harris's bundle, set `APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_TOPIC` (`com.harrisliangsu.whenreset`), and `APNS_PRIVATE_KEY` (the `.p8` contents) in the server environment, using a key created for Harris's team.

中文对照：PR 上的 CI 不需要 Apple 密钥。模拟器测试在 runner 上做 ad-hoc 签名，这样钥匙串测试才能通过；Release 构建保持未签名。打上 `v*` 版本标签后，TestFlight 工作流才会用 Apple 团队签名上传。归档前会撤销名为 Created via API 的开发证书，并删除 App 与 Widget 的 Xcode 开发描述文件；个人开发证书和发布证书保留。缺上面四个 secret 时，该工作流会直接失败并列出缺哪几个，不会假成功。开发者网站要先建好 App ID、Widget ID、App Group，并打开主 App 的 Push Notifications。上游的 APNs 密钥不能给这个新 Bundle ID 发推送。应用内检查更新只比较版本并打开 App Store 或 TestFlight，不会下载安装包。App Store 用 iTunes Lookup（id `6829609877`）；TestFlight 读 `master` 上的 `update-check.json`。iOS 上传成功后，`publish-update-feed` 会运行 `Scripts/bump-update-check.sh` 并把该文件推到 `master`。

Release preparation reads `MARKETING_VERSION` only from `project.yml`. That file is
the only place to bump the marketing version and build number. `xcodegen generate --spec project.yml`
writes the same values into `WhenReset.xcodeproj/project.pbxproj`, and CI rejects a
project file or `Config/WhenReset.xcconfig` that disagrees. The checked-in version is
a minimum: if Apple has approved that version on a selected platform, the upload uses
the next patch version after the latest approved release. Build numbers increase across
all app versions and platforms, including paginated build history. The number App Store
Connect already has can be higher than the checked-in build; the workflow still picks
one above that. Xcode's specific unreadable cloud-signing response is retried up to
three times before upload; version-validation failures and potentially completed uploads
are not retried. App Store review submission remains an explicit manual option, separate
from TestFlight uploads.

`update-check.json` on `master` records the iOS build that was actually uploaded, not
the next checked-in version. It stays at that live TestFlight build until another
upload finishes.

iOS update checks never download an app binary. App Store installs compare the installed
version with iTunes Lookup for app id `6829609877`. That lookup does not include TestFlight
builds, so TestFlight installs compare version and build with
`https://raw.githubusercontent.com/harrisliangsu/blinky-ios/master/update-check.json`.
`master` is the durable branch that tracks released builds. After a successful iOS upload,
the `publish-update-feed` job runs `Scripts/bump-update-check.sh` and pushes that file to
`master`. A pre-release build reports a failed check until the file exists on `master`,
instead of reading the temporary `cursor/ios-overhaul-verify` branch. Refresh the feed by
hand with `Scripts/bump-update-check.sh <version> <build>`, then commit `update-check.json`
on `master`. If `master` is protected, the feed job fails visibly and the TestFlight upload
itself still stands.

The release workflow reads these encrypted GitHub Actions repository secrets:

- `APP_STORE_CONNECT_KEY_ID`
- `APP_STORE_CONNECT_ISSUER_ID`
- `APP_STORE_CONNECT_PRIVATE_KEY`
- `APPLE_TEAM_ID`

The private key exists only in the runner’s temporary directory for the duration of the job. Trigger `App Store Release` from the Actions tab and select `both`, `ios`, or `macos`. Pushing a `testflight-*` tag uploads iOS only. After Apple finishes processing the iOS build, the workflow adds it to the `Internal Testers` group.

Raw Xcode export diagnostics stay out of public logs. To investigate an export failure,
an operator can temporarily set the `RELEASE_DIAGNOSTICS_PUBLIC_KEY` repository variable
to an RSA public key of at least 3072 bits, keeping its private key locally. Failed
exports then produce an artifact encrypted with AES-256-GCM and RSA-OAEP-SHA256,
retained for one day. Only that private key can decrypt the diagnostic file. Remove
the variable after investigating; never put the private key in the variable or repository.

## Provider notes

- ChatGPT reads private `wham` usage and banked-reset endpoints.
- Claude uses the Claude Code OAuth client and usage endpoint.
- Grok follows the weekly account pool described by [Pulse](https://github.com/qunqin24/Pulse) (`Docs/providers/grok.md`, `GrokUsageService.swift`, Apache-2.0). Device OAuth scopes are `openid email offline_access grok-cli:access` (`billing:read` is refused for this public client). Usage is `GET /v1/billing?format=credits` and the plan name is `subscription_tier_display` from `GET /v1/settings`, both with `x-xai-token-auth: xai-grok-cli`. An omitted percentage is 0% only while that period is still running. The access token lasts about six hours and is refreshed with the refresh token. Blinky does not treat xAI API spend as the coding pool.
- Kimi uses the public client embedded in the official Kimi Code client. Moonshot does not currently publish a third-party client-registration process.
- GitHub Copilot uses GitHub device authorization, but exact remaining quotas come from the undocumented `copilot_internal/user` endpoint. Its bundled VS Code client ID should be replaced with a separately registered client before distribution.
- 智谱 GLM / Z.AI uses a user-provided Coding Plan key. Automatic mode tries `https://api.z.ai` and then `https://open.bigmodel.cn` (path `/api/monitor/usage/quota/limit`) and stores the host that returns a successful `code` / `success` envelope. Choosing Global or 中国大陆 sends the key to that host only, so a wrong-region key fails on the host the user picked instead of looking like a generic quota error. The quota endpoint is not documented as a public API; general-purpose and pay-as-you-go keys are outside this app’s scope.
- MiniMax uses a user-provided Subscription Key and its documented Token Plan remaining-quota endpoint. Blinky tries the global service first, then the mainland-China service for regional keys. Standard pay-as-you-go keys are outside this app’s scope.
- Synthetic and Warp use user-provided API keys with fixed quota endpoints. Both can opt in to self-hosted Worker monitoring.
- OpenRouter reads the authenticated key's official credit-limit response, including its stable creator identity and daily, weekly, or monthly limit period when configured. Fireworks AI resolves the key's official account resource before reading account quotas, including the monthly USD spend limit when present. Both use fixed provider hosts and can opt in to self-hosted Worker monitoring.
- DeepSeek reads its official user-balance response and prefers USD when the service returns both USD and CNY balances. Poe reads the official current point balance. Neither response documents a reset timestamp, so Blinky displays the available balance without inventing a reset date. Both fixed-host integrations can opt in to self-hosted Worker monitoring.
- OpenAI and Anthropic billing use their organization Cost APIs and require Admin API keys; standard inference keys cannot read organization billing. Without an optional monthly budget, Blinky displays month-to-date spend instead of inventing a remaining balance. Their fixed-host integrations can opt in to self-hosted Worker monitoring.
- New API-compatible accounts read `/v1/dashboard/billing/subscription` and `/v1/dashboard/billing/usage` from the user-selected HTTPS origin. The custom origin and key remain on-device.
- Ollama Cloud currently exposes quota windows on its signed-in settings page, not through its API-key endpoints. Its session cookie therefore remains on-device.
- Antigravity uses Google OAuth and internal Cloud Code Assist quota endpoints. The mobile callback is completed by pasting the localhost URL, and its tokens remain on-device because the protocol is experimental.
- Compatible API accounts issue only `GET` requests to the exact user-entered HTTPS endpoint (or loopback HTTP), send a bearer key, cap responses at 1 MiB, and require explicit percentages or counters plus future reset timestamps. Their URL and key remain on-device.

Blinky tracks recurring coding-plan allowances and explicitly linked API billing accounts. The private and first-party-compatible integrations may change without notice. No provider token is written to app snapshots, logs, or user defaults.

The OpenAI Blossom is used only to identify the ChatGPT provider. OpenAI, ChatGPT, and the Blossom are trademarks of OpenAI; this project is not endorsed by or affiliated with OpenAI.
The Grok provider mark is adapted from CodexBar’s MIT-licensed provider asset and is used only for identification. Grok and xAI are trademarks of xAI; this project is not endorsed by or affiliated with xAI.

## Push refresh server

**[Linux quick start](docs/wiki/Linux-Quick-Start.md)** ·
[Deployment guides](docs/wiki/Home.md) ·
[Docs in this fork](https://github.com/harrisliangsu/blinky-ios/tree/master/docs/wiki) ·
[Security and secrets](SECURITY.md)

Deploy the optional server on [Linux on your own network](server/README.md#deploy-on-linux)
or [Cloudflare Workers](server/README.md#deploy-on-cloudflare-workers). Linux runs the same
dashboard and monitoring API with local SQLite storage, persistent jobs and a systemd service.
Provider requests use the Linux server's outbound IP; choose a static public IP or stable NAT
to keep account checks on a consistent network. An [installation script](server/install.sh)
sets it up and preserves configuration and data on updates:

```bash
sudo bash server/install.sh --origin https://reset.example.com
```

Follow the Linux guide to configure HTTPS and link the app. Both deployments require
explicit account-by-account monitoring consent.

The optional [Cloudflare Worker](server/README.md) is self-hosted in the user’s Cloudflare account. It sends hourly silent refresh hints and can, only for accounts individually opted in by the user, encrypt provider credentials in D1 and record quota every 5 minutes or longer. The app merges those server samples into its 24-hour, 7-day, and 30-day usage charts. Opaque, deployment-specific account references attach retained Worker history to the matching local account and collapse differently named copies of the same verified ChatGPT profile. The app shows whether the Worker’s last provider check found an active or expired session; a new sign-in can replace an expired credential directly on the Worker. Credential upload and replacement are strictly write-only: no API route downloads plaintext credentials, encrypted envelopes, or fingerprints. Overlapping client accounts are fetched once per credential scope and cron occurrence. Blinky does not operate an official server.

After unlocking the Worker dashboard with `REGISTRATION_ACCESS_KEY`, the operator can optionally enroll a WebAuthn passkey for later access. Apple devices can store and synchronize that passkey through iCloud Keychain, but the passkey is scoped to the exact Worker hostname and is separate from the app's synchronized provider credentials. Its private key never leaves the authenticator or password manager. Keep the registration key as the recovery method: changing the hostname requires enrollment on the new hostname, and rotating the registration key invalidates existing dashboard sessions and passkeys. See [dashboard passkeys and recovery](server/README.md#dashboard-passkeys-and-icloud-keychain).

### Intentional shared APNs credential

The APNs signing key under `server/apns/` is deliberately versioned, not an accidentally committed deployment secret. This follows [Bark Server’s implementation](https://github.com/Finb/bark-server/blob/master/apns/apns_certs.go), which bundles its APNs signing credential so independent self-hosted servers can send notifications to the official app.

The vendored APNs key is the upstream author's production key, topic-specific to `ad.neko.when`. It cannot access App Store Connect, Harris's `com.harrisliangsu.whenreset` topic, or discover device tokens. This fork's server advertises `APNS_TOPIC` (default `com.harrisliangsu.whenreset`). Replace the key with one from Harris's team before expecting pushes to the TestFlight app. See the [shared APNs key security model](server/README.md#shared-apns-key) for the upstream key's restrictions.

[![Deploy to Cloudflare](https://deploy.workers.cloudflare.com/button)](https://deploy.workers.cloudflare.com/?url=https://github.com/harrisliangsu/blinky-ios/tree/master/server)
