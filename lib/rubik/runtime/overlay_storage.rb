# frozen_string_literal: true

require "fileutils"
require "json"
require "digest"
require "time"
# save_manifest atomik yazımı Platform.atomic_write kullanır; dosyanın tek başına
# require edilmesi durumunda da çözümlenebilsin diye açık yüklenir.
require_relative "../platform"
require_relative "../plugin/package_inventory"
require_relative "synthesized_command_context"
require_relative "synthesized_tool_context"

module Rubik
  module Runtime
    class OverlayStorage
      attr_reader :root_dir, :home_dir

      COMMAND_SENTINEL = "# Rubik Custom Command:"
      TOOL_SENTINEL = "# Rubik Custom Tool:"

      def initialize(root_dir: Dir.pwd, home_dir: ENV.fetch("HOME", nil), guard: nil, runtime_manager: nil, runtime_context: nil)
        @root_dir = File.expand_path(root_dir)
        @home_dir = File.expand_path(home_dir || ENV["HOME"] || ".")
        @guard = guard
        @runtime_manager = runtime_manager
        @runtime_context = runtime_context
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
        ensure_valid_overlay_dir!(dir)
        path = File.join(dir, ".manifest.json")
        ensure_contained_path!(path, dir)
        path
      end

      def load_manifest(dir)
        path = manifest_path(dir)
        return {} unless File.exist?(path)

        JSON.parse(File.read(path))
      rescue JSON::ParserError, ArgumentError
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
        ensure_valid_overlay_dir!(dir)
        refuse_corrupt_manifest!(dir, :record, filename)

        path = File.join(dir, filename)
        ensure_contained_path!(path, dir)
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

        unless safe_path_under?(file_path, dir)
          warn "[SECURITY] Path traversal attempt detected for overlay '#{file_path}'. Skipping."
          return :rejected
        end

        basename = File.basename(file_path)
        manifest = load_manifest(dir)
        current_content = File.exist?(file_path) ? File.binread(file_path) : ""
        current_hash = Digest::SHA256.hexdigest(normalize_content(current_content))

        if manifest.key?(basename)
          # Known file — verify hash. Constant-time comparison, same policy
          # as plugin package verification (Plugin::PackageInventory): hash
          # checks in the same integrity family must not diverge in how they
          # compare.
          expected_hash = manifest[basename]["sha256"]
          if Rubik::Plugin::PackageInventory.secure_compare(current_hash, expected_hash)
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
          # Kabul ÖNCE synthesis guard'ından geçer (Aday 07 ertelemesi): klonlanan depodaki
          # dosya bu ortamda sentezlenmemişti; reddedilen dosya manifest'e yazılmaz.
          verdict = screen_bootstrap_content(current_content, basename)
          return verdict unless verdict == :ok

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

      # Issue #407: the command/tool quadruplets collapse onto shared skeletons
      # (save / delete / load_entries in the private section) behind the Kind
      # adapter at the bottom of this file. Public surface unchanged: these
      # delegators keep the exact pre-refactor signatures and per-kind defaults.
      def save_command(name, code, scope: :project, description: "Custom command")
        save(COMMAND_KIND, name, code, scope: scope, description: description)
      end

      def delete_command(name, scope: :project)
        delete(COMMAND_KIND, name, scope: scope)
      end

      def list_commands
        # Global commands; project commands (can override global) — sıra ve dönüş şekli korunur.
        verified_dir_entries(global_commands_dir, :global) +
          verified_dir_entries(project_commands_dir, :project)
      end

      def load_all(shell, _manager = nil)
        load_entries(COMMAND_KIND, list_commands) do |name, code, scope|
          eval_command(shell, name, code, scope)
          true
        end
      end

      def eval_command(shell, cmd_name, code, scope)
        description = overlay_description(code, scope, "command")

        proc_handler = if code.include?("->") || code.include?("lambda") || code.include?("proc")
                         overlay_eval(code)
                       else
                         # Sealed default (issue #398): a bare body (no proc marker)
                         # used to be wrapped into the legacy 3-arity raw-shell shape;
                         # it is now wrapped into a SEALED 2-arity handler so default
                         # saves land on the SynthesizedCommandContext deny-list path
                         # below. The body's `output` channel is preserved — bound per
                         # invocation to the sealed context's output view, inside the
                         # wrapper's own scope (lambda-local, no shared binding
                         # mutation, clean_eval_binding isolation unchanged). `shell`
                         # is deliberately NOT bound: bare bodies referencing it now
                         # raise NameError — the intended hardening; the documented
                         # migration is authoring an explicit 3-arity proc (the
                         # operator-trusted escape hatch in the dispatch else branch).
                         overlay_eval("->(args, ctx) {\noutput = ctx.respond_to?(:out) ? ctx.out : nil\n#{code}\n}")
                       end

        registered = shell.register_command(cmd_name, description: "#{description} [#{scope}]", custom: true) do |args, ctx|
          if proc_handler.arity == 1
            proc_handler.call(args)
          elsif proc_handler.arity == 2
            warn "[rubik] overlay command invoked without a dispatch CommandContext" unless ctx || ENV["RUBIK_TEST"]
            sealed_ctx = if ctx.is_a?(Rubik::REPL::SynthesizedCommandContext)
                           ctx
                         else
                           output_io = if ctx.respond_to?(:out)
                                         ctx.out
                                       elsif ctx
                                         ctx
                                       elsif shell.respond_to?(:output)
                                         shell.output
                                       else
                                         $stdout
                                       end
                           runtime_ctx = if shell.respond_to?(:runtime_manager)
                                           shell.runtime_manager&.context
                                         elsif ctx.respond_to?(:runtime_manager)
                                           ctx.runtime_manager&.context
                                         end
                           Rubik::REPL::SynthesizedCommandContext.new(output: output_io, coeffects: runtime_ctx || {})
                         end
            proc_handler.call(args, sealed_ctx)
          else
            # Trust model (issue #398): this branch serves EXPLICITLY authored
            # 3-arity handlers only — bare-body saves are sealed by the default
            # wrap above. Such a handler receives the RAW interactive
            # CommandContext/shell (`guard`, `config`, `sandbox_runner`,
            # `buffer_manager`, etc. reachable), so the SealedCoeffects
            # deny-list does NOT apply here. That is the operator-trusted
            # bootstrap contract, anchored to the same trust vocabulary as the
            # eval sites above: guard-checked at synthesis (or bootstrap
            # acceptance) AND disk hash verified against the manifest
            # (verify_integrity), with RUBIK_TRUST_OVERLAYS=1 as the blanket
            # operator override. Authoring a 3-arity proc remains the
            # deliberate escape hatch — it must stay an explicit act.
            out_ctx = if ctx
                        ctx
                      elsif shell.respond_to?(:command_context)
                        warn "[rubik] overlay command invoked without a dispatch CommandContext" unless ENV["RUBIK_TEST"]
                        shell.command_context
                      else
                        shell.output
                      end
            proc_handler.call(args, out_ctx.respond_to?(:out) ? out_ctx.out : out_ctx, shell)
          end
        end
        # register_command, built-in çakışmasında sessizce false döner; red,
        # load_all'un [OVERLAY] yoluna düşsün ve loaded listesi doğru kalsın.
        raise "registration refused for '#{cmd_name}' (name collides with a built-in)" if registered == false
      end

      def save_tool(name, code, scope: :project, description: "Custom native tool", params_schema: nil, risk: :execute)
        save(TOOL_KIND, name, code, scope: scope, description: description, params_schema: params_schema, risk: risk)
      end

      def delete_tool(name, scope: :project)
        delete(TOOL_KIND, name, scope: scope)
      end

      def list_tools
        verified_dir_entries(global_tools_dir, :global) +
          verified_dir_entries(project_tools_dir, :project)
      end

      def load_tools(tool_registry, runtime_manager: nil, runtime_context: nil)
        load_entries(TOOL_KIND, list_tools) do |name, code, scope|
          tool_inst = eval_tool(name, code, scope, runtime_manager: runtime_manager, runtime_context: runtime_context)
          next false unless tool_inst

          tool_registry.register(tool_inst, origin: :overlay)
          true
        end
      end

      def eval_tool(name, code, scope, runtime_manager: nil, runtime_context: nil)
        description = overlay_description(code, scope, "tool")

        schema_match = code.match(/# Schema:\s*(.*)/)
        schema = if schema_match
                   begin
                     JSON.parse(schema_match[1])
                   rescue JSON::ParserError
                     # A malformed schema silently claiming "no arguments"
                     # hides real overlay bugs; keep loading (the tool is
                     # hash-verified) but say so.
                     warn "[rubik] overlay tool '#{name}' has a malformed '# Schema:' header; treating as no-arg schema"
                     {}
                   end
                 else
                   {}
                 end

        risk_match = code.match(/# Risk:\s*(.*)/)
        risk = risk_match ? risk_match[1].strip.to_sym : :execute
        # Hand-authored overlays may carry non-enum risk words; the
        # Declaration seam validates read/write/execute, so clamp
        # conservatively (execute = the most-guarded class) instead of
        # dropping the tool at load.
        risk = :execute unless [:read, :write, :execute].include?(risk)

        evaluated = overlay_eval(code)
        if evaluated.is_a?(Class) && evaluated < Rubik::Tools::BaseTool
          evaluated.new
        elsif evaluated.respond_to?(:call)
          runtime_mgr = runtime_manager || @runtime_manager
          runtime_ctx = runtime_context || @runtime_context || (runtime_mgr&.context if runtime_mgr.respond_to?(:context)) || Rubik::Runtime::Context.new
          Class.new(Rubik::Tools::BaseTool) do
            define_method(:initialize) do
              super(name: name, description: "#{description} [#{scope}]", risk: risk, params_schema: schema)
              @handler = evaluated
              @runtime_context = runtime_ctx
            end

            define_method(:execute) do |args = {}, ctx = nil|
              if @handler.respond_to?(:arity) && @handler.arity.zero?
                @handler.call
              elsif Rubik::Runtime::SynthesizedToolContext.accepts_context?(@handler)
                effective_ctx = ctx || @runtime_context || Rubik::Runtime::Context.new
                sealed_ctx = Rubik::Runtime::SynthesizedToolContext.wrap(effective_ctx)
                @handler.call(args, sealed_ctx)
              else
                @handler.call(args)
              end
            end
          end.new
        end
      end

      private

      # Single home of the fail-closed corrupt-manifest contract (issue #407):
      # record_hash and the delete skeleton refuse through this one raise.
      # `verb` reproduces the per-site messages ("cannot record '...'" vs
      # "cannot delete '...'"); the rest of the template is verbatim shared.
      def refuse_corrupt_manifest!(dir, verb, filename)
        return unless manifest_state(dir) == :corrupt

        # Bozuk manifesti sessizce "heal" etmek (yalnızca yeni kaydı yazmak) diğer
        # kayıtlı overlay'leri tahliye eder; bunun yerine kaydı reddet.
        raise "cannot #{verb} '#{filename}': .manifest.json in #{dir} is corrupt; delete it and re-record overlays"
      end

      # Shared save skeleton (issue #407): mkdir → containment check → header →
      # File.write → record_hash → { ok:, ... } → rescue { ok:false, error: }.
      # Header bytes are load-bearing twice over (eval_* parse them back with
      # regexes; the integrity manifest hashes the whole file), so emission must
      # stay byte-identical (pinned by the header-bytes tests).
      def save(kind, name, code, scope:, description:, params_schema: nil, risk: :execute)
        clean_name = kind.normalize_name(name)
        target_dir = kind_dir(kind, scope)
        FileUtils.mkdir_p(target_dir)

        filename = kind.filename_for(clean_name)
        file_path = File.join(target_dir, filename)
        ensure_contained_path!(file_path, target_dir)

        header = kind.header_lines(name: clean_name, scope: scope, description: description,
                                   risk: risk, schema: params_schema ? JSON.dump(params_schema) : "{}")
        File.write(file_path, "#{header.join("\n")}\n#{code.strip}\n")
        record_hash(target_dir, filename, scope)
        { ok: true, path: file_path, name: clean_name, scope: scope }
      rescue StandardError => e
        # Audit 1: surfaced to the caller as ok:false; tool kind logs under RUBIK_DEBUG.
        warn "[WARN] [OVERLAY] Failed to save #{kind.label} '#{name}' to #{file_path}: #{e.class}: #{e.message}" if kind.debug_warn && ENV["RUBIK_DEBUG"]
        { ok: false, error: e.message }
      end

      # Shared delete skeleton (issue #407). Symmetric to save for both kinds:
      # same clean_name normalization, scope→dir selection and { ok:, error: }
      # shape. Fail-closed on a corrupt manifest — never wipe it with {}
      # (single-homed in refuse_corrupt_manifest! above).
      def delete(kind, name, scope:)
        clean_name = kind.normalize_name(name)
        target_dir = kind_dir(kind, scope)
        filename = kind.filename_for(clean_name)
        file_path = File.join(target_dir, filename)
        ensure_contained_path!(file_path, target_dir)

        refuse_corrupt_manifest!(target_dir, :delete, filename)

        manifest = load_manifest(target_dir)
        manifest.delete(filename)
        save_manifest(target_dir, manifest)

        FileUtils.rm_f(file_path)
        { ok: true, name: clean_name, scope: scope, path: file_path }
      rescue StandardError => e
        { ok: false, error: e.message }
      end

      # Shared load skeleton (issue #407): iterate the verified listing → skip
      # rejected entries → containment check → read → evaluate via the block →
      # collect → rescue+warn. The block decides what "registration" means per
      # kind; a falsy result collects nothing and, for the tool kind
      # (warn_on_unusable), warns "did not evaluate to a usable tool". Warn
      # wording stays byte-identical to the pre-refactor messages.
      def load_entries(kind, entries)
        loaded = []
        entries.each do |meta|
          next if meta[:integrity] == :rejected

          name = meta[:name]
          file_path = meta[:path]
          target_dir = kind_dir(kind, meta[:scope])

          ensure_contained_path!(file_path, target_dir)
          code = File.read(file_path)
          if yield(name, code, meta[:scope])
            loaded << name
          elsif kind.warn_on_unusable
            warn "[OVERLAY] Custom #{kind.label} '#{name}' from #{file_path} did not evaluate to a usable tool."
          end
        rescue StandardError => e
          warn "[OVERLAY] Failed to load custom #{kind.label} '#{name}' from #{file_path}: #{e.class}: #{e.message}"
        end
        loaded
      end

      # Shared header-field readback (issue #407): both eval paths recover the
      # Description line with the same regex and default text.
      def overlay_description(code, scope, kind_label)
        desc_match = code.match(/# Description:\s*(.*)/)
        desc_match ? desc_match[1].strip : "Custom #{scope} #{kind_label}"
      end

      # Single home of the overlay eval sink and its rubocop disable: the code
      # is guard-checked at synthesis (or bootstrap acceptance) and its disk
      # hash verified against the manifest before this runs.
      def overlay_eval(code)
        eval(code, clean_eval_binding, __FILE__, __LINE__) # rubocop:disable Security/Eval -- overlay çekirdeği; sentez anında (veya bootstrap kabulünde) guard kontrolünden geçti VE disk hash'i manifestle doğrulandı (verify_integrity)
      end

      # Kind-scoped directory selection: anything but :global lands in the
      # project tree (pre-refactor behavior for both kinds).
      def kind_dir(kind, scope)
        scope.to_sym == :global ? public_send(kind.global_dir) : public_send(kind.project_dir)
      end

      def ensure_valid_overlay_dir!(dir)
        allowed = [
          [project_commands_dir, @root_dir],
          [global_commands_dir, @home_dir],
          [project_tools_dir, @root_dir],
          [global_tools_dir, @home_dir]
        ]
        valid = allowed.any? do |allowed_dir, trusted_root|
          Platform.path_equal?(dir, allowed_dir) && Platform.resolved_path_under?(dir, trusted_root)
        end
        return if valid

        raise ArgumentError, "Invalid overlay directory: #{dir}"
      end

      def ensure_contained_path!(path, parent_dir)
        raise ArgumentError, "Path traversal attempt detected: #{path}" unless safe_path_under?(path, parent_dir)
      end

      def safe_path_under?(path, parent_dir)
        return false if path.nil? || parent_dir.nil?

        ensure_valid_overlay_dir!(parent_dir)

        # Lexical containment check first
        return false unless Platform.path_under?(path, parent_dir)

        # If path exists or parent exists, also check resolved path containment
        return Platform.resolved_path_under?(path, parent_dir) if File.exist?(path) || File.exist?(parent_dir)

        true
      rescue StandardError
        false
      end

      # Bootstrap kabul taramasında kullanılacak guard: kwarg'la geçilen örnek
      # (üretimde service catalog'un tek operatör-policy guard'ı) ya da lazy
      # default. Lazy çözüm bilinçli: overlay_storage.rb standalone require
      # edilebilen bir dosyadır; security/guard yalnızca tarama gerçekten
      # gerektiğinde yüklenir, load-order denetimi gerekmez.
      def bootstrap_guard
        @bootstrap_guard ||= begin
          require_relative "../security/guard"
          @guard || Rubik::Security::Guard.new
        end
      end

      # Aday 07'den ertelenen güvenlik kalemi: manifestsız dizindeki sentinel
      # dosya manifest'e yazılmadan önce synthesis guard'ından geçirilir.
      # Reddedilen (veya taranamayan) dosya manifest'e YAZILMAZ — sonraki tarama
      # yeniden tarar ve reddeder (sessiz heal, bozuk-manifest doktriniyle
      # çelişir); load_all/load_tools'un mevcut :rejected atlaması devreye girer.
      # Parse hatası guard içinde yutulur (çalıştırılamaz kod güvenlik olayı
      # değil); guard'ın kendisi patlarsa da dosya fail-closed reddedilir —
      # SystemStackError dahil: rakip içerikte derin yuvalama AST walk'ı
      # taşırebilir, tek dosyanın reddiyesi tüm taramayı çökertmemeli.
      # Bilinçli asimetri: dosyanın TAMAMI (Description/Schema başlığı dahil)
      # taranır — sentez anında yalnızca kod taranıyordu. Kabul kapısı daha
      # sıkı olmak güvenli yöndür; başlık metnine denk gelen nadir yanlış
      # pozitif dosyayı makinede yeniden kayıtla çözülür.
      # Emit doktrini (guard.rb run_synthesis_gate hükmü): güvenlik kararının
      # tek kullanıcı-yüzü izi $VERBOSE=nil altında da yaşamalıdır — $stderr.puts.
      def screen_bootstrap_content(content, basename)
        bootstrap_guard.verify_synthesis_safety!(content)
        :ok
      rescue Rubik::Security::BlockedWriteError => e
        $stderr.puts "[SECURITY] Bootstrap overlay '#{basename}' refused by synthesis guard: #{e.message}" # rubocop:disable Style/StderrPuts
        :rejected
      rescue StandardError, ScriptError, SystemStackError => e
        $stderr.puts "[SECURITY] Bootstrap overlay '#{basename}' could not be screened (#{e.class}: #{e.message}); refusing." # rubocop:disable Style/StderrPuts
        :rejected
      end

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

    # ── Private Kind adapter (issue #407) ──────────────────────────────────────
    # Defined at the bottom so the frozen instances below can reference the
    # sentinel constants declared in the class body above. Per-kind asymmetries
    # it parameterizes: name normalization (name_regex/strip_bang/colon_ok —
    # commands keep ':' in the name but substitute it in the filename), scope→
    # dir selection (global_dir/project_dir; anything but :global is project),
    # byte-exact header emission (sentinel/bang/metadata_lines), and the warn
    # asymmetries (debug_warn on save failure, warn_on_unusable on load).
    class OverlayStorage
      Kind = Struct.new(:label, :sentinel, :bang, :name_regex, :strip_bang, :colon_ok, :debug_warn,
                        :warn_on_unusable, :metadata_lines, :global_dir, :project_dir, keyword_init: true) do
        def normalize_name(raw)
          name = raw.to_s.downcase
          name = name.delete_prefix("!") if strip_bang
          name.gsub(name_regex, "_")
        end

        def filename_for(clean_name)
          "#{colon_ok ? clean_name.gsub(':', '_') : clean_name}.rb"
        end

        # Byte-exact header template: frozen-string line, sentinel line, Scope,
        # tool-only Risk/Schema lines around Description, trailing blank line.
        # eval_* parse these lines back and the integrity manifest hashes the
        # whole file, so every byte is contract (pinned by the header-bytes tests).
        def header_lines(name:, scope:, description:, risk:, schema:)
          lines = ["# frozen_string_literal: true",
                   "#{sentinel} #{bang}#{name}",
                   "# Scope: #{scope}"]
          lines << "# Risk: #{risk}" if metadata_lines
          lines << "# Description: #{description}"
          lines << "# Schema: #{schema}" if metadata_lines
          lines << ""
          lines
        end
      end

      COMMAND_KIND = Kind.new(label: "command", sentinel: COMMAND_SENTINEL, bang: "!", name_regex: /[^a-z0-9_:]/,
                              strip_bang: true, colon_ok: true, debug_warn: false, warn_on_unusable: false,
                              metadata_lines: false, global_dir: :global_commands_dir, project_dir: :project_commands_dir).freeze

      TOOL_KIND = Kind.new(label: "tool", sentinel: TOOL_SENTINEL, bang: "", name_regex: /[^a-z0-9_]/,
                           strip_bang: false, colon_ok: false, debug_warn: true, warn_on_unusable: true,
                           metadata_lines: true, global_dir: :global_tools_dir, project_dir: :project_tools_dir).freeze
    end
  end
end
