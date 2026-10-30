---
paths:
  - lib/data/**
  - lib/services/backup_service.dart
  - lib/services/csv_service.dart
---

# Data and backups

Use the `schema-change` skill for any change to what the app stores.

- A schema change needs all of these in `lib/data/database.dart`: bump `version`, add an `if (from < n)` step to `onUpgrade`, and update `onCreate` so a new install matches an upgraded one. Never edit an old step, because people have already run it.
- A new table goes in `AppDb.tables`, or backups silently leave it out. It needs `id TEXT PRIMARY KEY` and `updated_at INTEGER NOT NULL`.
- Backups merge by "last edit wins" and importing the same file twice must be safe. Old backups must keep importing after a schema change.
- Deletions don't sync yet. Don't imply that they do.
- Stored files and the database stay encrypted. Don't write decrypted data to a shared or temporary location without removing it afterwards.
- Lab catalog ranges are general adult values. A range printed on the report always takes precedence.
- Tests never touch real data: `AppDb.init` takes a `fileName` for this.
