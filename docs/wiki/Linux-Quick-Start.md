# Linux quick start

This installs When Reset as a systemd service, using a dedicated user and a private Node.js
24 runtime. It supports x86_64 and ARM64 Linux hosts. Use a maintained Debian/Ubuntu or
Fedora/RHEL-family distribution with systemd, sudo/root access and local disk storage.

## 1. Choose the host and HTTPS name

Choose a host whose outbound network you want providers to see. Reserve a static public IP
or use a network with stable NAT egress. Choose an HTTPS hostname such as
`reset.example.com`, reachable by the browsers and Apple devices that will use it.

For a public VPS, point DNS at the VPS. For a private server, use your LAN/VPN DNS and a
certificate trusted by your devices; public inbound access is optional. See
[HTTPS and private networks](HTTPS-and-Private-Networks.md).

## 2. Download, review and run the installer

Run these commands on the Linux host, replacing the example hostname:

```bash
curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
  https://raw.githubusercontent.com/iebb/when-reset/master/server/install.sh \
  -o install-when-reset.sh
less install-when-reset.sh
sudo bash install-when-reset.sh --origin https://reset.example.com
```

The standalone installer downloads the current `master` source. For an audited, fixed
revision, check out the desired commit locally and run its installer instead:

```bash
git clone --branch master https://github.com/iebb/when-reset.git
cd when-reset
# Optionally: git checkout <reviewed-commit>
sudo bash server/install.sh --origin https://reset.example.com
```

The installer verifies the Node archive checksum, builds the app, generates two independent
random keys, initializes SQLite and starts `when-reset.service`. It leaves the system's Node
installation alone. Keys are never printed. DNS, TLS and firewall rules are configured separately.

## 3. Put HTTPS in front of the service

The service listens only on `127.0.0.1:8787`. Install Caddy using its
[official Linux instructions](https://caddyserver.com/docs/install#debian-ubuntu-raspbian),
then add this site to `/etc/caddy/Caddyfile`:

```caddyfile
reset.example.com {
    reverse_proxy 127.0.0.1:8787
}
```

```bash
sudo caddy validate --config /etc/caddy/Caddyfile
sudo systemctl reload caddy
curl --fail https://reset.example.com/healthz
```

For automatic public certificates, DNS must resolve to the server and the certificate
challenge must be reachable. The private-network guide covers other certificate setups.
Do not expose port 8787 or bypass certificate validation. The example does not enable
HTTP access logging; keep headers and bodies out of reverse-proxy logs.

## 4. Unlock the dashboard and link When Reset

In a **private interactive terminal**, display only the dashboard recovery key:

```bash
sudo /opt/when-reset/current/node/bin/node \
  --env-file=/etc/when-reset/server.env \
  /opt/when-reset/current/app/show-access-key.mjs
```

The helper refuses pipes and redirected output. It does not display the credential encryption
key. Avoid terminal recording or screen sharing, and save the dashboard key in a password
manager. Do not paste the environment file into logs, support requests or this wiki.

1. Open your HTTPS hostname and unlock the dashboard with that key.
2. Optionally enroll a passkey under **Dashboard access**. Keep the recovery key separately.
3. Under **Link a device**, create a one-use QR code and scan it with the device, or choose
   **Open When Reset** on that device.
4. Confirm the hostname in When Reset. Some app screens still call the server a “Worker”;
   the Linux HTTPS origin works in those same controls.
5. Enable server monitoring only for the accounts you want to upload. Use the server-backed
   account/subscription for refreshes that should use the server's network.

## 5. Verify monitoring

```bash
sudo systemctl is-active when-reset
curl --fail http://127.0.0.1:8787/healthz
sudo journalctl -u when-reset --since '10 minutes ago' --no-pager
```

The health endpoint should return JSON containing `"ok": true`. After opting in an account, wait for the
next UTC five-minute boundary and check its last successful sample in the dashboard.
Providers can require longer intervals or backoff after errors. Silent notifications depend
on Apple/device delivery and are not proof that a provider check succeeded.

Next: [operations and backups](Operations-and-Backups.md) and
[security and secrets](Security-and-Secrets.md).
