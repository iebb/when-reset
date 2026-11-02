# Changelog

## Unreleased

- Settings is grouped by module: Appearance (system, light, or dark, and continuous or segmented usage bars; a fresh install draws one continuous bar), Forecasts, Language, Notifications, Refresh, Live Activity, Self-hosted Worker, and About. Account display name and icon stay on the account screen. Notifications show permission, unexpected or early resets, scheduled reset times, and each account’s detected-reset and scheduled-reset switches.
- Usage cards lead with the limit bars. Banked resets are one collapsed row under those bars. A card can also say how long a limit may last, and a ChatGPT card can show the public Codex Resets predicted reset. Settings → Forecasts holds those switches.
- The Usage list keeps the dragged custom order, or it can sort by lowest remaining or soonest reset. That choice does not rewrite the saved order. The soonest-reset badge does not move a row while the list is in custom order. Widgets and Live Activity follow the visible order; a widget pinned to one account stays on that account.
- Settings → Token activity charts the last 12 months (daily, weekly, or cumulative). Performance, with cache, input, output, and tokens per second, sits under that chart when a span has those figures. iOS does not scan local agent transcripts yet, so the page stays empty until records are available.
- Usage is the subject: account order is saved and synced, medium and large widgets default to a multi-account list, and Live Activity shows each included account's remaining percent. The soonest reset is a badge.
- 智谱 and z.ai are separate providers. Domestic Coding Plan keys that report `CREDIT_LIMIT` link and show remaining percent even when a reset time is missing. Browser sign-in can create a Coding Plan key. Existing mainland accounts move to 智谱.
- Codex device sign-in copies the code and opens the bare device page unless OpenAI returns `verification_uri_complete`.
- Simplified Chinese and English follow the system language, with an in-app override.

## 1.8

### 中文

- 主屏幕、设置和 App Store 图标改为与 Mac 相同的 Blinky 吉祥物：深海军蓝底、奶油色绒毛、黄绿色耳尖和头顶嫩芽、眨眼。源图本身已带圆角；iOS 资源改为铺满画布的不透明方形，只由系统遮罩裁一次圆角，避免套两层圆角把图案缩小。Bundle ID、Widget ID 和 App Group 不变，仍是 `com.harrisliangsu.whenreset`。

### English

- The Home Screen, Settings, and App Store icon now matches the Mac Blinky mascot: dark navy ground, cream fluff, lime ear tips and sprout, winking. The source art already includes a squircle, so the iOS asset is a full-bleed opaque square and the system mask rounds it once. That avoids a second rounding pass shrinking the artwork. Bundle ID, widget ID, and App Group stay `com.harrisliangsu.whenreset`.

## 1.7

### 中文

- 本分支的用户可见产品名改为 **Blinky**（主屏幕、设置、小组件文案和自托管面板）。Bundle ID、Widget ID 和 App Group 不变，仍是 `com.harrisliangsu.whenreset`。这是 Harris 分支的品牌，不是原项目；上游仍是 [iebb/when-reset](https://github.com/iebb/when-reset)（When Reset）。本仓库是 [harrisliangsu/blinky-ios](https://github.com/harrisliangsu/blinky-ios)。

### English

- This fork's user-visible product name is now **Blinky** (Home Screen, Settings, widget copy, and the self-hosted dashboard). Bundle ID, widget ID, and App Group are unchanged (`com.harrisliangsu.whenreset`). Blinky is this fork's branding, not a claim to be the original; upstream remains [iebb/when-reset](https://github.com/iebb/when-reset) (When Reset). This repository is [harrisliangsu/blinky-ios](https://github.com/harrisliangsu/blinky-ios).

## 1.6

### 中文

- 智谱 GLM Coding Plan 增加中国大陆主机 `https://open.bigmodel.cn`，与国际站 `https://api.z.ai` 使用同一额度路径 `/api/monitor/usage/quota/limit`。HTTP 200 上的 `code` / `success` 信封也会被识别。添加账号时可选择自动、Global 或中国大陆；成功的主机按账号保存，避免区域不匹配的 key 反复打到另一台主机。
- Grok 对齐 Pulse 的每周额度池：设备码 scope 仅为 `openid email offline_access grok-cli:access`，读取 `/v1/billing?format=credits` 与 `/v1/settings`，请求头 `x-xai-token-auth: xai-grok-cli`，并刷新大约 6 小时的访问令牌。
- ChatGPT / Codex、Kimi Code、智谱 GLM、Grok 的额度窗口进入主屏幕小组件、锁屏小组件和 Live Activity，并带上各自的供应商标记。
- Bundle ID、Widget ID、App Group 和 Team ID 改为可配置，默认使用 Harris 的前缀 `com.harrisliangsu.whenreset`，不再使用上游 `ad.neko.when`。
- macOS GitHub Actions：PR 上运行 xcodegen、模拟器测试和未签名构建，不需要 Apple 密钥。版本标签 `v*` 会归档并上传 TestFlight；缺少密钥时工作流会列出缺失项并停止。

### English

- 智谱 GLM Coding Plan now accepts the mainland host `https://open.bigmodel.cn` as well as `https://api.z.ai`. Both use `/api/monitor/usage/quota/limit`, including the `code` / `success` envelope on HTTP 200. The add-account screen can choose Automatic, Global, or 中国大陆, and the host that accepts the key is stored on that account.
- Grok follows Pulse's weekly credit pool: device-code scopes `openid email offline_access grok-cli:access`, `GET /v1/billing?format=credits` and `/v1/settings` with `x-xai-token-auth: xai-grok-cli`, and refresh of the roughly six-hour access token.
- ChatGPT / Codex, Kimi Code, 智谱 GLM, and Grok quota windows feed Home Screen widgets, Lock Screen widgets, and Live Activity, with each provider's mark.
- Bundle ID, widget ID, App Group, and Team ID are configurable. Defaults use the Harris-owned prefix `com.harrisliangsu.whenreset` instead of upstream `ad.neko.when`.
- macOS GitHub Actions runs xcodegen, simulator tests, and an unsigned build on pull requests without Apple secrets. A `v*` tag archives and uploads to TestFlight, and stops with the missing secret names when those secrets are absent.
