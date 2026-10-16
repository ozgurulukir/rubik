# frozen_string_literal: true

require "tmpdir"
require "fileutils"

module Rubik
  module RuntimeValidation
    # AST Persistent Cache cold vs warm benchmarking harness.
    # Measures extraction time, on-disk cache footprint, warm validation latency, and speedup factor.
    class CacheHarness
      def run(file_count = 150)
        tmp = Dir.mktmpdir("rubik_cache_bench")
        rubik_dir = File.join(tmp, ".rubik")
        FileUtils.mkdir_p(rubik_dir)

        # 1. Generate synthetic source tree
        total_source_bytes = 0
        file_count.times do |i|
          code = <<~RUBY
            # Component #{i}
            class ServiceComponent#{i}
              attr_reader :id, :name

              def initialize(id)
                @id = id
                @name = "service_\#{id}"
              end

              def process(data)
                validate(data)
                transform(data)
              end

              private

              def validate(data)
                raise ArgumentError if data.nil?
              end

              def transform(data)
                data.to_s.upcase
              end
            end
          RUBY
          path = File.join(tmp, "component_#{i}.rb")
          File.write(path, code)
          total_source_bytes += code.bytesize
        end

        store = Rubik::AST::CacheStore.new(root_dir: tmp, home_dir: tmp)

        # 2. Cold build & save
        symbols = {}
        t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        Dir.glob(File.join(tmp, "*.rb")).each do |f|
          symbols[f] = Rubik::AST::Extractor.extract(f, File.read(f))
        end
        store.save(symbols)
        cold_time_s = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0

        cache_file = store.cache_path
        cache_size_bytes = File.exist?(cache_file) ? File.size(cache_file) : 0

        # 3. Warm load and verification (checks stat and SHA1 digest for every entry)
        t1 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        loaded = store.load
        warm_time_s = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t1


        speedup = (cold_time_s / [warm_time_s, 0.0001].max).round(2)
        {
          file_count: file_count,
          total_source_bytes: total_source_bytes,
          cold_duration_ms: (cold_time_s * 1000.0).round(1),
          warm_duration_ms: (warm_time_s * 1000.0).round(1),
          cache_size_bytes: cache_size_bytes,
          speedup_ratio: speedup,
          loaded_entries: loaded.size,
          passed: loaded.size == file_count && warm_time_s < 0.5 && warm_time_s < cold_time_s && cache_size_bytes.positive?
        }
      ensure
        FileUtils.remove_entry(tmp) if tmp && File.directory?(tmp)
      end
    end
  end
end
