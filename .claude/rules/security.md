---
paths:
  - lib/security/**
  - ios/Runner/Info.plist
  - macos/Runner/*.entitlements
  - android/app/src/main/AndroidManifest.xml
  - SECURITY.md
---

# Security-sensitive files

- Don't invent crypto. Use the existing vault, with `cryptography` for AES and PBKDF2 and SQLCipher for the database. Changing iterations or formats must keep old backups and databases readable.
- Keys stay in the system keychain or keystore, and never appear in logs, errors, backups or test fixtures.
- A new permission or entitlement needs a reason a user would accept, and a note in `README.md`. Network entitlements exist only for opted-in AI reading.
- If what's protected changes, update `SECURITY.md`.
- Say in the pull request what could go wrong with the change, and ask for a person to review it.
