---
name: schema-change
description: Add or change a database table or column, or a field on a record, and carry it through migration, backups, CSV and the UI. Use for any change to what the app stores.
argument-hint: <what needs storing>
---

# Change what the app stores

Existing installs hold people's only copy of their records, and old backups must keep working. Take these in order.

1. **Schema**, in `lib/data/database.dart`:
   - Raise `version`, and add an `if (from < n)` step to `onUpgrade`. Never edit an old step.
   - Make `onCreate` match, so that a new install and an upgraded one are the same.
   - A new column must be nullable or have a `DEFAULT`, for existing rows and for old backups.
2. **New table**:
   - Include `id TEXT PRIMARY KEY` and `updated_at INTEGER NOT NULL`.
   - Add it to `AppDb.tables` in foreign-key order, parents first, since `mergeRows` inserts in that order.
   - `rawRows` filters by `member_id` by default. If the table has no such column, add a case, or single-member exports will fail.
3. **Model**, in `lib/data/models.dart`: update the constructor, `toMap` and `fromMap`. Older rows give `null`, so handle that. Anything that edits a record must set `updated_at`.
4. **Backups**, in `lib/services/backup_service.dart`: raise `formatVersion` if the contents change, so an older app refuses the file instead of misreading it. Files that a row points to must be added to the archive as well.
5. **Elsewhere**: check `lib/services/csv_service.dart`, `lib/demo_seed.dart`, and any AI extraction that fills this field.
6. **Tests**:
   - Extend `a version 2 database upgrades with its records intact` in `integration_test/data_flow_test.dart`, so the upgrade runs from a real old schema with records in it.
   - Cover old-backup import and importing twice.
   - Run the suite on a device with the `on-device` skill: `flutter test integration_test/data_flow_test.dart -d macos`. CI doesn't run it, so `tool/check.sh` alone proves nothing here.
7. Run `tool/check.sh`, then use `review-change`.
