# frozen_string_literal: true

require 'rubygems/package_task'
require 'rdoc/task'
require 'rspec/core/rake_task'

RSpec::Core::RakeTask.new(:spec)
Gem::PackageTask.new(Gem::Specification.load('rspec-osc7501.gemspec')) do |task|
  task.package_dir = 'pkg'
end
RDoc::Task.new do |task|
  task.main = 'README.md'
  task.rdoc_files.include('README.md', 'LICENSE', 'CHANGELOG.md', 'CONTRIBUTING.md', 'lib/**/*.rb', 'doc/**/*.rdoc')
  task.rdoc_dir = 'tmp/rdoc'
end

desc 'Check Ruby and RSpec style'
task :lint do
  sh 'rubocop', 'lib', 'script', 'spec', 'Gemfile', 'Rakefile', 'rspec-osc7501.gemspec'
end

desc 'Check resolved dependencies for known vulnerabilities'
task :audit do
  sh 'bundle-audit', 'check', '--update'
end

desc 'Check GitHub Actions workflows'
task :workflows do
  sh 'actionlint'
end

desc 'Run lint, dependency and workflow checks'
task quality: %i[lint audit workflows]
task default: %i[quality spec package rdoc]
