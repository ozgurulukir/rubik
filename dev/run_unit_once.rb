# frozen_string_literal: true

# Loads every unit test file into one process so a single Minitest run pays
# the ~8.5s boot cost once instead of once per file. Fast feedback loop; CI
# can run this via `rake test:unit_once`.
# Usage: bundle exec rake test:unit_once
Dir["test/unit/**/test_*.rb"].each { |f| require_relative "../#{f}" }
