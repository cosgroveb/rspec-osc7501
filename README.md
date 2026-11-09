# rspec-osc7501

Report RSpec suite activity, progress and results to terminals that support
[OSC 7501](https://www.superlogical.com/rex/docs/build/program-status).
Use the formatter alongside RSpec’s progress or documentation formatter.

Requires MRI Ruby 3.3 or newer and `rspec-core >= 3.12, < 4`.

## Install

Add the gem to your Gemfile:

```ruby
group :test do
  gem "rspec"
  gem "rspec-osc7501", "~> 0.1"
end
```

Run `bundle install`.

## Run

Run your specs in a terminal that supports OSC 7501:

```sh
bundle exec rspec --require rspec/osc7501 \
  --format progress --format RSpec::OSC7501::Formatter
```

Keep `--format progress` to see RSpec’s dots, failures and summary. The OSC
formatter reports completed examples and the final suite result through terminal
status records. Requiring `rspec/osc7501` registers the formatter without selecting
it.

To check the emitted records without terminal support, force output through a
pipe:

```sh
RSPEC_OSC7501=force bundle exec rspec --require rspec/osc7501 \
  --format progress --format RSpec::OSC7501::Formatter | cat -v
```

Look for `^[]7501;` records alongside RSpec output. A normal completed run ends
with a `state=done` or `state=error` record.

## Configure

| Environment variable | Values | Default |
| --- | --- | --- |
| `RSPEC_OSC7501` | `auto` emits to a TTY unless `TERM=dumb`, `off` disables output, `force` overrides both checks | `auto` |
| `RSPEC_OSC7501_TITLE` | Title for the suite’s status records | `RSpec` |

The formatter uses the output stream RSpec assigns, including `--out`. Default
mode emits nothing to redirected streams. Use one reporting RSpec process per
terminal. Concurrent processes overwrite the same status record.

Early stops report `idle` unless failure conditions take precedence. Termination
that bypasses formatter callbacks can leave the last status in place. See
[behavior and limits](doc/behavior.rdoc) for classification details.

## Documentation

- [Usage recipes](doc/usage.rdoc): persistent configuration and output routing.
- [Behavior and reference](doc/behavior.rdoc): progress, terminal states and limits.
- [Contributing](CONTRIBUTING.md): development and verification commands.
- [Accessibility](ACCESSIBILITY.md): text output and reporting barriers.
- [Security policy](SECURITY.md): supported releases and private reporting.
- [Code of conduct](CODE_OF_CONDUCT.md): participation and conduct reports.
- [Changelog](CHANGELOG.md).

Licensed under [Apache License 2.0](LICENSE).
