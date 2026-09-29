# frozen_string_literal: true

source "https://rubygems.org"

# Specify your gem's dependencies in rubik.gemspec.
gemspec

group :development, :test do
  gem "minitest", "~> 5.20"
  gem "rake", "~> 13.0"
  gem "rubocop", "~> 1.60", require: false
  gem "rubocop-minitest", require: false
  # Coverage instrumentation for the CI surface (G17). Loaded only when
  # RUBIK_COVERAGE=1 — local runs stay untouched.
  gem "simplecov", require: false
end
