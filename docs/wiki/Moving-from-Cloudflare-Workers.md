# Moving from Cloudflare Workers

Linux is an additional deployment option. Your existing Worker can continue to run, and
other users can keep deploying Workers. A Linux instance uses its own SQLite database,
keys, device links, account references and hostname-scoped passkeys.

## Move monitoring to your own network

1. Complete the [Linux quick start](Linux-Quick-Start.md) and verify HTTPS and health checks.
2. Link the Linux hostname in the app. Existing controls may call it a “Worker”; use the
   Linux HTTPS origin in those controls.
3. Select the accounts to monitor on the new server and explicitly grant consent there.
   If credentials have been removed from the device or an account exists only as a remote
   subscription, sign in again. The old server has no credential-download endpoint.
4. Wait for a successful provider check on Linux, then use the new server-backed account
   subscription for device refreshes that should use your network.
5. Disable monitoring for those accounts on the old Worker once the new server works.
   During an overlap, both instances may contact providers. Unlink or retire the old
   deployment when no clients need it.
6. Enroll passkeys on the Linux hostname and keep its independently generated recovery key.

Do not reuse the Worker's environment file or copy deployment secrets through chat, wiki or
command arguments. Independent deployment keys reduce the impact of a single compromised host.

## History and data

There is no supported D1-to-SQLite import or credential export. The Linux runtime rejects
an existing database that lacks its migration ledger. Deployment-specific identifiers and
encryption make a raw database copy insufficient. Preserve any old history you still need
on the original deployment and begin a new monitoring history on Linux.

Existing plan names are not retroactively reconstructed into transition events. Plan changes
are recorded from subsequent updates; charts do not connect sample gaps longer than 12 hours.

## What determines the IP providers see?

Scheduled Linux monitoring uses that server's outbound network. Accounts still monitored
locally use the device's network, and the old Worker continues to use Cloudflare egress until
you disable its checks. An HTTPS tunnel to your Linux dashboard affects inbound access; it
does not route outbound provider polling through Cloudflare.

If the Linux host has a dynamic ISP address, use a static-IP service or fixed egress gateway
under your control. The installation script does not change ISP or routing behavior.
