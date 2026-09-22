# frozen_string_literal: true

require "fileutils"
require "json"
require "digest"
require "time"
# save_manifest atomik yazımı Platform.atomic_write kullanır; dosyanın tek başına
# require edilmesi durumunda da çözümlenebilsin diye açık yüklenir.
require_relative "../platform"

module Rubik
  module Runtime
    class OverlayStorage
      attr_reader :root_dir, :home_dir

      COMMAND_SENTINEL = "# Rubik Custom Command:"
      TOOL_SENTINEL = "# Rubik Custom Tool:"

      def initialize(root_dir: Dir.pwd, home_dir: ENV.fetch("HOME", nil))
        @root_dir = File.expand_path(root_dir)
        @home_dir = File.expand_path(home_dir || ENV["HOME"] || ".")
        ensure_directories
      end

      def project_commands_dir
        File.join(@root_dir, ".rubik", "commands")
      end

      def global_commands_dir
        File.join(@home_dir, ".rubik", "commands")
      end

      def project_tools_dir
        File.join(@root_dir, ".rubik", "tools")
      end

      def global_tools_dir
        File.join(@home_dir, ".rubik", "tools")
      end

      def ensure_directories
        [project_commands_dir, global_commands_dir, project_tools_dir, global_tools_dir].each do |dir|
          FileUtils.mkdir_p(dir)
        rescue SystemCallError => e
          warn "[WARN] Failed to create overlay directory #{dir}: #{e.message}" if ENV["RUBIK_DEBUG"]
        end
      end

      def manifest_path(dir)
        File.join(dir, ".manifest.json")
      end

      def load_manifest(dir)
        path = manifest_path(dir)
        return {} unless File.exist?(path)

        JSON.parse(File.read(path))
      rescue JSON::ParserError
        {}
      end

      def save_manifest(dir, manifest)
        # Atomik yazım (tmp + rename): kilitsiz okuyucuların (load_manifest, manifest_state)
        # yarım manifest görmesini engeller; yarım okuma, kayıtlı overlay'lerin "unknown"
        # sayılıp kalıcı olarak reddedilmesine yol açabiliyordu. Platform.atomic_write,
        # Windows için unlink/rename yedeğiyle bu düzeni sağlar.
        Platform.atomic_write(manifest_path(dir), JSON.pretty_generate(manifest))
      end

      def normalize_content(raw)
        raw.delete("\r")
      end

      def record_hash(dir, filename, scope)
        if manifest_state(dir) == :corrupt
          # Bozuk manifesti sessizce "heal" etmek (yalnızca yeni kaydı yazmak) diğer
          # kayıtlı overlay'leri tahliye eder; bunun yerine kaydı reddet.
          raise "cannot record '#{filename}': .manifest.json in #{dir} is corrupt; delete it and re-record overlays"
        end

        path = File.join(dir, filename)
        hash = Digest::SHA256.hexdigest(normalize_content(File.binread(path)))
        manifest = load_manifest(dir)
        manifest[filename] = {
          "sha256" => hash,
          "scope" => scope.to_s,
          "created_at" => Time.now.iso8601
        }
        save_manifest(dir, manifest)
      end

      def verify_integrity(file_path, dir, bootstrap_eligible: false)
        return :trusted if trust_mode?

        basename = File.basename(file_path)
        manifest = load_manifest(dir)
        current_content = File.exist?(file_path) ? File.binread(file_path) : ""
        current_hash = Digest::SHA256.hexdigest(normalize_content(current_content))

        if manifest.key?(basename)
          # Known file — verify hash
          expected_hash = manifest[basename]["sha256"]
          if current_hash == expected_hash
            :verified
          else
            warn "[SECURITY] Integrity check failed for overlay '#{basename}': file modified " \
                 "since synthesis. Skipping. (expected: #{expected_hash}, got: #{current_hash})"
            :rejected
          end
        elsif bootstrap_eligible && sentinel_content?(current_content)
          # Bootstrap (tek seferlik): yalnızca manifest dosyasının hiç var olmadığı ilk taramada,
          # sentinel başlıklı dosya kabul edilip hash'i manifest'e yazılır; uygunluk kararını
          # verified_dir_entries taramanın başında verir. Manifest varken bootstrap asla çalışmaz.
          scope_match = current_content.match(/# Scope:\s*(.*)/)
          scope = scope_match ? scope_match[1].strip : "unknown"

          manifest[basename] = {
            "sha256" => current_hash,
            "scope" => scope,
            "created_at" => Time.now.iso8601
          }
          save_manifest(dir, manifest)
          :bootstrapped
        else
          warn "[SECURITY] Unknown overlay file '#{basename}' not in manifest. Skipping."
          :rejected
        end
      end

      def save_command(name, code, scope: :project, description: "Custom command")
        clean_name = name.to_s.downcase.delete_prefix("!").gsub(/[^a-z0-9_:]/, "_")
        target_dir = scope.to_sym == :global ? global_commands_dir : project_commands_dir
        FileUtils.mkdir_p(target_dir)

        filename = "#{clean_name.gsub(':', '_')}.rb"
        file_path = File.join(target_dir, filename)
        header = <<~RUBY
          # frozen_string_literal: true
          #{COMMAND_SENTINEL} !#{clean_name}
          # Scope: #{scope}
          # Description: #{description}

        RUBY

        File.write(file_path, "#{header}#{code.strip}\n")
        record_hash(target_dir, filename, scope)
        { ok: true, path: file_path, name: clean_name, scope: scope }
      rescue StandardError => e
        { ok: false, error: e.message }
      end

      # Delete a synthesized command from disk and manifest. Symmetric to
      # save_command: same clean_name normalization, scope→dir selection and
      # { ok:, error: } shape. Fail-closed on a corrupt manifest — never wipe
      # it with {} (mirror the record_hash guard on the save path).
      def delete_command(name, scope: :project)
        clean_name = name.to_s.downcase.delete_prefix("!").gsub(/[^a-z0-9_:]/, "_")
        target_dir = scope.to_sym == :global ? global_commands_dir : project_commands_dir
        filename = "#{clean_name.gsub(':', '_')}.rb"
        file_path = File.join(target_dir, filename)

        raise "cannot delete '#{filename}': .manifest.json in #{target_dir} is corrupt; delete it and re-record overlays" if manifest_state(target_dir) == :corrupt

        manifest = load_manifest(target_dir)
        manifest.delete(filename)
        save_manifest(target_dir, manifest)

        FileUtils.rm_f(file_path)
        { ok: true, name: clean_name, scope: scope, path: file_path }
      rescue StandardError => e
        { ok: false, error: e.message }
      end

      def list_commands
        # Global commands; project commands (can override global) — sıra ve dönüş şekli korunur.
        verified_dir_entries(global_commands_dir, :global) +
          verified_dir_entries(project_commands_dir, :project)
      end

      def load_all(shell, _manager = nil)
        loaded = []
        list_commands.each do |cmd_meta|
          next if cmd_meta[:integrity] == :rejected

          file_path = cmd_meta[:path]
          cmd_name = cmd_meta[:name]

          begin
            code = File.read(file_path)
            eval_command(shell, cmd_name, code, cmd_meta[:scope])
            loaded << cmd_name
          rescue StandardError => e
            warn "[OVERLAY] Failed to load custom command '#{cmd_name}' from #{file_path}: #{e.class}: #{e.message}"
          end
        end
        loaded
      end

      def eval_command(shell, cmd_name, code, scope)
        desc_match = code.match(/# Description:\s*(.*)/)
        description = desc_match ? desc_match[1].strip : "Custom #{scope} command"

        proc_handler = if code.include?("->") || code.include?("lambda") || code.include?("proc")
                         eval(code, clean_eval_binding, __FILE__, __LINE__) # rubocop:disable Security/Eval -- overlay çekirdeği; sentez anında guard desen kontrolünden geçti VE disk hash'i manifestle doğrulandı (verify_integrity)
                       else
                         eval("->(args, output, shell) {\n#{code}\n}", clean_eval_binding, __FILE__, __LINE__) # rubocop:disable Security/Eval -- overlay çekirdeği; sentez anında guard desen kontrolünden geçti VE disk hash'i manifestle doğrulandı (verify_integrity)
                       end

        registered = shell.register_command(cmd_name, description: "#{description} [#{scope}]", custom: true) do |args, ctx|
          # Arity contract mirrored from SynthesizeCommandTool: 2-arity
          # handlers receive the per-dispatch CommandContext (its IO
          # methods delegate to the active capture stream), 3-arity keeps
          # the raw shell for trusted persisted code. Direct invocation
          # outside dispatch has no ctx: use the shell's factory, or its
          # raw output for shell doubles predating the contract. The warn
          # keeps a ctx-forgetting dispatch site visible instead of
          # silently auto-healed.
          out_ctx = if ctx
                      ctx
                    elsif shell.respond_to?(:command_context)
                      warn "[rubik] overlay command invoked without a dispatch CommandContext" unless ENV["RUBIK_TEST"]
                      shell.command_context
                    else
                      shell.output
                    end
          if proc_handler.arity == 1
            proc_handler.call(args)
          elsif proc_handler.arity == 2
            proc_handler.call(args, out_ctx)
          else
            proc_handler.call(args, out_ctx.respond_to?(:out) ? out_ctx.out : out_ctx, shell)
          end
        end
        # register_command, built-in çakışmasında sessizce false döner; red,
        # load_all'un [OVERLAY] yoluna düşsün ve loaded listesi doğru kalsın.
        raise "registration refused for '#{cmd_name}' (name collides with a built-in)" if registered == false
      end

      def save_tool(name, code, scope: :project, description: "Custom native tool", params_schema: nil, risk: :execute)
        clean_name = name.to_s.downcase.gsub(/[^a-z0-9_]/, "_")
        target_dir = scope.to_sym == :global ? global_tools_dir : project_tools_dir
        FileUtils.mkdir_p(target_dir)

        filename = "#{clean_name}.rb"
        file_path = File.join(target_dir, filename)
        schema_json = params_schema ? JSON.dump(params_schema) : "{}"
        header = <<~RUBY
          # frozen_string_literal: true
          #{TOOL_SENTINEL} #{clean_name}
          # Scope: #{scope}
          # Risk: #{risk}
          # Description: #{description}
          # Schema: #{schema_json}

        RUBY

        File.write(file_path, "#{header}#{code.strip}\n")
        record_hash(target_dir, filename, scope)
        { ok: true, path: file_path, name: clean_name, scope: scope }
      rescue StandardError => e
        # Audit 1: surfaced to the caller as ok:false and logged under RUBIK_DEBUG.
        warn "[WARN] [OVERLAY] Failed to save tool '#{name}' to #{file_path}: #{e.class}: #{e.message}" if ENV["RUBIK_DEBUG"]
        { ok: false, error: e.message }
      end

      # Delete a synthesized tool from disk and manifest. Symmetric to
      # save_tool: same clean_name normalization, scope→dir selection and
      # { ok:, error: } shape. Fail-closed on a corrupt manifest — never wipe
      # it with {} (mirror the record_hash guard on the save path).
      def delete_tool(name, scope: :project)
        clean_name = name.to_s.downcase.gsub(/[^a-z0-9_]/, "_")
        target_dir = scope.to_sym == :global ? global_tools_dir : project_tools_dir
        filename = "#{clean_name}.rb"
        file_path = File.join(target_dir, filename)

        raise "cannot delete '#{filename}': .manifest.json in #{target_dir} is corrupt; delete it and re-record overlays" if manifest_state(target_dir) == :corrupt

        manifest = load_manifest(target_dir)
        manifest.delete(filename)
        save_manifest(target_dir, manifest)

        FileUtils.rm_f(file_path)
        { ok: true, name: clean_name, scope: scope, path: file_path }
      rescue StandardError => e
        { ok: false, error: e.message }
      end

      def list_tools
        verified_dir_entries(global_tools_dir, :global) +
          verified_dir_entries(project_tools_dir, :project)
      end

      def load_tools(tool_registry)
        loaded = []
        list_tools.each do |t_meta|
          next if t_meta[:integrity] == :rejected

          code = File.read(t_meta[:path])
          tool_inst = eval_tool(t_meta[:name], code, t_meta[:scope])
          if tool_inst
            tool_registry.register(tool_inst, origin: :overlay)
            loaded << t_meta[:name]
          else
            warn "[OVERLAY] Custom tool '#{t_meta[:name]}' from #{t_meta[:path]} did not evaluate to a usable tool."
          end
        rescue StandardError => e
          warn "[OVERLAY] Failed to load custom tool '#{t_meta[:name]}' from #{t_meta[:path]}: #{e.class}: #{e.message}"
        end
        loaded
      end

      def eval_tool(name, code, scope)
        desc_match = code.match(/# Description:\s*(.*)/)
        description = desc_match ? desc_match[1].strip : "Custom #{scope} tool"

        schema_match = code.match(/# Schema:\s*(.*)/)
        schema = if schema_match
                   begin
                     JSON.parse(schema_match[1])
                   rescue
                     {}
                   end
                 else
                   {}
                 end

        risk_match = code.match(/# Risk:\s*(.*)/)
        risk = risk_match ? risk_match[1].strip.to_sym : :execute

        evaluated = eval(code, clean_eval_binding, __FILE__, __LINE__) # rubocop:disable Security/Eval -- overlay çekirdeği; sentez anında guard desen kontrolünden geçti VE disk hash'i manifestle doğrulandı (verify_integrity)
        if evaluated.is_a?(Class) && evaluated < Rubik::Tools::BaseTool
          evaluated.new
        elsif evaluated.respond_to?(:call)
          Class.new(Rubik::Tools::BaseTool) do
            define_method(:initialize) do
              super(name: name, description: "#{description} [#{scope}]", risk: risk, params_schema: schema)
              @handler = evaluated
            end

            define_method(:execute) do |args = {}|
              @handler.call(args)
            end
          end.new
        end
      end

      private

      # Ortak kaçış kapısı predicate'i: iki güvenlik kapısının (verify_integrity,
      # verified_dir_entries) kopya ENV kontrolüyle sürünerek ayrışmasını engeller.
      def trust_mode?
        ENV["RUBIK_TRUST_OVERLAYS"] == "1"
      end

      # Üç durumlu manifest yoklaması: :missing / :valid / :corrupt.
      # load_manifest bilinçli olarak değiştirilmedi; kayıt yolu (record_hash) ve
      # save_command/save_tool akışları bozuk manifestte {} davranışına bağlı kalıyor.
      def manifest_state(dir)
        path = manifest_path(dir)
        return :missing unless File.exist?(path)

        parsed = JSON.parse(File.read(path))
        parsed.is_a?(Hash) ? :valid : :corrupt
      rescue JSON::ParserError
        :corrupt
      end

      # Dizin taraması başına bootstrap uygunluğu: manifest dosyası hiç yokken sentinel
      # başlıklı dosyalar bir kez kabul edilir; manifest varken kayıtsız dosyalar her
      # koşulda reddedilir. Bozuk manifest, o taramada dizini tamamen dışlar.
      def verified_dir_entries(dir, scope)
        files = Dir.glob(File.join(dir, "*.rb"))

        # Kaçış kapısı: trust modu manifest durumundan bağımsız olarak tüm dosyaları güvenilir sayar.
        return files.map { |f| { name: File.basename(f, ".rb"), scope: scope, path: f, integrity: :trusted } } if trust_mode?

        case manifest_state(dir)
        when :corrupt
          warn "[SECURITY] Corrupt manifest in #{dir}; skipping #{files.size} overlay(s)."
          []
        when :missing
          if bootstrap_opt_in?
            bootstrapped = 0
            entries = files.map do |f|
              integrity = verify_integrity(f, dir, bootstrap_eligible: true)
              bootstrapped += 1 if integrity == :bootstrapped
              { name: File.basename(f, ".rb"), scope: scope, path: f, integrity: integrity }
            end
            if bootstrapped.positive?
              warn "[BOOTSTRAP] First scan of #{dir}: recorded #{bootstrapped} overlay(s) into .manifest.json; " \
                   "unknown files will be rejected from now on."
            end
            entries
          else
            # Opt-in yokken ilk tarama bile bootstrap yapmaz (yabancı depo klonu senaryosu);
            # sentinel dosyalar görünür tek satırlık bildirimle atlanır.
            gated = files.count { |f| sentinel_file?(f) }
            if gated.positive?
              warn "[BOOTSTRAP] #{gated} unrecorded sentinel overlay(s) in #{dir} were skipped; " \
                   "first-time acceptance requires RUBIK_BOOTSTRAP_OVERLAYS=1."
            end
            files.map { |f| { name: File.basename(f, ".rb"), scope: scope, path: f, integrity: verify_integrity(f, dir) } }
          end
        else
          files.map { |f| { name: File.basename(f, ".rb"), scope: scope, path: f, integrity: verify_integrity(f, dir) } }
        end
      end

      # İlk-bootstrap açık rızası: manifest'siz dizindeki sentinel dosyaların ilk taramada
      # kabul edilmesi ancak bu env ile mümkündür (kayıt kalıcıdır; sonraki açılışlar env'siz çalışır).
      def bootstrap_opt_in?
        ENV["RUBIK_BOOTSTRAP_OVERLAYS"] == "1"
      end

      def sentinel_content?(content)
        content.include?(COMMAND_SENTINEL) || content.include?(TOOL_SENTINEL)
      end

      def sentinel_file?(path)
        File.file?(path) && sentinel_content?(File.binread(path))
      rescue StandardError => e
        # Audit 1: unreadable => fail-closed (not a sentinel), but traceable.
        warn "[WARN] [OVERLAY] sentinel check failed for #{path}: #{e.class}: #{e.message}" if ENV["RUBIK_DEBUG"]
        false
      end

      def clean_eval_binding
        Object.new.instance_eval { binding }
      end
    end
  end
end
