# Contributing

Use MRI Ruby 3.3 or newer. Install dependencies and run specs:

```sh
bundle install
bundle exec rake spec
```

Keep runtime dependencies limited to `rspec-core`. Cover formatter behavior with
specs and lifecycle changes with real RSpec subprocesses. Check RSpec 3.12 and
3.13 when changing early-stop detection.

Build the gem and documentation:

```sh
bundle exec rake package
bundle exec rake rdoc
```

The package is `pkg/rspec-osc7501-0.1.0.gem`. Open `tmp/rdoc/index.html` to check
rendered documentation. Keep generated files out of commits.

Update usage or behavior documentation for user-visible changes and add a brief
entry under `Unreleased` in `CHANGELOG.md`. Preserve the Apache-2.0 license text.
