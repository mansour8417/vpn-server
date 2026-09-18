# Security Review and Operations

## Review status — 2026-09-17

**Experimental source release, not a production security certification.**
The English source distribution contains no live deployment configuration and
has a fresh Git history. Identified source-level hazards have been fixed and
the checks below passed. Full Linux/Hyper-V deployment validation remains.
No live server has been modified by this review.

## Findings addressed in this revision

| Finding | Change |
|---|---|
| The root manager sourced `server.env` as shell code; the Xray account owned the metadata and its directory | Parse an allowlisted set of data fields, validate values, reject unsafe ownership/symlinks, and keep configuration root-owned |
| `vpn update` downloaded and ran a mutable upstream shell script as root | Disable that update path; require a staged manual update |
| Raw host/port/SNI values could corrupt JSON, metadata, or links | Validate inputs before privileged side effects and validate metadata before use |
| Re-running the installer silently regenerated keys and replaced users | Refuse an existing configuration, directory, or service |
| UFW was reset and SSH ports were inferred from only one file | Preserve rules and obtain all effective ports using `sshd -T`, including Include directives |
| User changes replaced active configuration before validation, without serialization or recovery | Lock management operations, validate candidates, use same-directory replacement, and restore configuration after restart failure |
| Generated files could inherit a permissive umask | Set umask 077; use root:xray 0640 for config and root:root 0600 for metadata |
| A custom Hyper-V ISO bypassed checksum verification | Require a trusted SHA256 for custom images and verify before switch/VM creation |
| Current documents exposed personal deployment details and made unsupported blocking/performance guarantees | Replace them with general English operational guidance and explicit limits |

The previous systemd service used `ProtectSystem=strict`, which limits writes
from that service's mount namespace. This does not make sourcing a service-owned
file as root safe: another process running as that account, or a changed service
sandbox, can still make those ownership choices dangerous.

## Existing installations

Updating repository files does not patch a previously installed `vpn` command or
service. Do not run the old manager or its updater on untrusted state. The fresh
installer intentionally refuses to migrate in place.

For an existing deployment, use a maintenance window and trusted administrator:

1. Back up configuration and inspect it as data, without sourcing `server.env`.
2. Check for unexpected processes, ownership changes, and configuration edits.
   If compromise is suspected, rebuild from a clean OS and rotate credentials.
3. Prefer a fresh, isolated VM and generate new client credentials using the
   revised installer after its deployment checks have passed.
4. Test access from the actual client networks, migrate users, and retire the
   old endpoint. Avoid running two services on the same port.

If preserving existing keys is necessary, that is a separate migration task:
review the data, restore root ownership and permissions, and deploy the revised
manager/service with rollback. Do not blindly chown and execute existing files.

## Manual Xray updates

Do not use `curl | bash` or execute a downloaded installer as root.

1. Review the official [Xray releases](https://github.com/XTLS/Xray-core/releases)
   and choose an explicit version for your architecture.
2. Download the archive and checksum from that release, inspect the filenames,
   and verify the checksum before extracting into a private staging directory.
   A checksum from the same source detects corruption but still trusts the source.
3. Back up the current binary, assets, configuration, and service unit securely.
4. Test the staged binary and assets against a copy of the configuration on a
   disposable system. Complete a real tunnel test before a production rollout.
5. During a maintenance window, replace the binary/assets without changing user
   credentials or the service's ownership model. Restart and check traffic.
6. Restore the previous binary/assets if validation or traffic checks fail.

This repository does not automatically migrate configuration across upstream
releases. The fresh installer is pinned to Xray v26.3.27, the version used for the tunnel
test. Review upstream security updates and validate newer versions before
changing that pin.

## Network isolation remains required

The supplied Xray rules block known private addresses and private domain entries.
These are application-level rules, not proof that DNS rebinding, all special-use
addresses, or management networks are inaccessible. DNS resolution and routing
behavior must be validated on the selected Xray version; see the upstream
[routing](https://xtls.github.io/en/config/routing.html) and
[Freedom](https://xtls.github.io/en/config/outbounds/freedom.html) documentation.

Place the VM in an isolated network with firewall-enforced restrictions on access
to LAN devices, loopback/host services, link-local/cloud metadata endpoints, and
management networks, for both IPv4 and IPv6. Test those restrictions with IP
literals and DNS names. The Hyper-V helper alone does not establish that isolation.
Do not expose an unreviewed home-server installation to untrusted users.

## Validation performed

Run from the repository root with Python 3, Bash, jq, and OpenSSL available:

```bash
python3 tests/test_security.py
```

The 14 isolated regression tests pass, covering shell syntax, malformed input,
metadata injection rejection, ownership/mode/symlink rejection, user lifecycle and
short-ID pairing, failed candidate validation, restart rollback, refusal to
reinstall, disabled remote updates, and absence of Persian text in the current
source tree.

The manager tests redirect all paths to temporary directories and simulate root
ownership, Xray, systemd, and flock. They do not prove operating-system permission
or locking behavior, Xray configuration compatibility, or network isolation.
Bash syntax checking and ShellCheck v0.11.0 passed for the installer and embedded
manager. PowerShell 7.6.6 parsed the Hyper-V script without errors. An unprivileged
Xray v26.3.27 server/client test on macOS validated the generated configuration,
carried an HTTPS request through REALITY, and blocked a direct loopback destination.
The default Ubuntu ISO hash was checked against
[Ubuntu's published checksums](https://releases.ubuntu.com/26.04/SHA256SUMS).

Not performed: a privileged Linux install, PowerShell execution/Hyper-V
provisioning, comprehensive DNS-rebinding/egress tests,
a comprehensive upstream dependency vulnerability audit, or a production review.
These must be completed before treating the installer as deployment-ready.

## Repository publication and secrets

This repository is a fresh source export. It does not import earlier private
deployment history. The license and public GitHub account attribution are retained.

No obvious embedded private key, token, server IP, or generated client credential
was identified in the reviewed source files. Gitleaks v8.30.1 also scanned the complete release source with no leaks found.
Neither a scanner nor this scoped manual review provides a security certification. Gitignore rules prevent
some accidental additions; they do not remove previously committed data.

Keep runtime configuration, client URLs/QR codes, private keys, logs, and backups
out of the repository. If a secret is ever committed, rotate it; deleting it from
the latest revision is not enough. Do not post credentials or private deployment
details in public issues.
