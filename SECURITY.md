# Security and secret handling

When Reset can monitor accounts on an operator's Cloudflare Worker or Linux server. The
operator, host administrators, deployment dependencies and TLS termination are trusted:
the server must decrypt opted-in credentials to contact each provider. No software can
guarantee that secrets will never leak from a compromised host, browser or operator account.

## Protections in this repository

- Provider credential upload and replacement are write-only. Credentials are encrypted
  with AES-256-GCM before database storage. Dashboard, history, sync and push responses do
  not export credentials, encrypted envelopes or credential fingerprints.
- The dashboard recovery key and credential encryption key are separate. Dashboard and
  device bearer tokens are hashed at rest; dashboard cookies use Secure, HttpOnly and
  same-site restrictions. Protected mutations validate the request origin.
- Logs use fixed events and bounded status codes. Arbitrary exception names, messages,
  provider bodies and APNs errors are excluded. Worker invocation logs are disabled in
  the supplied configuration; Linux does not produce HTTP access logs.
- All JSON API responses use `Cache-Control: no-store`. The server never serves local
  files. Provider and APNs HTTP requests do not follow redirects with credentials.
- The Linux installer generates independent random keys, disables shell tracing before
  handling them, and never prints them. A dedicated user runs the service; data directories
  are mode 0700, SQLite is 0600, and the environment file is root-owned 0640. Core dumps are
  disabled for the service. A terminal-only helper reveals just the dashboard recovery key.
- CI checks both runtimes, secret-disclosure canaries, installation/upgrade logs, private
  file permissions and full Git history with Gitleaks. These checks reduce mistakes;
  they are not a proof that every possible secret or future vulnerability is detected.

Account labels, usage history, APNs device tokens and some other operational metadata are
not encrypted at the application layer. Protect the entire database, filesystem snapshots
and backups. A backup containing both the database and encryption key can decrypt provider
credentials. Use encrypted storage and restricted, encrypted off-host backups as appropriate.

## Intentional public APNs key

`server/apns/WhenResetSharedAPNs.p8` is deliberately public so independent servers can send
refresh hints to the official app. It is production-only and scoped to `ad.neko.when`; it
does not grant App Store Connect access or discover device tokens. This is the only private
key file exception in secret scanning. CI checks its exact fingerprint, including history.
Deployment keys, provider credentials and APNs device tokens are **not** public exceptions.

## Operating securely

See [Security and Secrets](docs/wiki/Security-and-Secrets.md) for TLS, proxy logging, backup
protection, key recovery and incident response. Never put a key in a URL, shell command
argument, issue, screenshot, public CI variable or wiki page. Do not enable request-body or
header logging, Node inspector access, shell tracing around manual secret commands, or
debugging that dumps environment variables.

## Reporting a vulnerability

Use [GitHub's private vulnerability reporting](https://github.com/iebb/when-reset/security/advisories/new)
before disclosing exploitation details. Public issues
may describe a problem in general terms, but must never contain real keys, cookies, tokens,
environment files, database files or backups. Use synthetic values to reproduce a report.
