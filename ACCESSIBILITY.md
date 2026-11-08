# Accessibility

You should be able to read test results without relying on terminal status
indicators. Use rspec-osc7501 alongside an RSpec text formatter so failures and
the suite summary remain available as text.

## Text output

For example descriptions and results without color or OSC status output, run:

```sh
RSPEC_OSC7501=off bundle exec rspec --format documentation --no-color
```

`RSPEC_OSC7501=off` also disables status output when your RSpec configuration
selects the OSC formatter. By default, the OSC formatter emits nothing to
non-TTY streams, so redirected output does not contain its status records.

## Environments and limits

The gem supports MRI Ruby 3.3 or newer and RSpec Core 3.12 through 3.x. Terminal
status requires an OSC 7501-capable terminal. The terminal controls how it
displays or announces status, including through assistive technology.

I have not verified the status display with screen readers. Use the text
output above if status updates are inaccessible or distracting.

## Report a barrier

Open an [issue](https://github.com/cosgroveb/rspec-osc7501/issues) describing what
you tried, what prevented you from using it, and what would help. Include your
terminal, operating system, and assistive technology versions when relevant.
You do not need to disclose a disability or other medical information.
