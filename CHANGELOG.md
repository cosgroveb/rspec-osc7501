# Changelog

## Unreleased

- Bound text sanitization input to 150% of each field's output byte limit.
- Ignore caller exceptions already active when the suite starts.
- Report failures for zero and negative fail-fast thresholds.
- Flush status frames when supported and accept streams without TTY detection.

## 0.1.0 - 2026-11-07

- Add an opt-in OSC 7501 formatter for RSpec suite progress and outcomes.
- Support TTY detection, explicit output capture, and a configurable suite title.
