# frozen_string_literal: true

require "spec_helper"

RSpec.describe RSpec::OSC7501::Formatter do
  around do |example|
    original = ENV["RSPEC_OSC7501"]
    ENV["RSPEC_OSC7501"] = "force"
    example.run
  ensure
    original.nil? ? ENV.delete("RSPEC_OSC7501") : ENV["RSPEC_OSC7501"] = original
  end

  let(:output) { StringIO.new }
  let(:clock) { -> { @now } }
  let(:formatter) { described_class.new(output, clock: clock) }
  let(:example_notification) { Struct.new(:example).new(Struct.new(:full_description).new("checks behavior")) }

  it "throttles intermediate records while retaining completed progress and current description" do
    @now = 0.0
    formatter.start(Struct.new(:count).new(3))
    @now = 0.05
    formatter.example_started(example_notification)
    formatter.example_passed(example_notification)
    expect(frames(output.string).size).to eq(1)

    @now = 0.1
    formatter.example_started(example_notification)
    expect(frames(output.string).last).to include("state" => "working", "progress" => "33",
                                                   "msg" => a_string_including("1/3 examples", "checks behavior"))
    @now = 0.2
    formatter.example_pending(example_notification)
    expect(frames(output.string).last).to include("state" => "working", "progress" => "66",
                                                   "msg" => a_string_including("1 pending"))
  end

  it "omits progress when RSpec has no examples" do
    @now = 0.0
    formatter.start(Struct.new(:count).new(0))
    expect(frames(output.string).fetch(0)).not_to have_key("progress")
  end

  it "emits one incomplete result if close arrives without a summary" do
    @now = 0.0
    formatter.start(Struct.new(:count).new(2))
    formatter.close(nil)
    formatter.close(nil)
    expect(frames(output.string).last).to include("state" => "error", "msg" => a_string_including("Incomplete"))
    expect(frames(output.string).count { |record| record.fetch("state") == "error" }).to eq(1)
  end

  it "does not emit an outcome when no lifecycle callbacks arrive" do
    formatter.close(nil)
    expect(output.string).to be_empty
  end

  it "reads mode once when RSpec constructs the formatter" do
    @now = 0.0
    selected_formatter = formatter
    ENV["RSPEC_OSC7501"] = "off"
    selected_formatter.start(Struct.new(:count).new(1))
    expect(frames(output.string).first).to include("state" => "working")
  end
end
