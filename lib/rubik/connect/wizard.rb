# frozen_string_literal: true

require_relative "models_dev"
require_relative "probes"
require_relative "../llm/openai_compatible"
require_relative "../ui/frame"

module Rubik
  module Connect
    # The provider connect wizard: one flow shared by `!connect` (REPL),
    # `rubik connect` (CLI) and the boot offer. Gathers a provider binding
    # as an in-memory plan, live-validates it, and only then commits —
    # through the existing Config verbs, so SecretPolicy routes the
    # credential into the OS keyring and cancellation before the confirm
    # step is a zero-write event.
    #
    # Commit ordering: provider spec first (one atomic Hash write carrying
    # the full models array), then role specs. An interrupt mid-commit
    # leaves an inert-but-valid provider; roles re-attach with `!model set`.
    class Wizard
      CUSTOM_LABEL = "Özel uç nokta / Custom endpoint"
      MANUAL_MODEL_LABEL = "✎ Elle gir / Enter manually"
      S_PROVIDER = "Sağlayıcı seçin / Choose a provider:"
      S_ALL_CATALOG = "Tüm katalog / All catalog providers:"
      S_ENDPOINT = "Uç nokta / Endpoint:"
      S_AUTH = "Kimlik doğrulama / Authentication:"
      S_MODEL = "Model seçin (önerilen üstte) / Pick a model (recommended first):"
      S_ROLES = "Roller / Roles:"
      MAX_PROBE_ATTEMPTS = 5

      ROLE_DEFAULT = "Sadece default / default only"
      ROLE_DEFAULT_FAST = "default + fast"
      ROLE_ALL = "default + fast + advanced"
      ROLE_NONE = "Rol atama yok / no role binding"
      ROLE_MENU = [ROLE_DEFAULT, ROLE_DEFAULT_FAST, ROLE_ALL, ROLE_NONE].freeze

      AUTH_KEY = "API anahtarı gireceğim / I'll enter an API key"
      AUTH_ENV = "Ortam değişkeni kullanacağım / I'll use an environment variable"
      AUTH_SKIP = "Şimdilik atla / Skip for now"

      def initialize(config:, ui:, io:, scope: :global, refresh: nil, catalog_loader: nil, probe: nil)
        @config = config
        @ui = ui # prompt port: questions + live-terminal notices
        # @io is the transcript sink (REPL TeeIO capture / CLI stdout):
        # header, summary and result lines land in the session record too.
        @io = io
        @scope = scope
        @refresh = refresh
        @catalog_loader = catalog_loader || -> { ModelsDev.load(home_dir: @config.home_dir) }
        @probe = probe || Probes
        @catalog = {}
        @notes = []
      end

      # -> {ok: true, provider:, model:, roles:, scope:, notes: []}
      #  | {ok: false, reason: :cancelled|:non_interactive|:write_failed,
      #     error:, provider:, notes: []}
      def run
        return { ok: false, reason: :non_interactive, error: nil, provider: nil, notes: [] } unless @ui.interactive?

        render_header
        load_catalog
        plan = select_provider
        plan = ask_endpoint(plan) if plan.is_a?(Hash)
        plan = ask_credential(plan) if plan.is_a?(Hash)
        plan = ask_model(plan) if plan.is_a?(Hash)
        roles = ask_roles if plan.is_a?(Hash)
        return finish_abort(:cancelled) unless plan.is_a?(Hash) && roles.is_a?(Array)

        plan[:roles] = roles
        return finish_abort(:cancelled) unless confirm(plan)

        commit(plan)
      end

      private

      def finish_abort(reason)
        @ui.puts @ui.paint("Sihirbaz iptal edildi — hiçbir şey yazılmadı / Wizard cancelled — nothing was written.", :dim)
        { ok: false, reason: reason, error: nil, provider: nil, notes: @notes }
      end

      def render_header
        @io.puts Rubik::UI::Frame.draw(
          [@ui.paint("Sağlayıcı ekle, anahtarı doğrula, modeli bağla", :bold),
           @ui.paint("Add a provider, validate its key, bind a model", :dim)],
          theme: @ui.theme, width: 78,
          title: @ui.paint("⚙ BAĞLANTI SİHİRBAZI / CONNECT WIZARD", :accent)
        )
      end

      def load_catalog
        result = @ui.spinner("Katalog indiriliyor / Fetching model catalog…") { @catalog_loader.call }
        @catalog = result[:catalog].is_a?(Hash) ? result[:catalog] : {}
        case result[:source]
        when :stale
          note("katalog önbelleği bayat — eski katalog gösteriliyor / showing a stale cached catalog")
        when :none
          note("katalog alınamadı — manuel mod / catalog unavailable — manual mode")
        end
      end

      def note(text)
        @notes << text
      end

      # ── Step 1: provider ──────────────────────────────────────────────
      def select_provider
        choices = []
        lookup = {}
        ModelsDev::PINNED.each do |pin|
          entry = @catalog[pin[:catalog_id]].is_a?(Hash) ? @catalog[pin[:catalog_id]] : nil
          api = catalog_api_for(pin, entry)
          label = "#{pin[:label]}  ·  #{host_of(api)}"
          choices << label
          lookup[label] = { id: pin[:id], label: pin[:label], type: pin[:type], base_url: api,
                            catalog_id: pin[:catalog_id], catalog_entry: entry }
        end
        choices << CUSTOM_LABEL
        lookup[CUSTOM_LABEL] = :custom

        compatible = ModelsDev.compatible_providers(@catalog)
        all_label = "Tüm katalog / All catalog (#{compatible.size})"
        if compatible.any?
          choices << all_label
          lookup[all_label] = :all
        end

        chosen = @ui.select(S_PROVIDER, choices, default: choices.first)
        return :cancelled unless chosen.is_a?(String)

        case lookup[chosen]
        when :custom then ask_custom_provider
        when :all then pick_from_catalog(compatible)
        else lookup[chosen]
        end
      end

      # Online runs prefer the catalog's own api field (catalog updates win
      # over hardcoded bases); PINNED carries the offline fallback. Google's
      # catalog api is the native Gemini API rubik cannot speak, so that
      # pinned row opts out via use_catalog_api: false.
      def catalog_api_for(pin, entry)
        return pin[:api] if pin[:use_catalog_api] == false

        api = entry.is_a?(Hash) ? entry["api"] : nil
        api.is_a?(String) && !api.empty? ? api : pin[:api]
      end

      def ask_custom_provider
        name = @ui.ask("Sağlayıcı adı / Provider name:")
        return :cancelled unless name.is_a?(String) && !ModelsDev.provider_key(name).empty?

        type = @ui.select("Tür / Type:", ["openai_compatible", "anthropic", "ollama"], default: "openai_compatible")
        return :cancelled unless type.is_a?(String)

        { id: ModelsDev.provider_key(name), label: name.strip, type: type,
          base_url: nil, catalog_id: nil, catalog_entry: nil }
      end

      def pick_from_catalog(compatible)
        choices = compatible.map { |p| "#{p[:name]} (#{p[:id]})" }
        lookup = compatible.zip(choices).to_h { |p, label| [label, p] }
        chosen = @ui.select(S_ALL_CATALOG, choices)
        return :cancelled unless chosen.is_a?(String)

        picked = lookup[chosen]
        { id: ModelsDev.provider_key(picked[:id]), label: picked[:name], type: "openai_compatible",
          base_url: picked[:api], catalog_id: picked[:id], catalog_entry: picked[:entry] }
      end

      # ── Step 2: endpoint ─────────────────────────────────────────────
      def ask_endpoint(plan)
        # AnthropicProvider honors no endpoint parameter — asking would
        # invite a gateway URL the registry silently ignores; custom
        # gateways belong to the custom/openai_compatible branch.
        return plan if plan[:type] == "anthropic"

        default = plan[:base_url] || (plan[:type] == "ollama" ? "http://localhost:11434" : "")
        until (answer = request_endpoint(default)).is_a?(String) && valid_endpoint?(answer)
          return :cancelled unless answer.is_a?(String)

          @ui.puts @ui.paint("⚠ Geçersiz uç nokta / Endpoint must start with http:// or https://", :error)
        end

        plan[:base_url] = answer.strip
        plan
      end

      def request_endpoint(default)
        answer = @ui.ask(S_ENDPOINT, default: default)
        answer.is_a?(String) ? answer.strip : answer
      end

      def valid_endpoint?(answer)
        answer.to_s.start_with?("http://", "https://")
      end

      # ── Step 3: credential + live validation ─────────────────────────
      def ask_credential(plan)
        return plan if plan[:type] == "ollama"

        choice = @ui.select(S_AUTH, [AUTH_KEY, AUTH_ENV, AUTH_SKIP], default: AUTH_KEY)
        return :cancelled unless choice.is_a?(String)

        if choice == AUTH_ENV
          env = @ui.ask("Ortam değişkeni / Environment variable name:")
          return :cancelled unless env.is_a?(String) && !env.strip.empty?

          plan[:api_key_env] = env.strip
        elsif choice == AUTH_SKIP
          note("anahtar sonra ayarlanacak — doğrulama atlandı / key deferred — validation skipped")
        else
          key = key_with_validation(plan)
          return :cancelled if key == :cancelled
          return plan if key.nil? # deferred — the note is already recorded

          plan[:api_key] = key
        end
        plan
      end

      # Probe → menu loop for auth failures / unreachable endpoints.
      # Terminates by: storing a validated key, storing unvalidated (user
      # chose save-anyway), deferring (empty entry), cancelling, or burning
      # MAX_PROBE_ATTEMPTS (save last key with a note).
      def key_with_validation(plan)
        last_key = nil
        attempts = 0
        while attempts < MAX_PROBE_ATTEMPTS
          key = @ui.secret("#{plan[:label]} API anahtarı / API key:")
          return :cancelled unless key.is_a?(String) # interrupt / prompt failure

          if key.strip.empty? # empty entry = defer, same as AUTH_SKIP
            note("anahtar sonra ayarlanacak — doğrulama atlandı / key deferred — validation skipped")
            return nil
          end

          last_key = key
          attempts += 1
          result = @ui.spinner("Doğrulanıyor / Validating…") { probe_plan(plan, key) }
          if result[:ok]
            plan[:live_models] = result[:models] if result[:models].any?
            return key
          end

          note(result[:note]) if result[:note]

          action = @ui.select(failure_question(result), failure_menu(result))
          return :cancelled unless action.is_a?(String)

          return last_key if action.start_with?("Doğrulamadan", "Yine de")
          return :cancelled if action.start_with?("İptal")
        end
        note("doğrulama denemeleri tükendi — kaydediliyor / validation attempts exhausted — saving unvalidated")
        last_key
      end

      def probe_plan(plan, key)
        if plan[:type] == "anthropic"
          @probe.anthropic(api_key: key)
        else
          @probe.openai_compatible(plan[:base_url], api_key: key)
        end
      end

      def failure_question(result)
        if result[:auth_failed]
          "Anahtar reddedildi (#{result[:note]}). Ne yapalım? / Key rejected. What now?"
        else
          "Uç nokta doğrulanamadı (#{result[:note]}). Ne yapalım? / Could not validate the endpoint. What now?"
        end
      end

      def failure_menu(result)
        if result[:auth_failed]
          ["Anahtarı yeniden gir / Re-enter key", "Doğrulamadan kaydet / Save without validation", "İptal / Cancel"]
        else
          ["Anahtarı yeniden gir / Re-enter key", "Yine de kaydet / Save anyway", "İptal / Cancel"]
        end
      end

      # ── Step 4: model ────────────────────────────────────────────────
      def ask_model(plan)
        menu = build_model_menu(plan)
        chosen = @ui.select(S_MODEL, menu[:choices], default: menu[:default])
        return :cancelled unless chosen.is_a?(String)

        if chosen == MANUAL_MODEL_LABEL
          name = @ui.ask("Model adı / Model name:")
          return :cancelled unless name.is_a?(String) && !name.strip.empty?

          limit = @ui.ask("Bağlam sınırı (token) / Context limit (tokens):", default: ModelsDev::DEFAULT_CONTEXT_LIMIT.to_s)
          return :cancelled unless limit.is_a?(String)

          plan[:model] = { name: name.strip, context_limit: parse_limit(limit) || ModelsDev::DEFAULT_CONTEXT_LIMIT }
        else
          picked = menu[:lookup][chosen]
          plan[:model] = { name: picked[:id], context_limit: picked[:context_limit] || ModelsDev::DEFAULT_CONTEXT_LIMIT }
        end
        plan
      end

      # "200k" / "1M" suffixes are how users type context windows; bare
      # integers pass through, junk returns nil (caller falls back to the
      # default limit).
      def parse_limit(raw)
        match = raw.to_s.strip.downcase.match(/\A(\d+(?:\.\d+)?)\s*(k|m)?\z/)
        return nil unless match

        value = match[1].to_f
        value *= 1000 if match[2] == "k"
        value *= 1_000_000 if match[2] == "m"
        value.to_i.positive? ? value.to_i : nil
      end

      # Live model ids from the probes win (they are what the endpoint
      # actually serves); the catalog list is the fallback, annotated with
      # context limits and tool support. Manual entry is always available —
      # it is the whole flow when catalog AND live listing are absent. For
      # ollama the /api/tags listing doubles as the liveness probe and is
      # fetched here (there is no credential step to hang it on).
      def build_model_menu(plan)
        lookup = {}
        fetch_live_models(plan)
        live = plan[:live_models].is_a?(Array) && plan[:live_models].any?
        catalog_models = ModelsDev.models_for(@catalog, plan[:catalog_id])
        if live
          by_id = catalog_models.to_h { |m| [m[:id], m] }
          live_entries = plan[:live_models].map { |id| by_id[id.to_s] || { id: id.to_s, context_limit: nil, tool_call: false } }
          live_entries.each do |m|
            label = m[:context_limit] ? "#{m[:id]} · #{compact_ctx(m[:context_limit])}#{' · tools' if m[:tool_call]}" : m[:id]
            lookup[label] = m
          end
          recommended = ModelsDev.default_model(live_entries.select { |m| m[:context_limit] }) || live_entries.first
        else
          catalog_models.each do |m|
            label = "#{m[:id]} · #{compact_ctx(m[:context_limit])}#{' · tools' if m[:tool_call]}"
            lookup[label] = m
          end
          recommended = ModelsDev.default_model(catalog_models)
        end
        lookup[MANUAL_MODEL_LABEL] = nil
        # The pre-highlighted choice: best catalog-matched live model (or
        # first live id), or the catalog's recommended model mapped back to
        # its label.
        default_label = recommended && lookup.key(recommended) ? lookup.key(recommended).to_s : MANUAL_MODEL_LABEL
        { choices: lookup.keys, lookup: lookup, default: default_label }
      end

      def fetch_live_models(plan)
        return unless plan[:type] == "ollama"

        result = @ui.spinner("Ollama modelleri alınıyor / Fetching Ollama models…") { @probe.ollama(plan[:base_url]) }
        if result[:ok]
          plan[:live_models] = result[:models]
        else
          note(result[:note].to_s)
        end
      end

      def compact_ctx(limit)
        return "?" if limit.nil?

        "#{(limit.to_f / 1000).round}k"
      end

      # ── Step 5: roles ────────────────────────────────────────────────
      def ask_roles
        chosen = @ui.select(S_ROLES, ROLE_MENU, default: ROLE_DEFAULT)
        return :cancelled unless chosen.is_a?(String)

        case chosen
        when ROLE_DEFAULT then ["default"]
        when ROLE_DEFAULT_FAST then ["default", "fast"]
        when ROLE_ALL then ["default", "fast", "advanced"]
        else []
        end
      end

      # ── Step 6: confirm + commit ─────────────────────────────────────
      def confirm(plan)
        roles_desc = plan[:roles].empty? ? "—" : plan[:roles].join(", ")
        key_desc = if plan[:api_key_env]
                     "env: #{plan[:api_key_env]}"
                   elsif plan[:api_key].to_s.empty?
                     "yok / none"
                   else
                     "secret store'a yazılacak / stored via secret store"
                   end
        summary = [
          "#{@ui.paint('Sağlayıcı / Provider', :bold)}  : #{plan[:id]} (#{plan[:type]})",
          "#{@ui.paint('Uç nokta / Endpoint', :bold)}   : #{plan[:base_url]}",
          "#{@ui.paint('Model', :bold)}            : #{plan[:model][:name]} (#{compact_ctx(plan[:model][:context_limit])} ctx)",
          "#{@ui.paint('Roller / Roles', :bold)}      : #{roles_desc}",
          "#{@ui.paint('Anahtar / Key', :bold)}       : #{key_desc}",
          "#{@ui.paint('Kapsam / Scope', :bold)}      : #{scope_persist_label}"
        ]
        @io.puts Rubik::UI::Frame.draw(summary, theme: @ui.theme, width: 78,
                                                title: @ui.paint("⚙ BAĞLANTI ÖZETİ / CONNECTION SUMMARY", :accent))
        @ui.yes?("Kaydet / Save?", default: true) == true
      end

      def commit(plan)
        res = @config.set("providers.#{plan[:id]}", build_spec(plan), persist: @scope)
        unless res[:ok]
          @ui.puts @ui.paint("Yazma başarısız / Could not save: #{res[:error]}", :error)
          return { ok: false, reason: :write_failed, error: res[:error], provider: plan[:id], notes: @notes }
        end

        role_failures = bind_roles(plan)
        @refresh&.call
        render_success(plan, res, role_failures)

        { ok: true, provider: plan[:id], model: plan[:model][:name], roles: plan[:roles],
          scope: @scope, notes: @notes }
      end

      # Same storage shape !provider add writes; openai_compatible endpoints
      # get the same normalization (the registry re-normalizes on build, the
      # probe stays on the raw base). Compacted: ollama carries no api_key.
      def build_spec(plan)
        {
          "type" => plan[:type],
          "endpoint" => spec_endpoint(plan),
          "api_key" => plan[:api_key].to_s.empty? ? nil : plan[:api_key],
          "api_key_env" => plan[:api_key_env],
          "default_model" => plan[:model][:name],
          "models" => [{ "name" => plan[:model][:name], "context_limit" => plan[:model][:context_limit] }]
        }.compact
      end

      def spec_endpoint(plan)
        if plan[:type] == "openai_compatible"
          Rubik::LLM::OpenAICompatibleProvider.normalize_endpoint(plan[:base_url])
        else
          plan[:base_url]
        end
      end

      # An interrupt between the provider write and a failed role write
      # leaves an inert-but-valid provider; the note carries the exact
      # repair command. Role writes are the only routing-affecting
      # mutations, so they run last.
      def bind_roles(plan)
        failures = []
        plan[:roles].each do |role|
          res = @config.set_model_spec(role, provider: plan[:id], name: plan[:model][:name],
                                             endpoint: plan[:base_url], persist: @scope)
          next if res[:ok]

          failures << role
          note("rol '#{role}' yazılamadı — `!model set #{role} #{plan[:id]}/#{plan[:model][:name]}` ile tamamlayın / " \
               "role write failed — complete it with !model set")
          break
        end
        failures
      end

      def render_success(plan, res, role_failures)
        bound = plan[:roles] - role_failures
        bound_desc = bound.empty? ? "—" : bound.join(", ")
        @io.puts @ui.paint("✔ #{plan[:id]}/#{plan[:model][:name]} bağlandı / connected · roller / roles: #{bound_desc} " \
                           "[#{scope_persist_label}]", :success)

        info = res[:secret]
        if info
          if info[:stored]
            @io.puts "  API key stored via #{info[:backend]} secret store; the config file holds only a reference."
          elsif info[:warning]
            @io.puts "  Warning: #{info[:warning]}"
          end
        end
        @notes.each { |n| @io.puts "  Not / Note: #{n}" }
      end

      def scope_persist_label
        @scope == :project ? "Project level (.rubik/config.yml)" : "System level (~/.rubik/config.yml)"
      end

      def host_of(url)
        URI.parse(url.to_s).host.to_s
      rescue URI::Error
        url.to_s
      end
    end
  end
end
