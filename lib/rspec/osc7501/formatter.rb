# frozen_string_literal: true

require 'English'

module RSpec
  # Reports RSpec suite status through OSC 7501 terminal records.
  module OSC7501
    # RSpec formatter for suite progress and final results.
    # Select alongside an ordinary formatter to retain RSpec's text output.
    class Formatter
      RSpec::Core::Formatters.register self, :start, :example_started, :example_passed,
                                       :example_failed, :example_pending, :dump_summary, :close

      # Writes status to RSpec's +output+ stream without closing it.
      # Reads RSPEC_OSC7501 and RSPEC_OSC7501_TITLE at construction.
      # The optional +clock+ callable returns monotonic seconds for throttling.
      def initialize(output, clock: -> { Process.clock_gettime(Process::CLOCK_MONOTONIC) })
        @writer = Writer.new(output, mode: ENV.fetch('RSPEC_OSC7501', 'auto'),
                                     title: ENV.fetch('RSPEC_OSC7501_TITLE', 'RSpec'), id: ENV['RSPEC_OSC7501_ID'])
        @clock = clock
        @started = false
        @summarized = false
      end

      # Starts suite progress from the example count in +notification+.
      def start(notification)
        @inherited_exception = $ERROR_INFO
        @started = true
        @total = notification.count
        @completed = @failed = @pending = 0
        @current = nil
        @last_update = @clock.call
        message = "Running #{@total} examples"
        message += ' (dry run)' if RSpec.configuration.dry_run
        @writer.emit(state: 'working', msg: message, progress: progress)
      end

      # Sets the current example description and attempts a throttled update.
      def example_started(notification)
        @current = notification.example.full_description
        update
      end

      # Counts a passed example as completed and attempts a throttled update.
      def example_passed(_notification)
        @completed += 1
        update
      end

      # Counts a failed example as completed and attempts a throttled update.
      def example_failed(_notification)
        @completed += 1
        @failed += 1
        update
      end

      # Counts a pending example as completed and attempts a throttled update.
      def example_pending(_notification)
        @completed += 1
        @pending += 1
        update
      end

      # Emits the final state and counts from RSpec's summary.
      # Final output bypasses throttling and omits progress.
      def dump_summary(notification)
        active_exception = $ERROR_INFO
        active_exception = nil if active_exception.equal?(@inherited_exception)
        @summarized = true
        state = final_state(notification, active_exception)
        outcome = { 'done' => 'Completed', 'error' => 'Failed', 'idle' => 'Stopped' }.fetch(state)
        message = "#{outcome}: #{notification.totals_line} in #{notification.formatted_duration}"
        message += ' (dry run)' if RSpec.configuration.dry_run
        @writer.emit(state: state, msg: message)
      end

      # Reports an incomplete run if it started without reaching a summary.
      def close(_notification)
        return if @summarized || !@started || @closed

        @closed = true
        @writer.emit(state: 'error', msg: "Incomplete: #{@completed}/#{@total} examples")
      end

      private

      def update
        now = @clock.call
        return if now - @last_update < 0.1

        message = "#{@completed}/#{@total} examples"
        message += ", #{@failed} failures" if @failed > 0
        message += ", #{@pending} pending" if @pending > 0
        message += ": #{@current}" if @current
        @writer.emit(state: 'working', msg: message, progress: progress)
        @last_update = now
      end

      def progress
        return if @total.zero?

        [[(@completed * 100) / @total, 0].max, 100].min
      end

      def final_state(summary, active_exception)
        return 'idle' if active_exception.is_a?(Interrupt)
        return exit_state(summary, active_exception) if active_exception.is_a?(SystemExit)
        return 'error' if active_exception || summary.errors_outside_of_examples_count > 0
        return stopped_state(summary) if early_stop?

        unsuccessful_summary?(summary) ? 'error' : 'done'
      end

      def exit_state(summary, exception)
        failed = summary.failure_count > 0 || summary.errors_outside_of_examples_count > 0
        exception.status.zero? && !failed ? 'idle' : 'error'
      end

      def stopped_state(summary)
        fail_fast_reached?(summary.failure_count) ? 'error' : 'idle'
      end

      def unsuccessful_summary?(summary)
        summary.failure_count > 0 || (summary.example_count.zero? && RSpec.configuration.fail_if_no_examples)
      end

      # RSpec has no public early-stop event in supported 3.x versions.
      def early_stop?
        RSpec.world.wants_to_quit
      end

      def fail_fast_reached?(failure_count)
        threshold = RSpec.configuration.fail_fast
        threshold = 1 if threshold == true
        threshold.is_a?(Integer) && failure_count >= threshold
      end
    end
  end
end
