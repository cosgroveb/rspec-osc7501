# frozen_string_literal: true

require_relative 'lib/rspec/osc7501/version'

Gem::Specification.new do |spec|
  spec.name = 'rspec-osc7501'
  spec.version = RSpec::OSC7501::VERSION
  spec.summary = 'RSpec formatter for OSC 7501 terminal program status'
  spec.description = 'Reports RSpec suite progress and outcomes through OSC 7501.'
  spec.authors = ['Brian Cosgrove']
  spec.email = ['cosgroveb@users.noreply.github.com']
  spec.homepage = 'https://github.com/cosgroveb/rspec-osc7501'
  spec.license = 'Apache-2.0'
  spec.required_ruby_version = '>= 3.3'
  spec.metadata = {
    'source_code_uri' => 'https://github.com/cosgroveb/rspec-osc7501',
    'bug_tracker_uri' => 'https://github.com/cosgroveb/rspec-osc7501/issues',
    'changelog_uri' => 'https://github.com/cosgroveb/rspec-osc7501/blob/main/CHANGELOG.md'
  }
  spec.files = Dir.glob('lib/**/*.rb') + Dir.glob('doc/**/*.rdoc') + %w[README.md LICENSE CHANGELOG.md CONTRIBUTING.md]
  spec.files += %w[CODE_OF_CONDUCT.md SECURITY.md ACCESSIBILITY.md]
  spec.files.select! { |file| File.file?(file) }
  spec.require_paths = ['lib']

  spec.add_dependency 'rspec-core', '>= 3.12', '< 4'
end
