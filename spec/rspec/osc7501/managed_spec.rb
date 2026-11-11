# frozen_string_literal: true

require 'spec_helper'
require 'open3'
require 'tmpdir'
require 'rbconfig'
require 'json'
require 'rspec/osc7501/managed'

RSpec.describe RSpec::OSC7501::Managed, :aggregate_failures do
  def run_managed(options = '', env = {}, source = 'RSpec.describe("sample") { it("passes") {} }')
    Dir.mktmpdir('osc-managed') do |dir|
      File.write(File.join(dir, 'sample_spec.rb'), source)
      File.write(File.join(dir, '.rspec'), options)
      environment = { 'RSPEC_OSC7501' => 'force', 'RSPEC_OSC7501_ID' => 'rake-1-a/rspec-1' }.merge(env)
      # Ruby 2.1 processes command-line preloads before RUBYOPT's bundler/setup.
      output, error, status = Open3.capture3(environment, RbConfig.ruby, '-rbundler/setup',
                                             '-I', File.expand_path('../../../lib', __dir__),
                                             '-rrspec/osc7501/managed', '-S', 'rspec', 'sample_spec.rb', chdir: dir)
      file = File.join(dir, 'result.json')
      [output, error, status, File.file?(file) ? File.read(file) : nil]
    end
  end

  it 'uses the parent bundle versions during managed preloading' do
    versions = [RSpec::Core::Version::STRING, RSpec::Support::Version::STRING].join('/')
    source = 'puts [RSpec::Core::Version::STRING, RSpec::Support::Version::STRING].join("/")'
    output, error, status = run_managed('', {}, source)
    expect(status.success?).to be(true), error
    expect(output).to include(versions)
  end

  it 'adds OSC while preserving default progress' do
    output, error, status = run_managed
    expect(status.success?).to be(true), error
    expect(output).to include('1 example, 0 failures', '.')
    expect(frames(output).map { |frame| frame['state'] }).to eq(%w[working done])
    expect(frames(output).map { |frame| frame['id'] }.uniq).to eq(['rake-1-a/rspec-1'])
  end

  it 'preserves explicit OSC selection without duplicating it' do
    output, error, status = run_managed('--format RSpec::OSC7501::Formatter --format documentation')
    expect(status.success?).to be(true), error
    expect(output).to include('passes')
    expect(frames(output).size).to eq(2)
  end

  it 'preserves JSON file output and sends automatic OSC to stdout' do
    output, error, status, json = run_managed('--format json --out result.json')
    expect(status.success?).to be(true), error
    expect(JSON.parse(json)['summary']['failure_count']).to eq(0)
    expect(frames(output).size).to eq(2)
  end

  it 'preserves an explicit OSC file destination' do
    output, error, status, file = run_managed('--format RSpec::OSC7501::Formatter --out result.json --format progress')
    expect(status.success?).to be(true), error
    expect(frames(output)).to be_empty
    expect(frames(file).size).to eq(2)
  end

  [nil, '', 'invalid:id'].each do |id|
    it "is inert for context #{id.inspect}" do
      output, error, status = run_managed('', 'RSPEC_OSC7501_ID' => id)
      expect(status.success?).to be(true), error
      expect(frames(output)).to be_empty
    end
  end

  it 'honors explicit off' do
    output, error, status = run_managed('', 'RSPEC_OSC7501' => 'off')
    expect(status.success?).to be(true), error
    expect(frames(output)).to be_empty
  end

  context 'with a managed configuration' do
    let(:configuration) { RSpec::Core::Configuration.new }
    let(:other) { RSpec::Core::Configuration.new }

    before do
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with('RSPEC_OSC7501_ID').and_return('rake-1-a/rspec-1')
      allow(ENV).to receive(:[]).with('RSPEC_OSC7501').and_return('force')
    end

    it 'installs once on only the requested configuration' do
      expect(described_class.install!(configuration)).to be(true)
      expect(described_class.install!(configuration)).to be(false)
      expect(other.send(:formatter_loader)).not_to be_a(described_class::Loader)
    end
  end
end
