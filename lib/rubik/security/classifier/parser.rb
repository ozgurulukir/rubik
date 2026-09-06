# frozen_string_literal: true

require_relative "parsers/bash"
require_relative "parsers/powershell"
require_relative "../../platform"

module Rubik
  module Security
    module Classifier
      module Parser
        def self.parse(expression, shell: nil)
          is_pwsh = (shell.to_s.downcase == "powershell" || shell == :pwsh || shell == :powershell) ||
                    (shell.nil? && Rubik::Platform.windows?)

          if is_pwsh
            Parsers::PowerShell.parse(expression)
          else
            Parsers::Bash.parse(expression)
          end
        end
      end
    end
  end
end
