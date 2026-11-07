# frozen_string_literal: true

require "spec_helper"

RSpec.describe RSpec::OSC7501::Writer do
  let(:output) { StringIO.new }

  it "writes a complete root record with encoded text and bounded progress" do
    writer = described_class.new(output, mode: "force", title: "Suite")
    writer.emit(state: "working", msg: "running", progress: 35)

    expect(output.string).to start_with("\e]7501;")
    expect(output.string).to end_with("\e\\")
    expect(frames(output.string)).to eq([{ "app" => "rspec", "title" => "Suite", "state" => "working", "msg" => "running", "progress" => "35" }])
    expect(output).not_to be_closed
  end

  it "sanitizes controls and invalid bytes, and truncates on character boundaries" do
    title = "界" * 100 + "\x00\x7F\u0085"
    message = "\xFF".b.force_encoding("UTF-8") + "界" * 700 + "\n"
    writer = described_class.new(output, mode: "force", title: title)
    writer.emit(state: "working", msg: message, progress: 120)

    frame = frames(output.string).fetch(0)
    expect(frame.fetch("title").bytesize).to eq(192)
    expect(frame.fetch("msg").bytesize).to be <= 2048
    expect(frame.fetch("title")).to be_valid_encoding
    expect(frame.fetch("msg")).to be_valid_encoding
    expect(frame.fetch("msg")).not_to match(/[\u0000-\u001F\u007F-\u009F]/)
    expect(frame.fetch("msg")).to include("�")
    expect(frame.fetch("progress")).to eq("100")
    expect(output.string.bytesize).to be <= 4096
  end

  it "omits progress from terminal states" do
    described_class.new(output, mode: "force", title: "RSpec").emit(state: "done", msg: "complete", progress: 100)
    expect(frames(output.string).fetch(0)).not_to have_key("progress")
  end

  it "removes controls from the title and message before encoding" do
    described_class.new(output, mode: "force", title: "\x00Suite\x7F\u0085").emit(state: "working", msg: "one\ntwo\u009F")
    expect(frames(output.string).fetch(0)).to include("title" => "Suite", "msg" => "onetwo")
  end

  it "uses the supplied stream only when it is a TTY in auto mode" do
    described_class.new(output, mode: "auto", title: "RSpec").emit(state: "working", msg: "running")
    expect(output.string).to be_empty

    output.define_singleton_method(:tty?) { true }
    described_class.new(output, mode: "auto", title: "RSpec").emit(state: "working", msg: "running")
    expect(frames(output.string).size).to eq(1)
  end

  it "disables output in off mode, even for a TTY" do
    output.define_singleton_method(:tty?) { true }
    described_class.new(output, mode: "off", title: "RSpec").emit(state: "working", msg: "running")
    expect(output.string).to be_empty
  end

  it "rejects an invalid mode" do
    expect { described_class.new(output, mode: "sometimes", title: "RSpec") }.to raise_error(ArgumentError, /RSPEC_OSC7501/)
  end

  it "does not interrupt specs or close the caller stream after an I/O failure" do
    output.close
    writer = described_class.new(output, mode: "force", title: "RSpec")
    expect { writer.emit(state: "working", msg: "running") }.not_to raise_error
    expect { writer.emit(state: "done", msg: "complete") }.not_to raise_error
    expect(output).to be_closed
  end

  it "does not interrupt specs when auto mode inspects a closed stream" do
    file = File.open(File::NULL)
    file.close
    expect { described_class.new(file, mode: "auto", title: "RSpec") }.not_to raise_error
  end

  it "disables optional output after a broken pipe" do
    reader, writer_stream = IO.pipe
    reader.close
    writer = described_class.new(writer_stream, mode: "force", title: "RSpec")
    expect { writer.emit(state: "working", msg: "running") }.not_to raise_error
    expect { writer.emit(state: "done", msg: "complete") }.not_to raise_error
    expect(writer_stream).not_to be_closed
  ensure
    writer_stream&.close
  end
end
