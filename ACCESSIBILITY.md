# Accessibility

You should be able to read test results without relying on terminal status
indicators. Use rspec-osc7501 alongside an RSpec text formatter so failures and
the suite summary remain available as text.

## Plain text output

Run this for example descriptions and results without color or terminal status:

```sh
RSPEC_OSC7501=off bundle exec rspec --format documentation --no-color
```

`--no-color` disables RSpec's text colors. `RSPEC_OSC7501=off` disables this
gem's status records, even when your RSpec configuration selects the formatter.

By default, the formatter sends no status records to pipes or files.
`RSPEC_OSC7501=force` overrides that default.

## Environments and limits

The gem supports MRI Ruby 3.3 or newer and RSpec Core 3.12 through 3.x.
Terminal status requires an OSC 7501-capable terminal. The formatter checks
for a TTY but does not detect OSC support or check `TERM`.

Your terminal controls how it displays or announces status. I have not tested
the status display with screen readers. The command above gives you plain text,
but your screen reader may need other settings.

## Report a barrier

Open an [issue](https://github.com/cosgroveb/rspec-osc7501/issues) describing what
you tried, what prevented you from using it, and what would help. Include your
terminal, operating system, and assistive technology versions when relevant.
You do not need to disclose a disability or other medical information.
