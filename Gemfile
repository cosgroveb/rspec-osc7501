# frozen_string_literal: true

source "https://rubygems.org"

gemspec

rspec_minor = ENV.fetch("RSPEC_MINOR", "3.13")
gem "rspec", "~> #{rspec_minor}.0"
gem "rspec-core", ENV.fetch("RSPEC_CORE_VERSION", "~> #{rspec_minor}.0")
gem "rake"
gem "rdoc"
