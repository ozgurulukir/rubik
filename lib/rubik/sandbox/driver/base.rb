# frozen_string_literal: true

module Rubik
  module Sandbox
    module Driver
      class Base
        attr_reader :options

        def initialize(options = {})
          @options = options || {}
        end

        def name
          self.class.name.split("::").last.sub("Driver", "").downcase
        end

        def available?
          raise NotImplementedError
        end

        def run(cmd, timeout: 15, chdir: Dir.pwd, allow_network: false, memory_limit_mb: 512, cpus: "1.0")
          raise NotImplementedError
        end
      end
    end
  end
end
