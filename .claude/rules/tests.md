---
paths:
  - test/**
  - integration_test/**
---

# Tests

- Use made-up names, dates and values, or the demo family in `lib/demo_seed.dart`. Fixtures in `integration_test/fixtures/` must be synthetic.
- Report parsing tests print lines as labs do, including `2,50,000` style counts and mixed units, and check the result after conversion.
- Test code that takes a date with a fixed date, not `DateTime.now()`, and cover month ends, leap years and time zones where they matter.
- `test/` runs without a device, on CI. Anything needing a plugin, OCR or the keychain goes in `integration_test/`, which CI does not run. Say so when a change is only covered there.
- Shared on-device helpers are in `integration_test/harness.dart`.
