# When Reset self-hosted server

[![Deploy to Cloudflare](https://deploy.workers.cloudflare.com/button)](https://deploy.workers.cloudflare.com/?url=https://github.com/iebb/when-reset/tree/master/server)

This isolated Cloudflare Worker template can:

- send hourly silent APNs refresh hints to your own devices;
- optionally monitor selected linked accounts every 5 minutes or longer; and
- retain a user-selected history window from 7 days through 2 years for higher-resolution charts; and
- provide a responsive website for account health, quota windows, reset times,
  API balances, device health, collection runs, and retained history.

When Reset does not operate an official server. Server monitoring is off for every account by default. When you enable it for an account, the app uploads that account’s Keychain credentials only to the self-hosted Worker URL you configured.

## Shared APNs key

Like [Bark Server](https://github.com/Finb/bark-server), this repository bundles the APNs signing key required by independent self-hosted servers. The When Reset key was created in Apple Developer with all of these immutable APNs restrictions:

- Service: Apple Push Notification service (APNs) only
- Environment: Production only
- Restriction: Topic Specific
- Sole topic: `ad.neko.when`

It is not an App Store Connect API key and grants no access to Apple accounts, apps, builds, signing assets, analytics, DeviceCheck, WeatherKit, or any other bundle ID or service. Apple’s topic-specific keys are explicitly limited to their selected topics and environment.

The remaining exposure is intentional: anyone with this public key, its public identifiers, and a valid production device token for `ad.neko.when` can send an APNs payload to that device. The key cannot discover device tokens. Each self-hosted Worker keeps its tokens in its own D1 database, and the API never logs them.

The app labels each APNs token as development or production. App Store and TestFlight builds use production. A locally signed Debug build uses Apple’s sandbox, which this production-only shared key cannot access; the Worker disables push hints for that token after Apple returns `BadEnvironmentKeyInToken`, while preserving server monitoring, subscriptions, snapshot sync, and history. A later authenticated production-token rotation re-enables pushes.

Bundled key SHA-256: `9512a4e0063a0aa9ca5974d458c0d4fff6abd936c0d97e97d1814cd919530917`.

## Deploy

Click the button above, sign in to Cloudflare, and choose names for the Worker, D1 database, and Queue. Cloudflare provisions and binds those resources from `wrangler.jsonc`; the deploy script initializes a new D1 database from `schema.sql`, applies tracked D1 migrations, and then deploys the Worker. Existing deployments keep their data while migrations add new cloud-sync fields.

The deployment form asks for two independent secrets:

- `REGISTRATION_ACCESS_KEY`: generate a unique random value of at least 32 characters, for example with `openssl rand -base64 32`. This unlocks the read-only dashboard and authorizes creation of short-lived device links. It is unrelated to APNs and provider credentials.
- `CREDENTIAL_ENCRYPTION_KEY`: generate a different random value of at least 32 characters. The Worker derives an AES-256-GCM key from it and encrypts each provider credential envelope before writing it to D1. Never enter this value in the app and do not rotate it unless you first remove every monitored account.

After deployment:

1. Open the new `https://…workers.dev` URL in a browser.
2. Enter `REGISTRATION_ACCESS_KEY` to unlock the private dashboard. The key is exchanged
   for a 12-hour `HttpOnly`, `Secure`, same-site browser session and is immediately cleared
   from the page. D1 stores only a domain-separated keyed hash of the random cookie token;
   rotating `REGISTRATION_ACCESS_KEY` invalidates every existing dashboard session and
   enrolled dashboard passkey.
3. In **Dashboard access**, optionally choose **Add passkey** after unlocking with the key.
4. In **Link a device**, create a QR code, scan it with Camera, or use **Open When Reset**
   on the same device.
5. Check the Worker hostname and the accounts listed by When Reset, then explicitly confirm the link.

### Dashboard passkeys and iCloud Keychain

After an access-key unlock, the dashboard can enroll a WebAuthn passkey for future sign-ins.
On Apple devices, the system can save and synchronize that passkey through iCloud Keychain
when the user has enabled it; Safari may also offer another credential manager or a nearby
device. The Worker cannot see which Apple Account or password manager owns a passkey, inspect
whether it has synchronized, or force a copy to synchronize.

A passkey is scoped by WebAuthn to the exact Worker hostname where it was enrolled. A passkey
created on a `workers.dev` hostname does not authenticate a later custom hostname, and the
reverse is also true. Settle on the hostname you intend to use, open that URL, and enroll the
passkey there. If the hostname changes, unlock the new hostname with
`REGISTRATION_ACCESS_KEY` and enroll another passkey.

The authenticator or password manager creates and retains the passkey's private key. It never
leaves the authenticator and is never sent to the Worker. D1 stores only the public verification
material and minimal management metadata needed to accept the passkey. This dashboard passkey
is separate from the provider credentials that the When Reset app may synchronize through
iCloud Keychain; enrolling it neither copies nor exposes any provider token, API key, session,
or encrypted credential envelope.

Keep `REGISTRATION_ACCESS_KEY` in a separate secure location even after enrolling a passkey.
It remains the recovery method when a passkey is missing, deleted, unavailable on a new device,
or no longer accepted. Unlock with the key, remove the stale Worker registration, and enroll a
replacement. Removing a passkey in the dashboard stops this Worker from accepting it but cannot
delete the user's copy from Apple Passwords or another credential manager; remove that copy
separately if desired. If both the passkey and key are unavailable, replace
`REGISTRATION_ACCESS_KEY` in the Cloudflare deployment, unlock with the new value, and enroll
again. Rotation deliberately invalidates every dashboard session and previously enrolled
passkey; an old local passkey may remain visible in a password manager, but the Worker will no
longer accept it.

The QR contains only the Worker HTTPS origin and a random, five-minute, one-use token. It never contains either deployment secret or any provider credential. Scanning only loads authenticated Worker metadata. When Reset does not register the device, save the Worker configuration, or upload any selected account credentials until the user confirms. The confirmation explains that the Worker operator is inside the credential trust boundary and identifies every account that will be uploaded.

After the device registers, enable **Monitor on Self-hosted Server** in each account that you want the Worker to fetch. The global **Server monitoring** picker controls the selected accounts’ cadence, starting at 5 minutes, and **Cloud history retention** controls how long each account’s Worker history is kept. Per-quota “Show as 100%” choices are sent as minimal metric descriptors so server-side chart samples preserve that behavior when a provider omits a quota. The Worker cron runs every 5 minutes and writes each successful per-quota sample to D1; When Reset merges downloaded server samples into the same charts as on-device refreshes. Silent device refresh hints remain hourly. APNs background delivery is best-effort: iOS may coalesce, delay, or suppress it, so a server sample can reach the on-device chart later than it was recorded.

**Upload Local History** backfills eligible on-device samples into D1. Every history row carries a deterministic tag derived from the account, metric, and recorded second; D1 enforces uniqueness by both that tag and the natural account/metric/timestamp key, so retries and samples already created by the Worker do not duplicate history. Uploaded rows are accepted only inside the selected retention window and never contain credentials.

A registered device can also choose **Add from self-hosted Worker**. The account list contains only opaque keyed references, provider, display name, plan, last-success time, and a coarse session status. For ChatGPT, each successful Worker refresh verifies the signed-in user through the provider profile endpoint and combines that identity with the official ChatGPT account/workspace ID used for the quota request before converting the tuple into a deployment-specific HMAC; neither raw value is stored in D1 or returned. An unavailable profile endpoint does not stop quota collection, but that refresh is not trusted for cross-device merging; unverified JWT payloads are never used as account identity. This lets differently named copies of the same exact ChatGPT account collapse into one logical account while keeping a user’s personal, team, and enterprise quota scopes separate. The app attaches the subscription and retained history to the matching local account instead of keeping a duplicate; otherwise it creates a remote-only account.

Importing never copies or returns the provider credential envelope, fingerprint, workspace identifier, source device identifier, raw source account identifier, or raw provider profile ID. A remote-only account has no provider credentials in its Keychain and cannot fall back to a local provider request. Manual, launch, background, and silent-push refreshes only download the Worker snapshot and history for any attached subscription. Imports are idempotent, and an existing local subscription can repair a missing Worker mapping from its opaque remote reference without receiving credentials. Multiple subscribed devices still share the same persisted cron run and single provider fetch. Removing an imported account deletes only that device’s subscription and cached local data, not the Worker’s source account.

The account screen can re-check the last Worker refresh and identifies authentication failures as an expired session. **Update Worker sign-in** performs a new provider authorization and sends the resulting credential directly to the authenticated Worker route. The existing Worker account scope is never changed during replacement. Where the provider exposes a stable identity, the Worker also proves that it matches the prior provider-account-scoped opaque reference; legacy unscoped references migrate once after successful provider verification. Fixed-host providers without an identity endpoint verify the replacement credential with the provider and retain the existing Worker logical scope. The Worker then atomically replaces the encrypted credential, clears expired state from other direct devices and remote subscriptions, and sends them a silent refresh hint. This recovery applies to every provider supported by off-device monitoring.

After a successful upload, **Remove Synced Credentials** can make the Worker the account’s credential authority. The app then deletes that account’s synchronizable Keychain credential, including its iCloud-synced copies, while retaining only account metadata locally. Provider tokens remain write-only: signing in again can replace the Worker copy, but no Worker route downloads credentials. Refresh cadence and history retention can still be changed after local credentials have been removed.

From the private dashboard, each account has two destructive actions. **Remove · keep data**
detaches the account from monitoring, deletes the Worker-held provider credential, and moves
sanitized quota history into an opaque server-side archive. Re-adding the same provider and
workspace with the app restores that retained history. **Delete · all data** permanently removes
the account’s Worker snapshot, credential, consent, and retained history. Both actions require
the recovery-key management grant; a passkey-only session must re-verify the recovery key.

### Linked device management

**Linked devices** lists every device registered against the Worker. Each row is addressed by an
opaque HMAC handle and shown under a short derived label such as `7QF2`, so the dashboard can
manage a device without ever receiving, rendering, or echoing its real identifier or APNs token.
Alongside the label the row reports when the device was linked, when it was last seen, its push
state and last delivery, whether it registers production or sandbox APNs, and how many accounts
it asks the Worker to monitor, publishes usage for, or follows from another device.

**Disable push** clears APNs delivery for that device while leaving it linked; it keeps syncing
whenever the app is open, and delivery can be resumed from the same row. **Unlink** removes the
registration, cascades the device’s Worker-held accounts, consents, snapshots, and retained
history, and writes a deletion tombstone so the device learns it was removed instead of silently
re-registering. Both actions require the recovery-key management grant, and the dashboard raises
one shared **Verify recovery access key** step-up for every destructive action rather than
hiding the prompt inside an unrelated settings card.

### Manual deployment

```sh
npm install
npm test
npm run check
npx wrangler d1 create when-reset-push
npx wrangler queues create when-reset-push
```

Put the returned D1 ID in `wrangler.jsonc`, set both secrets, then deploy. The deploy command initializes missing base tables and applies pending migrations:

```sh
npx wrangler secret put REGISTRATION_ACCESS_KEY
npx wrangler secret put CREDENTIAL_ENCRYPTION_KEY
npm run deploy
```

## Trust boundary

Each app installation creates a random UUID and a 256-bit device secret. D1 stores the UUID, APNs token, and only a SHA-256 hash of that secret. The UUID is a lookup identifier, not authentication: account sync, update, delete, and test-push routes require the device-held secret. The secret uses a device-only Keychain accessibility class and does not sync with account credentials.

An APNs token can belong to only one device UUID. Link claims, access-key registrations, and authenticated token rotations return `409 apns_token_conflict` instead of silently transferring a token owned by another registration.

Device unregister is idempotent when a successful response is lost. The D1 transaction first stores a deletion tombstone and then deletes the live device, cascading its accounts, credentials, consent records, and history. A permanent APNs rejection does not unregister the device: it disables further pushes only when both the device UUID and rejected token still match, preserving monitored accounts, remote subscriptions, snapshots, and history. A later authenticated token rotation clears that push-disabled state. The deletion tombstone contains only the device UUID, SHA-256 device-secret hash, and deletion timestamp—never an APNs token or provider data. An authenticated unregister retry returns `204`; a wrong secret returns `401`. Successful registration or QR relinking clears an older tombstone, and authentication against a live re-registered device always takes precedence so its previous secret cannot delete it. Remaining tombstones are pruned after 90 days.

The browser link page asks for the deployment’s registration key over HTTPS and uses it only to create a link session. D1 stores only a SHA-256 hash of the random session token. A session expires after five minutes and its claim is a conditional D1 transaction, so only one device can consume it. Expired sessions are pruned by cron. The long-lived registration key is never returned by the Worker, embedded in a QR code, or stored by the app when QR linking is used.

Provider credentials are write-only through the Worker API: the app can upload or replace them after explicit consent, but no response, sync route, dashboard route, or website asset returns plaintext credentials, encrypted credential envelopes, or credential fingerprints. There is deliberately no credential download endpoint. The dashboard API uses explicit SQL and response allowlists, opaque keyed account and chart identifiers, aggregate device/run data, and generic health classes; it omits raw device, account, workspace, profile, email, provider-error, APNs, and credential fields. A fail-closed runtime schema rejects every dashboard field or nested object that is not explicitly allowlisted for that endpoint. The app ignores a `credentials` field even if a modified server tries to send one. Credentials are encrypted with AES-256-GCM before D1 storage. The authenticated encryption context binds ciphertext to its device, account, provider, and schema version. D1 also encrypts its storage at rest. This protects a copied database, but the Worker must be able to decrypt credentials internally to call providers: anyone controlling the Worker deployment or `CREDENTIAL_ENCRYPTION_KEY` is inside the trust boundary. Use only a Worker account you control. Requests use fixed provider HTTPS endpoints, including Grok Build billing, Synthetic, Warp, OpenRouter key limits, Fireworks AI account quotas, DeepSeek balances, Poe point balances, OpenAI organization costs, and Anthropic organization costs; response sizes are bounded, and structured logs never contain credentials, provider response bodies, account IDs, device IDs, or quota values. Ollama Cloud sessions, Antigravity OAuth, New API-compatible origins, and other compatible custom endpoints are intentionally on-device only.

For scheduled monitoring, the Worker derives a keyed HMAC fingerprint over the exact authentication credential set and its provider, workspace, and plan scope. Display-only settings such as an API monthly budget are excluded, then reapplied separately for each target during fan-out. The fingerprint cannot be reversed without the deployment secret and is never sent to a client or placed in a Queue message. Accounts from multiple app installations with the same scope are grouped into one persisted cron run. Its Queue message contains only an opaque run ID; an atomic D1 claim permits at most one provider fetch for that credential scope and cron occurrence even when Cloudflare delivers duplicate messages. Scheduling reserves each target, and a newer occurrence prevents an older result from overwriting it. The encrypted refreshed credential result is persisted only long enough to fan the snapshot and history out to every still-consenting target, then erased. Queue-send and fan-out gaps are re-enqueued by cron, and a retry resumes from a persisted result without calling the provider again. If execution stops after the run is claimed but before the result is saved, that occurrence fails closed and a later cron occurrence tries again instead of risking a duplicate fetch. Removing the last target erases any transient result but retains a credential-free idempotency tombstone until normal pruning.

Disabling monitoring for a source account deletes its server credentials, latest snapshot, and history. Removing a remote-only import deletes only its subscription. Removing the device registration deletes that device’s monitored accounts and subscriptions. History older than each account’s configured retention is pruned by cron.

### Credential-free device usage uploads

An account can separately opt in to publishing sanitized usage from When Reset after an on-device
refresh. This mode does not upload, create, replace, or delete provider credentials. Its D1 consent,
source, and history tables are independent from Worker polling, so both modes can be enabled for
the same local account. The dashboard coalesces that exact device/account pair, prefers its freshest
usable snapshot, labels whether the visible result came from **Device upload** or **Worker polling**,
and combines their allowlisted history without exposing the local identifiers.

The authenticated enable request contains only provider, display label, cadence, retention, and a
monotonic consent revision. Each upload contains a strict projection of quota windows, reset-credit
times/status, plan, and optional API balance. It is capped at 32 KiB, 32 windows, and 32 reset
credits. Unknown fields—including workspace, profile, email, account-reference, credential, token,
and raw-provider fields—are rejected. A sequence number plus a payload hash makes a lost-response
retry idempotent while rejecting conflicting replays; observations outside retention or more than
five minutes in the future are rejected. `DELETE` with a newer consent revision stores a disabled
tombstone and removes only the credential-free snapshot/history source. Repeating the disabled
revision is idempotent; the same revision cannot turn an enabled source off.

Device-published sources are available to the private dashboard and its history charts. They are
not offered through remote-account discovery in this version; that existing feature remains limited
to credential-backed Worker sources.

### Monitoring consent revisions

Account monitoring uses a monotonic consent tombstone per device and account so a delayed upload cannot recreate credentials after the user disables monitoring:

- account `PUT` bodies carry `consent_revision` as a positive JSON-safe integer;
- account `DELETE` requests carry the revision in `?consent_revision=…`;
- a `PUT` is accepted when its revision is newer, or when it repeats the currently enabled revision;
- a `DELETE` is accepted at the current or a newer revision, and repeating the current disabled revision is idempotent; and
- stale requests return `409 consent_revision_conflict` without changing credentials, history, or the tombstone.

Because this is a fresh deployment, there are no existing monitored accounts to seed. For client compatibility, an older app that omits the revision is treated as revision 1. This allows an initial legacy enable or disable, but an omitted revision can never cross an existing disabled or newer tombstone. A newer explicit revision is required to re-enable monitoring after deletion.

Cron enqueues push-enabled devices seen within the last 45 days. Provider-monitoring messages are deduplicated by cron occurrence and credential scope before they enter the Queue. Queue consumers retry result fan-out without repeating the provider request. Invalid or unregistered APNs tokens disable only push delivery; server-side provider monitoring and authenticated snapshot sync continue. A short-lived APNs provider JWT is cached in D1 and rotated after 50 minutes.

## HTTP API

- `GET /healthz` — deployment mode and fixed APNs topic
- `GET /` or `GET /link` — credential-safe monitoring dashboard and private app-link page
- `POST /v1/dashboard/session` — exchange the registration key, from the exact Worker
  origin, for a hashed 12-hour `HttpOnly` browser session
- `DELETE /v1/dashboard/session` — invalidate the browser session and clear its cookie
- `GET /v1/dashboard` — return only allowlisted account/quota summaries and aggregate
  device/run health; credentials and internal identifiers are never returned
- `GET /v1/dashboard/accounts/:opaque/history?range=24h|7d|30d` — return bounded,
  allowlisted quota history using opaque keyed account and series identifiers
- `DELETE /v1/dashboard/accounts/:opaque?mode=preserve|purge` — remove one logical account;
  preserve archives sanitized history for a future re-add, while purge removes all stored data
- `GET /v1/dashboard/devices` — list linked devices behind opaque keyed handles, with a short
  derived label, environment, linked/last-seen/last-push timestamps, push state, and how many
  accounts each device monitors, publishes, or follows; device identifiers and APNs tokens are
  never returned
- `PATCH /v1/dashboard/devices/:opaque` — `{"push_enabled": true|false}` to stop or resume APNs
  delivery to one device without unlinking it
- `DELETE /v1/dashboard/devices/:opaque` — unlink one device, cascade its Worker-held accounts,
  consents, snapshots, and history, and write a deletion tombstone so the device learns it was
  removed
- `POST /v1/link-sessions` — create a five-minute link; requires `X-When-Reset-Server-Key`
  or an authenticated dashboard session
- `GET /v1/link-sessions/:session` — authenticate the QR token and return Worker metadata
- `POST /v1/link-sessions/:session/claim` — atomically consume the QR token and register one device
- `POST /v1/devices` — register or rotate an APNs token; requires `X-When-Reset-Server-Key`
- `PUT /v1/devices/:id` — rotate an existing APNs token using the device secret
- `DELETE /v1/devices/:id` — idempotently remove a registration using the device secret
- `POST /v1/devices/:id/refresh` — send one silent test push using the device secret
- `GET /v1/devices/:id/remote-accounts` — list sanitized, unsubscribed logical Worker accounts using opaque references plus account metadata and session status
- `POST /v1/devices/:id/remote-accounts` — create a read-only local subscription; no provider credential is copied or returned
- `PUT /v1/devices/:id/accounts/:account` — opt in or update encrypted provider credentials; JSON includes `consent_revision`
- `PUT /v1/devices/:id/accounts/:account` with `X-When-Reset-Credential-Update: replace-remote` — validate and replace an expired remote subscription’s credential without returning it
- `PATCH /v1/devices/:id/accounts/:account/settings` — update monitoring cadence and history retention without resending provider credentials
- `POST /v1/devices/:id/accounts/:account/history` — backfill tagged local history with idempotent deduplication
- `DELETE /v1/devices/:id/accounts/:account?consent_revision=N` — persist a consent tombstone and remove the server-side account and history
- `GET /v1/devices/:id/accounts/:account/sync` — return account metadata, the latest quota, status, and paginated history; credentials are never returned
- `PUT /v1/devices/:id/accounts/:account/snapshots` — explicitly enable or update credential-free device usage publishing; returns the next upload sequence
- `POST /v1/devices/:id/accounts/:account/snapshots` — publish one bounded, sanitized quota snapshot after an on-device refresh; never accepts credentials
- `DELETE /v1/devices/:id/accounts/:account/snapshots?consent_revision=N` — tombstone consent and remove only the device-published snapshot/history source

All account routes require the device secret. Sync responses use `Cache-Control: no-store`.

## Cloudflare usage

Cloudflare Queues counts a normally delivered message as three operations: write, read, and delete. Both scheduled account refreshes and device hints consume Queue operations. D1 retains one row per reported quota per successful refresh for the configured 7-day to 2-year window. A personal deployment is normally small, but check [Cloudflare Queues pricing](https://developers.cloudflare.com/queues/platform/pricing/) and [D1 limits](https://developers.cloudflare.com/d1/platform/limits/) before selecting long retention or monitoring many accounts at short intervals.
