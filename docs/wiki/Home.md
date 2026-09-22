# When Reset deployment guides

Run the account-monitoring server on **Linux on your own network** or **Cloudflare Workers**.
Both use the same dashboard, device-linking protocol and per-account monitoring consent.
Linux sends provider requests through that host's network, with local SQLite storage and
durable background jobs. Cloudflare manages the runtime, D1 database and queue for Workers.

| Guide | What it covers |
| --- | --- |
| [Linux quick start](Linux-Quick-Start.md) | Install, enable HTTPS, unlock the dashboard and link the app |
| [HTTPS and private networks](HTTPS-and-Private-Networks.md) | Public VPS, LAN/VPN, reverse proxy and stable outbound IP |
| [Operations and backups](Operations-and-Backups.md) | Upgrade, health checks, backup, restore and troubleshooting |
| [Security and secrets](Security-and-Secrets.md) | Credential protection, logs, access keys and incident response |
| [Moving from Cloudflare Workers](Moving-from-Cloudflare-Workers.md) | Move monitoring to Linux without exporting credentials |
| [Cloudflare deployment](https://github.com/iebb/when-reset/blob/master/server/README.md#deploy-on-cloudflare-workers) | Deploy with the Cloudflare button or Wrangler |

A stable provider-facing IP requires a static public address or stable NAT egress. Installing
the server does not make a dynamic residential address static. Device accounts left in local
monitoring mode still contact providers from the device's network.

The server is self-hosted; there is no official shared account-monitoring service. Install it
only on infrastructure you trust with the accounts you choose to monitor. See the
[security policy](https://github.com/iebb/when-reset/blob/master/SECURITY.md) for the trust boundary.

These pages are maintained in
[`docs/wiki` on master](https://github.com/iebb/when-reset/tree/master/docs/wiki).
