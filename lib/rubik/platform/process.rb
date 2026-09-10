# frozen_string_literal: true

module Rubik
  module Platform
    # Process and environment management (e.g. kill_tree).
    # Extracted from lib/rubik/platform.rb (Plan 86 D-4).
    module Process
      def self.included(base)
        base.extend self
      end

      def kill_tree(pid)
        return unless pid&.positive?

        if windows?
          begin
            # Plan 55 D-1 ile tutarlı dizi-form çağrı: cmd.exe ara katmanı ve kabuk
            # yönlendirmesi ("> NUL 2>&1") yerine out:/err: seçenekleri kullanılır.
            system("taskkill", "/F", "/T", "/PID", pid.to_s, out: File::NULL, err: File::NULL)
          rescue
            nil
          end
        else
          begin
            ::Process.kill("TERM", pid)
          rescue
            nil
          end
          begin
            ::Process.kill("KILL", pid)
          rescue
            nil
          end
        end
      end
    end
  end
end
