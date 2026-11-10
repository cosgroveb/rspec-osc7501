# frozen_string_literal: true

source 'https://rubygems.org'

gemspec

rspec_minor = ENV.fetch('RSPEC_MINOR', '3.13')
gem 'bundler-audit'
gem 'rake'
gem 'rdoc'
gem 'rspec', ENV.fetch('RSPEC_VERSION', "~> #{rspec_minor}.0")
gem 'rspec-core', ENV.fetch('RSPEC_CORE_VERSION', "~> #{rspec_minor}.0")
gem 'rubocop', '~> 1.92'
gem 'rubocop-rspec', '~> 3.10'
