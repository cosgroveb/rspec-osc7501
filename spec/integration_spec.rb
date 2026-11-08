# frozen_string_literal: true

require "spec_helper"
require "open3"
require "pty"
require "tmpdir"
require "rbconfig"
require "json"

RSpec.describe "RSpec CLI integration" do
  def run_suite(source, *options, mode: "force", tty: false, osc_out: nil, formatter: true, extra_env: {})
    Dir.mktmpdir("rspec-osc7501-") do |directory|
      File.write(File.join(directory, "sample_spec.rb"), source)
      environment = {
        "BUNDLE_GEMFILE" => File.expand_path("../Gemfile", __dir__),
        "RSPEC_OSC7501" => mode,
        "RUBYLIB" => File.expand_path("../lib", __dir__)
      }.merge(extra_env)
      command = [RbConfig.ruby, "-S", "bundle", "exec", "rspec", "-r", "rspec/osc7501"]
      command += ["-f", "RSpec::OSC7501::Formatter"] if formatter
      command += ["--out", osc_out] if formatter && osc_out
      command += ["-f", "progress", *options, "sample_spec.rb"]
      if tty
        output, status = capture_pty(environment, command, directory)
        [output, "", status]
      else
        output, error, status = Open3.capture3(environment, *command, chdir: directory)
        file = File.join(directory, "result.json")
        File.file?(file) ? [output, error, status, File.read(file)] : [output, error, status]
      end
    end
  end

  def capture_pty(environment, command, directory)
    master, slave = PTY.open
    pid = Process.spawn(environment, *command, chdir: directory, out: slave, err: slave)
    output = +""
    status = nil
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 15
    quiet_since = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    loop do
      ready = IO.select([master], nil, nil, 0.1)
      if ready
        begin
          chunk = master.read_nonblock(65_536)
          output << chunk
          quiet_since = Process.clock_gettime(Process::CLOCK_MONOTONIC) unless chunk.empty?
        rescue IO::WaitReadable
          nil
        end
      end
      if !status
        waited, result = Process.waitpid2(pid, Process::WNOHANG)
        status = result if waited
      end
      now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      break if status && now - quiet_since >= 0.2
      raise "RSpec PTY timeout (status=#{status.inspect}, bytes=#{output.bytesize})" if now >= deadline
    end
    [output, status]
  ensure
    Process.kill("KILL", pid) if pid && !status
    Process.waitpid(pid) if pid && !status
    master&.close
    slave&.close
  end

  it "runs beside progress output without changing a passing exit status" do
    output, error, status = run_suite('RSpec.describe("pass") { it("works") { expect(1).to eq(1) } }')
    records = frames(output)

    expect(status.exitstatus).to eq(0)
    expect(error).to be_empty
    expect(output).to include("1 example, 0 failures")
    expect(records.first).to include("app" => "rspec", "title" => "RSpec", "state" => "working", "progress" => "0")
    expect(records.last).to include("state" => "done", "msg" => a_string_including("1 example, 0 failures"))
    expect(records.count { |record| record.fetch("state") != "working" }).to eq(1)
  end

  it "reports failures and pending examples without stopping at the first failure" do
    source = <<~RUBY
      RSpec.describe("mix") do
        it("passes") { expect(1).to eq(1) }
        it("fails") { expect(1).to eq(2) }
        it("waits") { pending("later"); expect(1).to eq(2) }
      end
    RUBY
    output, _, status = run_suite(source)
    expect(status.exitstatus).to eq(1)
    expect(frames(output).last).to include("state" => "error", "msg" => a_string_including("3 examples, 1 failure, 1 pending"))
  end

  it "distinguishes boolean fail-fast from interruption" do
    source = 'RSpec.describe("fast") { it("fails") { raise "failure" }; it("skips") { raise "should not run" } }'
    output, _, status = run_suite(source, "--fail-fast")
    expect(status.exitstatus).to eq(1)
    expect(frames(output).last).to include("state" => "error", "msg" => a_string_including("1 example, 1 failure"))
  end

  it "honors integer fail-fast thresholds" do
    source = 'RSpec.describe("fast") { it("fails once") { raise "one" }; it("fails twice") { raise "two" }; it("skips") { raise "three" } }'
    output, _, status = run_suite(source, "--fail-fast=2")
    expect(status.exitstatus).to eq(1)
    expect(frames(output).last).to include("state" => "error", "msg" => a_string_including("2 examples, 2 failures"))
  end

  [0, -1].each do |threshold|
    it "reports failure for fail-fast threshold #{threshold}" do
      source = 'RSpec.describe("fast") { it("fails") { raise "failure" }; it("skips") {} }'
      output, _, status = run_suite(source, "--fail-fast=#{threshold}")
      expect(status.exitstatus).to eq(1)
      expect(frames(output).last).to include("state" => "error", "msg" => a_string_including("1 example, 1 failure"))
    end
  end

  [["RuntimeError", "nil", 0, "done"], ["Interrupt", 'raise "failure"', 1, "error"],
   ["RuntimeError", "exit 0", 0, "idle"]].each do |exception, body, exit_status, state|
    it "reports #{state} for a run inside rescue #{exception}" do
      script = <<~RUBY
        require "rspec/osc7501"
        require "stringio"
        RSpec.describe("embedded") { it("runs") { #{body} } }
        begin
          raise #{exception}, "caller exception"
        rescue #{exception}
          exit RSpec::Core::Runner.run(["-f", "RSpec::OSC7501::Formatter"], StringIO.new, $stdout)
        end
      RUBY
      output, error, status = Open3.capture3({ "RSPEC_OSC7501" => "force" }, RbConfig.ruby,
                                           "-I", File.expand_path("../lib", __dir__), "-e", script)
      expect(error).to be_empty
      expect(status.exitstatus).to eq(exit_status)
      expect(frames(output).last).to include("state" => state)
    end
  end

  it "reports the first SIGINT with remaining examples as idle" do
    source = 'RSpec.describe("interrupt") { it("signals") { Process.kill("INT", Process.pid); sleep 0.02 }; it("never runs") { raise "ran" } }'
    output, _, status = run_suite(source)
    expect(status.exitstatus).to eq(1)
    expect(frames(output).last).to include("state" => "idle", "msg" => a_string_including("1 example, 0 failures"))
  end

  it "reports SIGINT during the final example as idle despite complete counts" do
    source = 'RSpec.describe("interrupt") { it("last") { Process.kill("INT", Process.pid); sleep 0.02 } }'
    output, _, status = run_suite(source)
    expect(status.exitstatus).to eq(0)
    expect(frames(output).last).to include("state" => "idle", "msg" => a_string_including("1 example, 0 failures"))
  end

  it "keeps prior failure counts when interrupted later" do
    source = 'RSpec.describe("interrupt") { it("fails") { raise "first" }; it("signals") { Process.kill("INT", Process.pid); sleep 0.02 }; it("never runs") { raise "ran" } }'
    output, _, status = run_suite(source)
    expect(status.exitstatus).to eq(1)
    expect(frames(output).last).to include("state" => "idle", "msg" => a_string_including("2 examples, 1 failure"))
  end

  it "reports outside-example hook errors" do
    source = 'RSpec.configure { |c| c.before(:suite) { raise "setup failed" } }; RSpec.describe("hook") { it("runs") {} }'
    output, _, status = run_suite(source)
    expect(status.exitstatus).to eq(1)
    expect(frames(output).last).to include("state" => "error", "msg" => a_string_including("1 error occurred outside of examples"))
  end

  it "reports ordinary load errors after formatter installation" do
    output, _, status = run_suite('raise "load failed"')
    expect(status.exitstatus).to eq(1)
    expect(frames(output).last).to include("state" => "error", "msg" => a_string_including("1 error occurred outside of examples"))
  end

  it "does not imply success for empty suites configured to fail" do
    output, _, status = run_suite('RSpec.configure { |c| c.fail_if_no_examples = true }; RSpec.describe("empty") {}')
    expect(status.exitstatus).to eq(1)
    expect(frames(output).last).to include("state" => "error", "msg" => a_string_including("0 examples, 0 failures"))
  end

  it "marks a dry run in its status message" do
    output, _, status = run_suite('RSpec.describe("dry") { it("does not execute") { raise "ran" } }', "--dry-run")
    expect(status.exitstatus).to eq(0)
    expect(frames(output).last).to include("state" => "done", "msg" => a_string_including("dry run"))
  end

  it "honors formatter destinations and leaves JSON parseable" do
    output, error, status, json = run_suite('RSpec.describe("json") { it("passes") {} }', "-f", "json", "--out", "result.json", mode: "auto")
    expect(status.exitstatus).to eq(0)
    expect(frames(output)).to be_empty
    expect(error).to be_empty
    expect(output).to include("1 example, 0 failures")
    expect(JSON.parse(json).fetch("summary")).to include("example_count" => 1, "failure_count" => 0)
  end

  it "routes status to the formatter's --out destination" do
    output, error, status = run_suite('RSpec.describe("route") { it("passes") {} }', osc_out: "/dev/stderr")
    expect(status.exitstatus).to eq(0)
    expect(frames(output)).to be_empty
    expect(frames(error).last).to include("state" => "done")
    expect(output).to include("1 example, 0 failures")
  end

  it "leaves a redirected formatter destination silent in auto mode" do
    output, error, status = run_suite('RSpec.describe("route") { it("passes") {} }', mode: "auto", osc_out: "/dev/stderr")
    expect(status.exitstatus).to eq(0)
    expect(frames(output)).to be_empty
    expect(frames(error)).to be_empty
  end

  it "does not activate when the library is merely required" do
    output, error, status = run_suite('RSpec.describe("require") { it("passes") {} }', formatter: false)
    expect(status.exitstatus).to eq(0)
    expect(frames(output)).to be_empty
    expect(error).to be_empty
  end

  it "reports syntax errors during loading" do
    output, _, status = run_suite("RSpec.describe(\"broken\") do\n")
    expect(status.exitstatus).to eq(1)
    expect(frames(output).last).to include("state" => "error", "msg" => a_string_including("1 error occurred outside of examples"))
  end

  it "reports an after-suite error" do
    source = 'RSpec.configure { |c| c.after(:suite) { raise "teardown failed" } }; RSpec.describe("hook") { it("runs") {} }'
    output, _, status = run_suite(source)
    expect(status.exitstatus).to eq(1)
    expect(frames(output).last).to include("state" => "error", "msg" => a_string_including("1 error occurred outside of examples"))
  end

  it "reports a before-context error" do
    source = 'RSpec.describe("hook") { before(:context) { raise "setup failed" }; it("does not run") {} }'
    output, _, status = run_suite(source)
    expect(status.exitstatus).to eq(1)
    expect(frames(output).last).to include("state" => "error", "msg" => a_string_including("1 example, 1 failure"))
  end

  it "reports an after-context error" do
    source = 'RSpec.describe("hook") { after(:context) { raise "teardown failed" }; it("runs") {} }'
    output, _, status = run_suite(source)
    expect(status.exitstatus).to eq(1)
    expect(frames(output).last).to include("state" => "error", "msg" => a_string_including("1 error occurred outside of examples"))
  end

  it "treats nonzero SystemExit during execution as an error" do
    output, _, status = run_suite('RSpec.describe("exit") { it("exits") { exit 2 } }')
    expect(status.exitstatus).to eq(2)
    expect(frames(output).last).to include("state" => "error")
  end

  it "treats zero-status SystemExit during execution as an early stop" do
    output, _, status = run_suite('RSpec.describe("exit") { it("exits") { exit 0 } }')
    expect(status.exitstatus).to eq(0)
    expect(frames(output).last).to include("state" => "idle")
  end

  it "reports raised Interrupt as idle during unwinding" do
    output, _, status = run_suite('RSpec.describe("interrupt") { it("raises") { raise Interrupt } }')
    expect(status.success?).not_to be(true)
    expect(frames(output).last).to include("state" => "idle")
  end

  it "emits no false final result when loading exits before callbacks" do
    output, _, status = run_suite("exit 2")
    expect(status.exitstatus).to eq(2)
    expect(frames(output)).to be_empty
  end

  it "emits on a PTY in auto mode and respects a custom title" do
    output, _, status = run_suite('RSpec.describe("tty") { it("passes") {} }', mode: "auto", tty: true,
                                  extra_env: { "RSPEC_OSC7501_TITLE" => "CI suite" })
    expect(status.exitstatus).to eq(0)
    expect(frames(output).first).to include("title" => "CI suite", "state" => "working")
    expect(frames(output).last).to include("title" => "CI suite", "state" => "done")
  end

  it "emits nothing when disabled on a PTY" do
    output, _, status = run_suite('RSpec.describe("tty") { it("passes") {} }', mode: "off", tty: true)
    expect(status.exitstatus).to eq(0)
    expect(frames(output)).to be_empty
  end
end
