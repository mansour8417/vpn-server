# Maintainer Handoff

## Project scope

This repository contains a standalone Xray VLESS + XTLS-Vision + REALITY installer
and an optional Hyper-V provisioning helper. It can be used on a dedicated VPS
or an isolated home-server VM. It does not configure an existing panel deployment.

## Files

| File | Purpose |
|---|---|
| `install.sh` | Fresh Linux installation and embedded `vpn` management command |
| `New-VpnVM.ps1` | Hyper-V VM creation and Ubuntu installer boot |
| `README.md` | English setup, usage, and maintenance guide |
| `SECURITY.md` | Security findings, migration guidance, and review limitations |
| `tests/test_security.py` | Isolated regression checks without changing a server |

## Deployment work remaining

1. Exercise the revised installer on a disposable Ubuntu/Debian VM with console
   access and no production credentials.
2. Verify firewall behavior with SSH Include files and existing UFW rules.
3. Test a real client/server tunnel, user creation/revocation, and service recovery.
4. Execute the Hyper-V helper on a Windows test host; validate ISO failure paths,
   the External switch, Secure Boot, networking, and reboot behavior.
5. Verify that the VPN host cannot reach local, management, or metadata networks
   using IPv4, IPv6, DNS names, and the actual target network's isolation rules.

## Operational details

- Use the Linux Secure Boot template `MicrosoftUEFICertificateAuthority`.
- An External Hyper-V switch gives the guest LAN connectivity; creating it can
  briefly disconnect the host. Use a local console when possible.
- Prefer TCP/443, and validate the SNI from the actual client network.
- Keep credentials, client links, configuration, and backups out of Git.
- Never source runtime metadata as root or give the service ownership of its
  configuration directory.
- Do not run the fresh installer over an existing server.

## Release status

This source distribution has a fresh history and contains no live deployment
configuration. It is experimental; retain the validation limits documented in
SECURITY.md when describing or extending it.
