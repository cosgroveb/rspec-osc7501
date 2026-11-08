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

The package is `pkg/rspec-osc7501-<version>.gem`. Open `tmp/rdoc/index.html` to check
rendered documentation. Keep generated files out of commits.

Update usage or behavior documentation for user-visible changes. Write commit
subjects that describe the change, because release notes use those subjects.
Do not maintain `Unreleased` entries by hand. Preserve the Apache-2.0 license text.

## Release

Release the reviewed commits on remote `main` with an explicit stable version:

```sh
gh workflow run release.yml --ref main -f version=0.1.1
```

The workflow captures `main`, updates `VERSION`, and generates CHANGELOG bullets
from non-merge commit subjects since the previous release tag. It preserves
older changelog sections and uses the same notes for the GitHub Release.
Versions must use `major.minor.patch` without a `v` prefix or prerelease suffix.
A new version must exceed the current version and include new commits.

The full CI matrix tests the prepared release commit before the workflow pushes
it and its tag together. If `main` advances during testing, the workflow stops.
After the push, it publishes to RubyGems, then creates the GitHub Release. No
intermediate approval is required.

### One-time publishing setup

On the gem's RubyGems page, configure a Trusted Publisher with owner `cosgroveb`,
repository `rspec-osc7501`, and workflow `release.yml`. Leave the environment
blank. The workflow uses short-lived OIDC credentials, with no RubyGems token
stored in GitHub secrets. Repository Actions permissions must permit the
workflow's `contents: write` and `id-token: write` requests.

### Failed releases

Inspect the run and its publication summary:

```sh
gh run list --workflow release.yml
gh run view <run-id> --log-failed
```

RubyGems publication is the release. A later GitHub Release failure leaves the
workflow failed but does not undo the published gem. Rerun the same version to
finish missing steps:

```sh
gh workflow run release.yml --ref main -f version=0.1.1
```

When the tag exists, the workflow uses that exact commit and recorded notes,
verifies matching publications, and skips completed steps. It does not move
tags, replace published gems, or retry automatically. If the retry fails,
inspect the logs before trying again.
