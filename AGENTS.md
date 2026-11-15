# Project guide

`rspec-osc7501` is an opt-in RSpec formatter for OSC 7501 terminal status.
Target MRI Ruby >= 2.1 and `rspec-core` >= 3.6.

- `lib/rspec/osc7501.rb` loads and registers the formatter.
- `lib/rspec/osc7501/` holds implementation and version.
- `spec/` covers protocol encoding, formatter events, and real RSpec runs.
- `doc/` holds usage recipes and behavior reference.

Install development dependencies with `bundle install`. Run:

```sh
bundle exec rake spec
bundle exec rake package
bundle exec rake rdoc
```

The gem goes in `pkg/`. RDoc goes in `tmp/rdoc/`.

Pre-1.0, no API-stability promise. Two interfaces: the Ruby API
(formatter registration and preserved RSpec behavior) and the emitted
escape sequences, which consumers parse. OSC 7501 frames must keep
conforming. Patch for fixes, minor for new behavior including added
sequences; removing or changing sequences is breaking.

Release with `script/release.rb prepare <version> <dir>`, build the gem,
then `publish <dir> <gem>`: the script handles the tag, the atomic main+tag
push, the RubyGems push and the GitHub release, then verifies the published
gem. If a release fails, inspect the logs and rerun the same version to finish missing steps.

I prefer ff-only merges for single-commit PRs and squash merges for larger changes.
Rebase single-commit PRs when needed to fast-forward. Use git first, gh if needed.

Preserve these contracts:

- Requiring the library registers the formatter without selecting it.
- Honor RSpec's output stream. Default to silence on non-TTY streams.
- Keep state per formatter instance and preserve RSpec's exit status.
- Keep OSC frames bounded, sanitize text, and handle stream errors at the writer.
- Emit one final result and leave caller-owned streams open.
- Isolate access to RSpec's private early-stop flag and cover supported versions.

Keep changes within the formatter. Worker aggregation, terminal queries, signal
handlers, and process-wide exit hooks are out of scope. Do not commit built gems,
generated HTML, lockfiles, or local bundle state. Preserve `LICENSE` verbatim.

## PR writing requirements

These requirements override general writing guidance unless Brian
explicitly requests otherwise.

- Read and apply `my-voice` with its core and PR-description references
  before drafting or revising, then apply `stop-slop` to the final text.
- Use ASCII only in titles and descriptions.
- Write one short sentence per template section.
- Include exact numbers only when they affect the reader's decision,
  such as compatibility versions or operational limits.
- Summarize verification by outcome rather than listing test counts
  or command transcripts.
- Before submitting, check the exact title and body against these
  requirements and correct any violations.
