# Personal VPN Server — Xray + VLESS + REALITY

**Experimental setup kit — review and test on an isolated VM before deployment.**

A small, self-hosted Xray setup using **VLESS + XTLS-Vision + REALITY**.
Run it on a dedicated Ubuntu/Debian server or an isolated Linux VM. An optional
PowerShell script creates an Ubuntu VM on a Windows Hyper-V host.

REALITY does not require you to obtain a TLS certificate or own a domain for
the VPN listener. A DNS name is still useful if your server's public IP changes.
It uses a separate TLS target (the SNI hostname). Reachability and resistance to
filtering depend on the network and target; no IP, protocol, or SNI is unblockable.

> Existing installation? Read [SECURITY.md](SECURITY.md) first. Older revisions
> contain unsafe metadata handling and an unsafe updater. This installer refuses
> to overwrite an existing installation, and automatic updates are disabled.

## Requirements

- A dedicated Ubuntu 22.04+ or Debian 12+ system with systemd and apt.
- Root access and a working OpenSSH server. Keep console access available while
  changing firewall rules.
- An available TCP port (443 by default), reachable from clients. For a home VM,
  reserve its LAN address and forward the router's TCP/443 port to that address.
- An isolated network segment that cannot reach your household or management
  devices. The application-level private-address rules are defense in depth,
  not a substitute for network isolation.

## Install

Download and inspect `install.sh` from this repository, then copy it to your
new server. Do not pipe downloaded scripts directly into a root shell.

```bash
scp install.sh operator@SERVER_IP:~/install.sh
ssh operator@SERVER_IP
sudo bash ~/install.sh
```

The installer:

- Downloads the tested Xray v26.3.27 release for x86-64, ARM64, or ARMv7 and checks its
  SHA256 against the release's checksum file. This trusts GitHub and the upstream
  publisher; it is not an independent signature verification.
- Selects the first candidate SNI that passes a TLS 1.3 / HTTP/2 probe, or verifies
  the hostname you supply. A successful server-side probe does not prove that
  the target works from a filtered client network.
- Generates a fresh REALITY key pair, user UUID, and short ID.
- Creates a restricted, non-root systemd service. Root owns its configuration;
  the service account can read it but cannot change it.
- Preserves existing UFW rules, adds the effective SSH listening ports and the
  VPN port, and sets incoming-deny/outgoing-allow defaults. Review pre-existing
  rules: preserved rules can still expose other services.
- Enables clock synchronization and attempts BBR/network tuning.
- Prints an `admin` client link and QR code. Treat both as credentials.

```bash
sudo bash install.sh --sni www.asus.com
sudo bash install.sh --host vpn.example.com
sudo bash install.sh --port 8443
sudo bash install.sh --allow-torrent
```

`--host` accepts a DNS hostname or IPv4 address for client links. Literal IPv6
addresses are not supported by this helper. Prefer TCP/443 unless you have a
reason to use a different port; unusual ports can make traffic more distinctive.
Torrent blocking is a best-effort protocol filter, not a guarantee.

## Manage users

```bash
sudo vpn add alice       # Create a user and print a link and QR code
sudo vpn list            # List user names and UUIDs (sensitive)
sudo vpn link alice      # Show that user's link again
sudo vpn del alice       # Revoke a user
sudo vpn status          # Show service and listener status
sudo vpn log 100         # Show the last 100 journal lines
```

Names may contain spaces when quoted, but must be 1–64 characters without
control characters. Each user gets a UUID and a short ID; deleting a user removes
both entries while preserving the remaining pairings. The initial `admin` user
cannot be removed using this command. It is a VPN client, not an OS administrator.

Configuration changes are serialized with a lock and validated before replacing
the active file. If restarting the service fails, the previous configuration is
restored and a recovery restart is attempted.

`vpn update` deliberately exits with instructions rather than executing a remote
script. See the [manual update procedure](SECURITY.md#manual-xray-updates).

## Connect a client

Use a maintained client that explicitly supports VLESS, REALITY, and
`xtls-rprx-vision`. Import the `vless://` link or scan the QR code privately.
Verify that an HTTPS request actually passes through the server; an app showing
“Connected” is not sufficient. Client versions and network filtering can affect
compatibility.

## Optional Windows Hyper-V VM

Enable Hyper-V and run PowerShell as Administrator:

```powershell
.\New-VpnVM.ps1
```

Defaults: a Generation 2 VM named `vpn`, 2 vCPUs, 2 GB RAM, a 20 GB disk, and
Ubuntu Server 26.04.1. The downloaded ISO is checked against a pinned SHA256
from [Ubuntu's checksum list](https://releases.ubuntu.com/26.04/SHA256SUMS).
For a custom ISO, obtain its checksum from a trusted publisher first:

```powershell
.\New-VpnVM.ps1 -IsoPath D:\iso\ubuntu-server.iso -IsoSha256 '<trusted-64-character-sha256>'
```

Creating an External switch can interrupt the Windows host's network connection,
including RDP. The script asks before creating one. An existing non-External
switch is rejected. The Linux Secure Boot template is selected explicitly.

After the VM boots:

1. Open its console in Hyper-V Manager and complete Ubuntu installation.
2. Enable **Install OpenSSH server** and configure your administrator account.
3. Reserve the printed MAC address in your router's DHCP settings.
4. Put the VM on an isolated network and forward only the VPN TCP port to it.
5. Copy `install.sh` into the VM and follow the Linux installation steps above.

**The Hyper-V workflow has not been executed as part of this review.** Do not
interpret syntax or code review as proof of a successful Windows deployment.

## Home server or VPS

A home server needs an inbound-reachable public address, router port forwarding,
and sufficient upload capacity. Compare the router's WAN address with the address
reported by an external IP service. A mismatch can indicate CGNAT or another NAT
layer; investigate with your ISP. Residential addresses can also be blocked.
Client traffic exits through the host's connection.

A VPS avoids reliance on home power and upload speed but has its own cost,
provider limits, and reachability constraints. Measure latency and throughput
from the actual client network. A relay adds another hop and does not remove
filtering on the international leg. No fixed performance or availability claims
are made here.

For dynamic addresses, configure DDNS and use `--host vpn.example.com` during
installation. The dial address and SNI are different settings.

## Maintenance and backups

Generated state lives in `/usr/local/etc/xray/`. `config.json` contains private
key material and user credentials; `server.env` contains client-link metadata.
Do not commit either file, QR exports, logs, or backups.

```bash
sudo sh -c 'umask 077; tar czf /root/xray-backup.tgz -C /usr/local/etc xray'
```

Store backups securely off-server. Restoring also requires compatible Xray
binaries/assets, the service unit, firewall rules, and correct file ownership;
a configuration backup alone is not a complete system backup.

To change the dial address, use `sudoedit /usr/local/etc/xray/server.env` and edit
only `SERVER_IP=...`, then regenerate client links with `sudo vpn link NAME`.
To change the SNI, back up the state and update `target` and `serverNames` in
`config.json` and `SNI` in `server.env` together. Validate with
`sudo /usr/local/bin/xray run -test -config /usr/local/etc/xray/config.json`, restart
Xray, and distribute updated links. Do not rerun the installer to change settings.

## Validation status

Historical notes reported a tunnel test using Xray v26.3.27 and a separate live
panel-based deployment. Those reports do **not** validate this revised installer.
This release passed 14 isolated regression tests, ShellCheck, PowerShell parsing,
and a real loopback Xray v26.3.27 client/server HTTPS tunnel test. A direct loopback
destination was blocked by the proxy rules. Full Linux installation and Hyper-V
provisioning remain untested; see [SECURITY.md](SECURITY.md).

## License

[MIT](LICENSE).
