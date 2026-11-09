# frozen_string_literal: true

require 'bundler'
require 'open3'
require 'rubygems/installer'
require 'tmpdir'

# Runs the packaged formatter without the checkout or Bundler in the child.
class InstalledSmoke
  RUNNER = <<-'RUBY'
    require 'rspec/osc7501'
    expected, checkout = ARGV
    entrypoint = $LOADED_FEATURES.find { |path| path.end_with?('/rspec/osc7501.rb') }
    abort 'Formatter did not load from the installed gem' unless File.realpath(entrypoint) == expected
    abort 'Checkout lib entered the load path' if $LOAD_PATH.any? { |path| File.expand_path(path) == checkout }
    exit RSpec::Core::Runner.run(['--options', File::NULL, '--order', 'defined',
                                 '-f', 'progress', '-f', 'RSpec::OSC7501::Formatter', 'sample_spec.rb'])
  RUBY

  def initialize(package)
    @package = File.expand_path(package)
    @dependencies = %w[rspec-core rspec-support].flat_map { |name| Gem.loaded_specs.fetch(name).full_require_paths }
    @checkout = File.expand_path('../lib', __dir__)
  end

  def run
    Dir.mktmpdir('rspec-osc7501-installed-') do |directory|
      constructor = Gem::Installer.respond_to?(:at) ? :at : :new
      installed = Gem::Installer.public_send(constructor, @package, install_dir: directory,
                                                                    ignore_dependencies: true).install
      @library = File.join(installed.full_gem_path, 'lib')
      check(directory, 0, 'done')
      check(directory, 1, 'error')
    end
    puts 'Installed gem: passing and failing suites verified'
  end

  private

  def check(directory, failures, state)
    body = failures.zero? ? 'true' : 'raise "installed smoke failure"'
    File.write(File.join(directory, 'sample_spec.rb'), "RSpec.describe('installed') { it('runs') { #{body} } }\n")
    output, error, status = capture(directory)
    raise "Installed suite failed (#{status.exitstatus}):\n#{output}\n#{error}" unless status.exitstatus == failures
    raise "Ordinary RSpec output missing:\n#{output}" unless output.include?("1 example, #{failures} failure")

    verify_final(output, state, failures)
  end

  def capture(directory)
    environment = { 'RUBYOPT' => nil, 'RUBYLIB' => nil, 'GEM_HOME' => directory, 'GEM_PATH' => directory,
                    'HOME' => directory, 'SPEC_OPTS' => nil, 'RSPEC_OSC7501' => 'force' }
    paths = [@library, *@dependencies].flat_map { |path| ['-I', path] }
    clean_env = Bundler.respond_to?(:with_unbundled_env) ? :with_unbundled_env : :with_clean_env
    Bundler.public_send(clean_env) do
      Open3.capture3(environment, Gem.ruby, *paths, '-e', RUNNER,
                     File.realpath(File.join(@library, 'rspec/osc7501.rb')), @checkout, chdir: directory)
    end
  end

  def verify_final(output, state, failures)
    records = output.scan(/\e\]7501;([^\e]*)\e\\/).flatten
    final = records.last.to_s.split(':').map { |field| field.split('=', 2) }.to_h
    raise "Wrong final OSC record:\n#{output}" unless final['app'] == 'rspec' && final['state'] == state
    raise "Unexpected final progress:\n#{output}" if final.key?('progress')

    verify_summary(final, failures)
  end

  def verify_summary(final, failures)
    message = final.fetch('msg', '').unpack('m0').first
    prefix = failures.zero? ? 'Completed' : 'Failed'
    return if message.start_with?("#{prefix}: 1 example, #{failures} failure")

    raise "Wrong final OSC summary: #{message.inspect}"
  end
end

InstalledSmoke.new(ARGV.fetch(0)).run if $PROGRAM_NAME == __FILE__
