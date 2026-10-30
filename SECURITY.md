# Security

Family Health stores private medical records, so security reports are very welcome.

## Reporting a problem

Please don't open a public issue. Use [private vulnerability reporting](https://github.com/hasnat-abdullah/family_health/security/advisories/new) and include the steps to reproduce it. I aim to reply within a week. Never include real medical records or API keys in a report.

Only the latest release is supported.

## How data is protected

- The database is encrypted with SQLCipher and stored files are encrypted with AES. The key is kept in the system keychain or keystore.
- Backups are encrypted with a password you choose, and never contain AI keys.
- Nothing leaves the device unless you turn on AI reading with a cloud provider. Documents are then sent to that provider under your own API key, and its privacy terms apply.

## What it doesn't protect against

- Someone with your unlocked device, or malware running as your user.
- A forgotten backup password: backups can't be recovered without it.
- Tampered downloads. Release files are built by GitHub Actions and listed in `SHA256SUMS.txt`, but the macOS and iOS builds are not signed by Apple, so check the checksums or build from source if that matters to you.
