# HTTPS and private networks

The HTTPS hostname is how devices reach your dashboard and sync API. The **outbound IP** is
the address providers see when this server checks accounts. These are separate network
paths. A reverse proxy or inbound tunnel does not automatically stabilize provider-facing egress.

## Public VPS

1. Reserve a static public IP from your host. Check both IPv4 and IPv6 egress if both are enabled.
2. Point `reset.example.com` at the server and configure HTTPS using the quick start.
3. Allow inbound HTTPS to the reverse proxy and whatever certificate validation requires.
   Keep SSH restricted according to your access policy. Keep port 8787 private to localhost.
4. Allow outbound DNS and HTTPS to provider APIs and Apple's APNs endpoints. APNs uses HTTP/2.

Verify the outbound address in your provider/network console. The app's last-success time
and provider access history help confirm that account monitoring uses the intended server.
Do not send an account token to an IP-checking service.

## Home server, office LAN or VPN

Run the service on a host with a stable LAN address, behind the outbound connection you want
to use. Your clients must be connected to that LAN/VPN to open the dashboard and sync if it
has no public inbound route. The server can continue polling while clients are disconnected.
This does not guarantee background iOS VPN connectivity.

Choose a stable hostname and one of these certificate arrangements:

- A publicly trusted certificate obtained with DNS validation, plus split DNS pointing the
  hostname to the private address. Caddy's DNS challenge needs the matching DNS provider
  module and narrowly scoped DNS credentials; protect those credentials separately.
- Your organization's existing HTTPS reverse proxy and certificate management.
- A private CA whose root you deliberately install and trust on every browser and device.
  Do not bypass TLS warnings or use `curl -k` as a deployment fix.

For an existing certificate and key on the proxy host, Caddy can use:

```caddyfile
reset.example.com {
    tls /etc/caddy/certs/reset-fullchain.pem /etc/caddy/certs/reset-key.pem
    reverse_proxy 127.0.0.1:8787
}
```

Restrict the TLS key to the proxy's service account and arrange certificate renewal. These
TLS paths are examples for the operator's host, never files to commit to the repository.
See [Caddy's automatic HTTPS guide](https://caddyserver.com/docs/automatic-https) for challenge
and private-CA details.

## Proxy configuration and logging

Set `PUBLIC_ORIGIN` to the **exact external HTTPS origin**, without a path or query string.
The Linux bridge deliberately ignores incoming Host/forwarded-host values when building
application URLs. The browser's Origin header must match the configured public origin.
Preserve cookies and request headers through the proxy; do not cache any application routes.
If another access gateway requires an interactive sign-in, verify native app linking and
background sync too: the app cannot necessarily complete that gateway's browser login.

Keep the proxy on the same host when using `127.0.0.1:8787`. For a separate proxy host, a
private bind address, firewall and protected proxy-to-app connection require deliberate
configuration; changing `HOST` to `0.0.0.0` alone exposes the unencrypted backend.

Do not enable Caddy `debug`, request-body logging, or access logs containing request headers
or query strings. Default redaction does not necessarily cover the custom
`X-When-Reset-Server-Key` header. The examples omit the `log` directive. Review any inherited
proxy, CDN, firewall or tracing rules separately; application logging settings cannot control them.

## Changing the hostname or network

Rerun the installer with the new `--origin` and update DNS/TLS together. Passkeys are scoped
to the hostname: unlock the new hostname with the recovery key and enroll a new passkey.
Update the app's linked server configuration. Keep the credential encryption key unchanged.

If your ISP changes its public address, the installer cannot prevent it. Use a static address
or a fixed egress gateway under your control. Merely adding dynamic DNS fixes discovery,
not source-IP stability. Accounts that still refresh locally use the device's network.
