# frozen_string_literal: true

require 'spec_helper'
require 'tempfile'
require_relative '../../support/sanitizer_inputs'

RSpec.describe RSpec::OSC7501::Writer do
  let(:output) { StringIO.new }
  let(:writer) { described_class.new(output, mode: 'force', title: 'RSpec') }

  before do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).to receive(:[]).with('TERM').and_return(nil)
  end

  context 'when writing a complete root record' do
    before do
      described_class.new(output, mode: 'force', title: 'Suite').emit(state: 'working', msg: 'running', progress: 35)
    end

    it 'delimits the frame', :aggregate_failures do
      expect(output.string).to start_with("\e]7501;")
      expect(output.string).to end_with("\e\\")
    end

    it 'encodes text and progress' do
      expect(frames(output.string)).to eq([{ 'app' => 'rspec', 'title' => 'Suite', 'state' => 'working',
                                             'msg' => 'running', 'progress' => '35' }])
    end

    it 'leaves the caller stream open' do
      expect(output).not_to be_closed
    end
  end

  context 'with a buffered stream' do
    let(:output) { Tempfile.new('osc7501') }

    after { output.close! }

    it 'flushes progress and final frames', :aggregate_failures do
      writer.emit(state: 'working', msg: 'running')
      expect(frames(File.read(output.path)).last).to include('state' => 'working')
      writer.emit(state: 'done', msg: 'complete')
      expect(frames(File.read(output.path)).last).to include('state' => 'done')
      expect(output).not_to be_closed
    end
  end

  context 'with a write-only stream' do
    let(:buffer) { +'' }
    let(:output) { Object.new }

    before do
      destination = buffer
      output.define_singleton_method(:write) { |text| destination << text }
    end

    it 'silences auto mode but supports force mode', :aggregate_failures do
      described_class.new(output, mode: 'auto', title: 'RSpec').emit(state: 'working', msg: 'running')
      expect(buffer).to be_empty
      writer.emit(state: 'done', msg: 'complete')
      expect(frames(buffer).last).to include('state' => 'done')
    end
  end

  it 'disables output after a flush failure', :aggregate_failures do
    output.define_singleton_method(:flush) { raise IOError, 'flush failed' }
    expect { writer.emit(state: 'working', msg: 'running') }.not_to raise_error
    writer.emit(state: 'done', msg: 'complete')
    expect(frames(output.string).map { |frame| frame.fetch('state') }).to eq(['working'])
    expect(output).not_to be_closed
  end

  context 'with controls, invalid bytes and oversized text' do
    let(:frame) { frames(output.string).fetch(0) }

    before do
      title = "#{'界' * 100}\x00\x7F\u0085"
      message = "#{"\xFF".b.force_encoding('UTF-8')}#{'界' * 700}\n"
      described_class.new(output, mode: 'force', title: title).emit(state: 'working', msg: message, progress: 120)
    end

    it 'bounds encoded text and the whole frame', :aggregate_failures do
      expect(frame.fetch('title').bytesize).to eq(192)
      expect(frame.fetch('msg').bytesize).to be <= 2048
      expect(output.string.bytesize).to be <= 4096
    end

    it 'truncates on character boundaries', :aggregate_failures do
      expect(frame.fetch('title')).to be_valid_encoding
      expect(frame.fetch('msg')).to be_valid_encoding
    end

    it 'removes controls and replaces invalid bytes', :aggregate_failures do
      expect(frame.fetch('msg')).not_to match(/[\u0000-\u001F\u007F-\u009F]/)
      expect(frame.fetch('msg')).to include('�')
    end

    it 'bounds progress' do
      expect(frame.fetch('progress')).to eq('100')
    end
  end

  it 'bounds sanitization input even when controls leave room in the output' do
    title = "#{"\0" * 288}discarded"
    message = "#{"\0" * 3072}discarded"
    described_class.new(output, mode: 'force', title: title).emit(state: 'working', msg: message)
    expect(frames(output.string).fetch(0)).to include('title' => '', 'msg' => '')
  end

  it 'uses sanitization headroom to fill the output after stripping controls' do
    title = "\0" * 96 + 't' * 192
    message = "\0" * 1024 + 'm' * 2048
    described_class.new(output, mode: 'force', title: title).emit(state: 'working', msg: message)
    expect(frames(output.string).fetch(0)).to include('title' => 't' * 192, 'msg' => 'm' * 2048)
  end

  ["#{"\0" * 287}界", "#{"\0" * 143}😀".encode('UTF-16LE')].each do |title|
    it "replaces a character split by the input cap in #{title.encoding}" do
      described_class.new(output, mode: 'force', title: title).emit(state: 'done', msg: 'complete')
      expect(frames(output.string).fetch(0)).to include('title' => '�')
    end
  end

  SanitizerInputs.cases.each do |description, title, message|
    context "with generated #{description}" do
      let(:frame) { frames(output.string).fetch(0) }

      before do
        described_class.new(output, mode: 'force', title: title).emit(state: 'working', msg: message, progress: 50)
      end

      it 'emits one complete bounded frame', :aggregate_failures do
        expect(output.string).to match(%r{\A\e\]7501;app=rspec:title=[A-Za-z0-9+/=]*:state=working:
                                         msg=[A-Za-z0-9+/=]*:progress=50\e\\\z}x)
        expect(output.string.bytesize).to be <= 4096
      end

      it 'bounds both decoded fields', :aggregate_failures do
        expect(frame.fetch('title').bytesize).to be <= 192
        expect(frame.fetch('msg').bytesize).to be <= 2048
      end

      it 'produces valid UTF-8 without controls', :aggregate_failures do
        expect(frame.values_at('title', 'msg')).to all(be_valid_encoding)
        expect(frame.values_at('title', 'msg')).not_to include(match(/[\u0000-\u001F\u007F-\u009F]/))
      end
    end
  end

  it 'omits progress from terminal states' do
    described_class.new(output, mode: 'force', title: 'RSpec').emit(state: 'done', msg: 'complete', progress: 100)
    expect(frames(output.string).fetch(0)).not_to have_key('progress')
  end

  it 'removes controls from the title and message before encoding' do
    described_class.new(output, mode: 'force', title: "\x00Suite\x7F\u0085").emit(state: 'working',
                                                                                  msg: "one\ntwo\u009F")
    expect(frames(output.string).fetch(0)).to include('title' => 'Suite', 'msg' => 'onetwo')
  end

  it 'uses the supplied stream only when it is a TTY in auto mode', :aggregate_failures do
    described_class.new(output, mode: 'auto', title: 'RSpec').emit(state: 'working', msg: 'running')
    expect(output.string).to be_empty

    output.define_singleton_method(:tty?) { true }
    described_class.new(output, mode: 'auto', title: 'RSpec').emit(state: 'working', msg: 'running')
    expect(frames(output.string).size).to eq(1)
  end

  it 'disables output in off mode, even for a TTY' do
    output.define_singleton_method(:tty?) { true }
    described_class.new(output, mode: 'off', title: 'RSpec').emit(state: 'working', msg: 'running')
    expect(output.string).to be_empty
  end

  it 'rejects an invalid mode' do
    expect do
      described_class.new(output, mode: 'sometimes', title: 'RSpec')
    end.to raise_error(ArgumentError, /RSPEC_OSC7501/)
  end

  it 'does not interrupt specs or close the caller stream after an I/O failure', :aggregate_failures do
    output.close
    expect { writer.emit(state: 'working', msg: 'running') }.not_to raise_error
    expect { writer.emit(state: 'done', msg: 'complete') }.not_to raise_error
    expect(output).to be_closed
  end

  it 'does not interrupt specs when auto mode inspects a closed stream' do
    file = File.open(File::NULL)
    file.close
    expect { described_class.new(file, mode: 'auto', title: 'RSpec') }.not_to raise_error
  end

  context 'with a broken pipe' do
    let(:output) do
      reader, stream = IO.pipe
      reader.close
      stream
    end

    after { output.close }

    it 'disables optional output and leaves the stream open', :aggregate_failures do
      expect { writer.emit(state: 'working', msg: 'running') }.not_to raise_error
      expect { writer.emit(state: 'done', msg: 'complete') }.not_to raise_error
      expect(output).not_to be_closed
    end
  end
end
