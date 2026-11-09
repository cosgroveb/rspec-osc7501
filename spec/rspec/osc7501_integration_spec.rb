# frozen_string_literal: true

require 'spec_helper'
require 'open3'
require 'pty'
require 'tmpdir'
require 'rbconfig'
require 'json'

require_relative '../support/cli_suite'

RSpec.describe RSpec::OSC7501, :aggregate_failures do
  def run_suite(source, *options, **settings)
    CLISuite.new(source, options, settings).run
  end

  let(:mixed_source) do
    <<-RUBY
      RSpec.describe("mix") do
        it("passes") { expect(1).to eq(1) }
        it("fails") { expect(1).to eq(2) }
        it("waits") { pending("later"); expect(1).to eq(2) }
      end
    RUBY
  end

  context 'with a passing example' do
    let(:result) { run_suite('RSpec.describe("pass") { it("works") { expect(1).to eq(1) } }') }
    let(:output) { result[0] }
    let(:records) { frames(output) }

    it 'preserves progress output and a passing exit status' do
      expect(result[2].exitstatus).to eq(0)
      expect(result[1]).to be_empty
      expect(output).to include('1 example, 0 failures')
    end

    it 'emits one final result after the initial record' do
      expect(records.first).to include('app' => 'rspec', 'title' => 'RSpec', 'state' => 'working', 'progress' => '0')
      expect(records.last).to include('state' => 'done', 'msg' => a_string_including('1 example, 0 failures'))
      expect(records.count { |record| record.fetch('state') != 'working' }).to eq(1)
    end
  end

  it 'reports failures and pending examples without stopping at the first failure' do
    output, _, status = run_suite(mixed_source)
    expect(status.exitstatus).to eq(1)
    expect(frames(output).last).to include('state' => 'error',
                                           'msg' => a_string_including('3 examples, 1 failure, 1 pending'))
  end

  it 'distinguishes boolean fail-fast from interruption' do
    source = 'RSpec.describe("fast") { it("fails") { raise "failure" }; it("skips") { raise "should not run" } }'
    output, _, status = run_suite(source, '--fail-fast')
    expect(status.exitstatus).to eq(1)
    expect(frames(output).last).to include('state' => 'error', 'msg' => a_string_including('1 example, 1 failure'))
  end

  context 'with integer fail-fast' do
    let(:source) do
      'RSpec.describe("fast") { it("fails once") { raise "one" }; ' \
             'it("fails twice") { raise "two" }; ' \
             'it("skips") { raise "three" } }'
    end

    it 'honors integer fail-fast thresholds' do
      output, _, status = run_suite(source, '--fail-fast=2')
      expect(status.exitstatus).to eq(1)
      expect(frames(output).last).to include('state' => 'error', 'msg' => a_string_including('2 examples, 2 failures'))
    end
  end

  [0, -1].each do |threshold|
    it "reports failure for fail-fast threshold #{threshold}" do
      source = 'RSpec.describe("fast") { it("fails") { raise "failure" }; it("skips") {} }'
      output, _, status = run_suite(source, "--fail-fast=#{threshold}")
      expect(status.exitstatus).to eq(1)
      expect(frames(output).last).to include('state' => 'error', 'msg' => a_string_including('1 example, 1 failure'))
    end
  end

  [['RuntimeError', 'nil', 0, 'done'], ['Interrupt', 'raise "failure"', 1, 'error'],
   ['RuntimeError', 'exit 0', 0, 'idle']].each do |exception, body, exit_status, state|
    it "reports #{state} for a run inside rescue #{exception}" do
      output, error, status = CLISuite.run_embedded(exception, body)
      expect(error).to be_empty
      expect(status.exitstatus).to eq(exit_status)
      expect(frames(output).last).to include('state' => state)
    end
  end

  context 'with SIGINT before the last example' do
    let(:source) do
      'RSpec.describe("interrupt") { it("signals") { Process.kill("INT", Process.pid); ' \
             'sleep 0.02 }; ' \
             'it("never runs") { raise "ran" } }'
    end

    it 'reports the first SIGINT with remaining examples as idle' do
      output, _, status = run_suite(source)
      expect(status.exitstatus).to eq(1)
      expect(frames(output).last).to include('state' => 'idle', 'msg' => a_string_including('1 example, 0 failures'))
    end
  end

  it 'reports SIGINT during the final example as idle despite complete counts' do
    source = 'RSpec.describe("interrupt") { it("last") { Process.kill("INT", Process.pid); sleep 0.02 } }'
    output, _, status = run_suite(source)
    expect(status.exitstatus).to eq(0)
    expect(frames(output).last).to include('state' => 'idle', 'msg' => a_string_including('1 example, 0 failures'))
  end

  context 'with SIGINT after an earlier failure' do
    let(:source) do
      'RSpec.describe("interrupt") { it("fails") { raise "first" }; ' \
             'it("signals") { Process.kill("INT", Process.pid); ' \
             'sleep 0.02 }; ' \
             'it("never runs") { raise "ran" } }'
    end

    it 'keeps prior failure counts when interrupted later' do
      output, _, status = run_suite(source)
      expect(status.exitstatus).to eq(1)
      expect(frames(output).last).to include('state' => 'idle', 'msg' => a_string_including('2 examples, 1 failure'))
    end
  end

  context 'with a before-suite error' do
    let(:source) do
      'RSpec.configure { |c| c.before(:suite) { raise "setup failed" } }; ' \
             'RSpec.describe("hook") { it("runs") {} }'
    end

    it 'reports outside-example hook errors' do
      output, _, status = run_suite(source)
      expect(status.exitstatus).to eq(1)
      expect(frames(output).last).to include('state' => 'error',
                                             'msg' => a_string_including('1 error occurred outside of examples'))
    end
  end

  it 'reports ordinary load errors after formatter installation' do
    output, _, status = run_suite('raise "load failed"')
    expect(status.exitstatus).to eq(1)
    expect(frames(output).last).to include('state' => 'error',
                                           'msg' => a_string_including('1 error occurred outside of examples'))
  end

  it 'does not imply success for empty suites configured to fail' do
    output, _, status = run_suite('RSpec.configure { |c| c.fail_if_no_examples = true }; RSpec.describe("empty") {}')
    expect(status.exitstatus).to eq(1)
    expect(frames(output).last).to include('state' => 'error', 'msg' => a_string_including('0 examples, 0 failures'))
  end

  it 'marks a dry run in its status message' do
    output, _, status = run_suite('RSpec.describe("dry") { it("does not execute") { raise "ran" } }', '--dry-run')
    expect(status.exitstatus).to eq(0)
    expect(frames(output).last).to include('state' => 'done', 'msg' => a_string_including('dry run'))
  end

  context 'with a JSON formatter destination' do
    let(:result) do
      run_suite('RSpec.describe("json") { it("passes") {} }', '-f', 'json', '--out', 'result.json', mode: 'auto')
    end

    it 'preserves progress output and a passing exit status' do
      expect(result[2].exitstatus).to eq(0)
      expect(result[1]).to be_empty
      expect(result[0]).to include('1 example, 0 failures')
    end

    it 'leaves redirected output silent and JSON parseable' do
      expect(frames(result[0])).to be_empty
      expect(JSON.parse(result[3]).fetch('summary')).to include('example_count' => 1, 'failure_count' => 0)
    end
  end

  it "routes status to the formatter's --out destination" do
    output, error, status = run_suite('RSpec.describe("route") { it("passes") {} }', osc_out: '/dev/stderr')
    expect(status.exitstatus).to eq(0)
    expect(frames(output)).to be_empty
    expect(frames(error).last).to include('state' => 'done')
    expect(output).to include('1 example, 0 failures')
  end

  it 'leaves a redirected formatter destination silent in auto mode' do
    output, error, status = run_suite('RSpec.describe("route") { it("passes") {} }', mode: 'auto',
                                                                                     osc_out: '/dev/stderr')
    expect(status.exitstatus).to eq(0)
    expect(frames(output)).to be_empty
    expect(frames(error)).to be_empty
  end

  it 'does not activate when the library is merely required' do
    output, error, status = run_suite('RSpec.describe("require") { it("passes") {} }', formatter: false)
    expect(status.exitstatus).to eq(0)
    expect(frames(output)).to be_empty
    expect(error).to be_empty
  end

  it 'reports syntax errors during loading' do
    output, _, status = run_suite("RSpec.describe(\"broken\") do\n")
    expect(status.exitstatus).to eq(1)
    expect(frames(output).last).to include('state' => 'error',
                                           'msg' => a_string_including('1 error occurred outside of examples'))
  end

  context 'with an after-suite error' do
    let(:source) do
      'RSpec.configure { |c| c.after(:suite) { raise "teardown failed" } }; ' \
             'RSpec.describe("hook") { it("runs") {} }'
    end

    it 'reports an after-suite error' do
      output, _, status = run_suite(source)
      expect(status.exitstatus).to eq(1)
      expect(frames(output).last).to include('state' => 'error',
                                             'msg' => a_string_including('1 error occurred outside of examples'))
    end
  end

  it 'reports a before-context error' do
    source = 'RSpec.describe("hook") { before(:context) { raise "setup failed" }; it("does not run") {} }'
    output, _, status = run_suite(source)
    expect(status.exitstatus).to eq(1)
    expect(frames(output).last).to include('state' => 'error', 'msg' => a_string_including('1 example, 1 failure'))
  end

  it 'reports an after-context error' do
    source = 'RSpec.describe("hook") { after(:context) { raise "teardown failed" }; it("runs") {} }'
    output, _, status = run_suite(source)
    expect(status.exitstatus).to eq(1)
    expect(frames(output).last).to include('state' => 'error',
                                           'msg' => a_string_including('1 error occurred outside of examples'))
  end

  it 'treats nonzero SystemExit during execution as an error' do
    output, _, status = run_suite('RSpec.describe("exit") { it("exits") { exit 2 } }')
    expect(status.exitstatus).to eq(2)
    expect(frames(output).last).to include('state' => 'error')
  end

  it 'treats zero-status SystemExit during execution as an early stop' do
    output, _, status = run_suite('RSpec.describe("exit") { it("exits") { exit 0 } }')
    expect(status.exitstatus).to eq(0)
    expect(frames(output).last).to include('state' => 'idle')
  end

  it 'reports raised Interrupt as idle during unwinding' do
    output, _, status = run_suite('RSpec.describe("interrupt") { it("raises") { raise Interrupt } }')
    expect(status.success?).not_to be(true)
    expect(frames(output).last).to include('state' => 'idle')
  end

  it 'emits no false final result when loading exits before callbacks' do
    output, _, status = run_suite('exit 2')
    expect(status.exitstatus).to eq(2)
    expect(frames(output)).to be_empty
  end

  context 'with a custom title on a PTY' do
    let(:environment) { { 'RSPEC_OSC7501_TITLE' => 'CI suite' } }

    it 'emits on a PTY in auto mode and respects a custom title' do
      output, _, status = run_suite('RSpec.describe("tty") { it("passes") {} }',
                                    mode: 'auto', tty: true, extra_env: environment)
      expect(status.exitstatus).to eq(0)
      expect(frames(output).first).to include('title' => 'CI suite', 'state' => 'working')
      expect(frames(output).last).to include('title' => 'CI suite', 'state' => 'done')
    end
  end

  it 'emits nothing when disabled on a PTY' do
    output, _, status = run_suite('RSpec.describe("tty") { it("passes") {} }', mode: 'off', tty: true)
    expect(status.exitstatus).to eq(0)
    expect(frames(output)).to be_empty
  end

  it 'preserves readable failures when color and status are disabled' do
    output, _, status = run_suite(mixed_source, '-f', 'documentation', '--no-color', mode: 'off', tty: true)
    expect(status.exitstatus).to eq(1)
    expect(output).to include('passes', 'fails', 'waits', 'expected: 2', 'got: 1', '3 examples, 1 failure, 1 pending')
    expect(output).not_to include("\e")
  end

  it 'reports status independently of text color' do
    output, _, status = run_suite(mixed_source, '--no-color', mode: 'auto', tty: true, extra_env: { 'TERM' => 'xterm' })
    expect(status.exitstatus).to eq(1)
    expect(frames(output).last).to include('state' => 'error')
    expect(output).not_to match(/\e\[[\d;]*m/)
  end

  it 'preserves forced text color when status is disabled' do
    output, _, status = run_suite(mixed_source, '--force-color', mode: 'off', tty: true)
    expect(status.exitstatus).to eq(1)
    expect(output).to match(/\e\[[\d;]*m/)
    expect(frames(output)).to be_empty
  end

  it 'suppresses automatic status on a dumb terminal' do
    output, _, status = run_suite(mixed_source, mode: 'auto', tty: true, extra_env: { 'TERM' => 'dumb' })
    expect(status.exitstatus).to eq(1)
    expect(output).to include('3 examples, 1 failure, 1 pending')
    expect(frames(output)).to be_empty
  end

  it 'allows forced status on a dumb terminal' do
    output, _, status = run_suite(mixed_source, mode: 'force', tty: true, extra_env: { 'TERM' => 'dumb' })
    expect(status.exitstatus).to eq(1)
    expect(frames(output).last).to include('state' => 'error')
  end

  it 'keeps redirected status silent when text output uses a terminal' do
    output, _, status, file = run_suite(mixed_source, mode: 'auto', tty: true, osc_out: 'result.json')
    expect(status.exitstatus).to eq(1)
    expect(output).to include('3 examples, 1 failure, 1 pending')
    expect(frames(output)).to be_empty
    expect(file).to eq('')
  end
end
