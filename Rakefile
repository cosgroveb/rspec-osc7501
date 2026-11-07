# frozen_string_literal: true

require "rubygems/package_task"
require "rdoc/task"
require "rspec/core/rake_task"

RSpec::Core::RakeTask.new(:spec)
Gem::PackageTask.new(Gem::Specification.load("rspec-osc7501.gemspec")) do |task|
  task.package_dir = "pkg"
end
RDoc::Task.new do |task|
  task.main = "README.md"
  task.rdoc_files.include("README.md", "LICENSE", "CHANGELOG.md", "CONTRIBUTING.md", "lib/**/*.rb", "doc/**/*.rdoc")
  task.rdoc_dir = "tmp/rdoc"
end

task default: :spec
