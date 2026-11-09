# frozen_string_literal: true

require 'open3'
require 'pty'
require 'tmpdir'
require 'rbconfig'

# Executes an isolated RSpec CLI suite, optionally through a real terminal.
class CLISuite
  def self.run_embedded(exception, body)
    Open3.capture3({ 'RSPEC_OSC7501' => 'force' }, RbConfig.ruby,
                   '-I', File.expand_path('../../lib', __dir__), '-e', embedded_source(exception, body))
  end

  def self.embedded_source(exception, body)
    <<~RUBY
      require "rspec/osc7501"
      require "stringio"
      RSpec.describe("embedded") { it("runs") { #{body} } }
      begin
        raise #{exception}, "caller exception"
      rescue #{exception}
        exit RSpec::Core::Runner.run(["-f", "RSpec::OSC7501::Formatter"], StringIO.new, $stdout)
      end
    RUBY
  end

  def initialize(source, options, settings)
    @source = source
    @options = options
    @settings = settings
  end

  def run
    Dir.mktmpdir('rspec-osc7501-') do |directory|
      File.write(File.join(directory, 'sample_spec.rb'), @source)
      capture(directory)
    end
  end

  private

  def environment
    {
      'BUNDLE_GEMFILE' => File.expand_path('../../Gemfile', __dir__),
      'RSPEC_OSC7501' => @settings.fetch(:mode, 'force'),
      'RUBYLIB' => File.expand_path('../../lib', __dir__)
    }.merge(@settings.fetch(:extra_env, {}))
  end

  def command
    # Interrupt and fail-fast fixtures depend on example order.
    [RbConfig.ruby, '-S', 'bundle', 'exec', 'rspec', '--order', 'defined', '-r', 'rspec/osc7501',
     *formatter_options, '-f', 'progress', *@options, 'sample_spec.rb']
  end

  def formatter_options
    return [] unless @settings.fetch(:formatter, true)

    options = ['-f', 'RSpec::OSC7501::Formatter']
    options += ['--out', @settings[:osc_out]] if @settings[:osc_out]
    options
  end

  def capture(directory)
    if @settings[:tty]
      output, status = PTYCapture.new(environment, command, directory).run
      [output, '', status]
    else
      result = Open3.capture3(environment, *command, chdir: directory)
      file = File.join(directory, 'result.json')
      File.file?(file) ? [*result, File.read(file)] : result
    end
  end
end

# Drains PTY output after exit and bounds hangs while reaping the child.
class PTYCapture
  def initialize(environment, command, directory)
    @environment = environment
    @command = command
    @directory = directory
    @output = +''
    @status = nil
  end

  def run
    @master, @slave = PTY.open
    @pid = Process.spawn(@environment, *@command, chdir: @directory, out: @slave, err: @slave)
    drain
    [@output, @status]
  ensure
    cleanup
  end

  private

  def now
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  def drain
    deadline = now + 15
    @quiet_since = now
    loop do
      read_available
      reap
      break if @status && now - @quiet_since >= 0.2
      raise "RSpec PTY timeout (status=#{@status.inspect}, bytes=#{@output.bytesize})" if now >= deadline
    end
  end

  def read_available
    return unless IO.select([@master], nil, nil, 0.1)

    chunk = @master.read_nonblock(65_536)
    @output << chunk
    @quiet_since = now unless chunk.empty?
  rescue IO::WaitReadable
    nil
  end

  def reap
    return if @status

    waited, result = Process.waitpid2(@pid, Process::WNOHANG)
    @status = result if waited
  end

  def cleanup
    if @pid && !@status
      Process.kill('KILL', @pid)
      Process.waitpid(@pid)
    end
    @master&.close
    @slave&.close
  end
end
