---
paths:
  - lib/services/ai/**
  - test/ai_*
  - integration_test/ai_flow_test.dart
---

# AI reading

- Provider replies are untrusted input. A malformed reply is asked for once more, then discarded whole.
- The prompt asks for strings as printed. Never have the model calculate, convert or normalize. That belongs in the deterministic code shared with on-device reading.
- Every value is cross-checked against an independent reading (PDF text or OCR, plus the heuristic parser). Keep the row states: confirmed, on the page but not tied to the row, not found, in conflict, unreadable, not checkable.
- Failures never lose work. The original is stored first and on-device values stay on screen.
- Retry busy, rate-limit and network errors with backoff, honouring `Retry-After` up to 30 seconds. Don't retry bad keys, missing models or billing errors.
- API keys go in the system keychain only. Never log them or put them in backups, and strip them from error text. The tests check this.
- A cloud provider asks for agreement once before its first document. Plain http is allowed only to private addresses.
- Default model names are in `README.md` as well as the code. Change both.
