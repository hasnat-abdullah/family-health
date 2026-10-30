---
name: add-lab-test
description: Add a lab test, a printed alias, a unit conversion or a new report format to the on-device reader. Use when a test isn't recognised or a report reads wrongly.
argument-hint: <test name, or a description of the report>
---

# Add a lab test or report format

The input may be a real report. Copy only its format: use made-up names, values and labs in everything you write, and don't quote it into code, commits or issues.

1. Write the failing test first, in `test/report_parser_test.dart`, with lines as a lab prints them. Use `ReportParser(sex: ...).parse([...])`, and check `testKey`, the value after conversion, the unit and the range.
2. Add to `labCatalog` in `lib/data/lab_catalog.dart`, in the right panel:
   - `key`: stable and lower-case. It's stored in people's records, so never rename one.
   - `aliases`: lower-case, as labs print them, including abbreviations and spellings like `haemoglobin`.
   - `unit`: the canonical unit, so trends stay comparable.
   - `range`, or `female` and `male`: general adult values from a mainstream reference. Leave them out rather than guess.
   - `scale`: `ScaleRule`s for other units or scales. Check a real conversion factor, and that the rule can't fire on a value already in the canonical unit.
3. Check aliases don't collide: a short alias like `hb` must not match inside another test's row. Add a test for any near neighbour.
4. If the layout itself is new, change `lib/services/report_parser.dart` as little as possible, and run the whole parser test file.
5. If the count in `README.md` under "Things to know" no longer holds, update it.
6. Run `tool/check.sh`.
