# Security policy

## Reporting a vulnerability

Please report security issues privately through GitHub: open the **Security** tab of this repository and choose
**Report a vulnerability** (GitHub private vulnerability reporting / security advisories).
Do not open a public issue for security problems.

Include what you found, how to reproduce it, and the affected version. You can expect an acknowledgement within a
few days. This is a personal project maintained on a best-effort basis; fixes are released as soon as practical.

## Scope notes

- Pairing credentials are stored in `~/Library/Application Support/Télécommande Apple TV/pyatv.conf` (mode 0600).
  Never attach this file to a report.
- Releases are ad-hoc signed and not notarized. Verify the SHA-256 checksum published with each release.
