# rspec-osc7501

Report RSpec suite activity, progress and results to terminals that support
[OSC 7501](https://www.superlogical.com/rex/docs/build/program-status).
Use the formatter alongside RSpec’s progress or documentation formatter.

Requires MRI Ruby 3.3 or newer and `rspec-core >= 3.12, < 4`.

## Install

This gem is unreleased. Add the source branch to your Gemfile:

```ruby
group :test do
  gem "rspec"
  gem "rspec-osc7501",
      git: "https://github.com/cosgroveb/rspec-osc7501",
      branch: "feature/osc7501-formatter"
end
```

Run `bundle install`.

## Run

Run your specs in a terminal that supports OSC 7501:

```sh
bundle exec rspec --require rspec/osc7501 \
  --format progress --format RSpec::OSC7501::Formatter
```

Keep `--format progress` to retain RSpec’s dots, failures and summary. The OSC
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
| `RSPEC_OSC7501` | `auto` emits to a TTY, `off` disables output, `force` permits redirected output | `auto` |
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
- [Changelog](CHANGELOG.md).

Licensed under [Apache License 2.0](LICENSE).
