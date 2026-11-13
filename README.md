# rspec-osc7501

Report RSpec suite progress and results to terminals that support
[OSC 7501](https://www.superlogical.com/rex/docs/build/program-status).
Requires MRI Ruby 2.1 or newer and `rspec-core >= 3.6`.

## Install

```ruby
group :test do
  gem "rspec"
  gem "rspec-osc7501", "~> 0.1"
end
```

## Run your specs in a terminal that supports OSC 7501:

```sh
bundle exec rspec --require rspec/osc7501 \
  --format progress --format RSpec::OSC7501::Formatter
```

Keep `--format progress` to see RSpec's dots and summary. Requiring
`rspec/osc7501` registers the formatter without selecting it.

## Configure

| Environment variable | Values | Default |
| --- | --- | --- |
| `RSPEC_OSC7501` | `auto` emits to a TTY unless `TERM=dumb`, `off` disables output, `force` overrides both checks | `auto` |
| `RSPEC_OSC7501_TITLE` | Title for the suite's status records | `RSpec` |

## Documentation

- [Usage recipes](doc/usage.rdoc): persistent configuration and output routing.
- [Behavior and limits](doc/behavior.rdoc): terminal states and concurrency.
- [Contributing](CONTRIBUTING.md), [accessibility](ACCESSIBILITY.md), [security](SECURITY.md), [code of conduct](CODE_OF_CONDUCT.md), [changelog](CHANGELOG.md)

Licensed under [Apache License 2.0](LICENSE).
