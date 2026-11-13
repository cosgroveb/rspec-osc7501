# Accessibility

Read test results without relying on terminal status indicators. Use
rspec-osc7501 alongside an RSpec text formatter so failures and
the suite summary remain available as text.

## Plain text output

Run this for example descriptions and results without color or terminal status:

```sh
RSPEC_OSC7501=off bundle exec rspec --format documentation --no-color
```

`--no-color` disables RSpec's text colors. `RSPEC_OSC7501=off` disables this
gem's status records, even when your RSpec configuration selects the formatter.

By default, the formatter sends no status records to redirected streams or to
terminals with `TERM=dumb`. `RSPEC_OSC7501=force` overrides those defaults.

## Environments and limits

The gem targets MRI Ruby 2.1 or newer and RSpec Core 3.6 or newer.
Terminal status requires an OSC 7501-capable terminal. The formatter checks
for a TTY and honors `TERM=dumb` but does not detect OSC support.

Your terminal controls how it displays or announces status. I have not tested
the status display with screen readers. The command above gives you plain text,
but your screen reader may need other settings.

## Report a barrier

Open an [issue](https://github.com/cosgroveb/rspec-osc7501/issues) describing what
you tried and what would help. Include your terminal and assistive
technology versions when relevant.
You do not need to disclose a disability or other medical information.
