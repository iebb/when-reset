# When Reset self-hosted server

[![Deploy to Cloudflare](https://deploy.workers.cloudflare.com/button)](https://deploy.workers.cloudflare.com/?url=https://github.com/iebb/when-reset/tree/master/server)

This isolated Cloudflare Worker template sends hourly silent APNs refresh hints to your own devices. When Reset then fetches every provider directly on the device, records usage history, updates widgets and Live Activities, and creates reset notifications locally.

When Reset does not operate an official server. Provider OAuth tokens, API keys, account details, quota values, and history never reach this Worker.

## Shared APNs key

Like [Bark Server](https://github.com/Finb/bark-server), this repository bundles the APNs signing key required by independent self-hosted servers. The When Reset key was created in Apple Developer with all of these immutable APNs restrictions:

- Service: Apple Push Notification service (APNs) only
- Environment: Production only
- Restriction: Topic Specific
- Sole topic: `ad.neko.when`

It is not an App Store Connect API key and grants no access to Apple accounts, apps, builds, signing assets, analytics, DeviceCheck, WeatherKit, or any other bundle ID or service. Apple’s topic-specific keys are explicitly limited to their selected topics and environment.

The remaining exposure is intentional: anyone with this public key, its public identifiers, and a valid production device token for `ad.neko.when` can send an APNs payload to that device. The key cannot discover device tokens. Each self-hosted Worker keeps its tokens in its own D1 database, and the API never logs them.

Bundled key SHA-256: `9512a4e0063a0aa9ca5974d458c0d4fff6abd936c0d97e97d1814cd919530917`.

## Deploy

Click the button above, sign in to Cloudflare, and choose names for the Worker, D1 database, and Queue. Cloudflare provisions and binds those resources from `wrangler.jsonc`; the deploy script applies the D1 migration automatically.

The setup form asks for one secret:

- `REGISTRATION_ACCESS_KEY`: generate a unique random value of at least 32 characters, for example with `openssl rand -base64 32`. This authorizes device enrollment into your Worker. It is unrelated to APNs and provider credentials.

After deployment, open When Reset → Settings → Push Refresh, choose Self-hosted server, and enter:

- the new `https://…workers.dev` URL
- the same `REGISTRATION_ACCESS_KEY`

The default cron runs hourly. Change `triggers.crons` in `wrangler.jsonc` if you want a different cadence. Silent background notifications remain best-effort: APNs may coalesce them, and iOS may delay or suppress execution based on device conditions.

### Manual deployment

```sh
npm install
npm test
npm run check
npx wrangler d1 create when-reset-push
npx wrangler queues create when-reset-push
```

Put the returned D1 ID in `wrangler.jsonc`, set the enrollment secret, then deploy:

```sh
npx wrangler secret put REGISTRATION_ACCESS_KEY
npm run deploy
```

## Trust boundary

Each app installation creates a random UUID and a 256-bit device secret. D1 stores the UUID, APNs token, and only a SHA-256 hash of that secret. The UUID is a lookup identifier, not authentication: update, delete, and test-push routes require the device-held secret. The secret uses a device-only Keychain accessibility class and does not sync with account credentials.

Cron enqueues devices seen within the last 45 days. Queue consumers retry transient failures and delete registrations rejected by APNs as invalid or unregistered. A short-lived APNs provider JWT is cached in D1 and rotated after 50 minutes.

## HTTP API

- `GET /healthz` — deployment mode and fixed APNs topic
- `POST /v1/devices` — register or rotate an APNs token; requires `X-When-Reset-Server-Key`
- `DELETE /v1/devices/:id` — remove a registration using the device secret
- `POST /v1/devices/:id/refresh` — send one silent test push using the device secret

No endpoint accepts provider credentials or quota data. Structured logs contain event names, counts, HTTP status codes, and APNs rejection reasons, but omit device UUIDs, APNs tokens, and secrets.

## Cloudflare usage

Cloudflare Queues counts a normally delivered message as three operations: write, read, and delete. The Free plan currently includes 10,000 Queue operations per day, enough for roughly 3,333 successful device pushes before retries. A personal deployment is normally far below that allowance; check [Cloudflare Queues pricing](https://developers.cloudflare.com/queues/platform/pricing/) before increasing the cadence substantially.
