# frozen_string_literal: true

require_relative "budget"
require_relative "notices"

module Rubik
  module Orchestrator
    module Subagent
      # PM tarzı dispatch kısıtları (kullanıcı kararı 2026-10-01): bağlı
      # işler aynı anda ateşlenmez — FS (finish-to-start, varsayılan) öncül
      # tamamlanınca, SS (start-to-start) öncül İLK kez running'a geçince
      # bırakılır. Bekleyen spec bir Instance DEĞİL: thread yok, slot yok,
      # maliyet yok — bırakılınca gerçek spawn koreografisi oynar.
      # FF/SF v1'de bilinçli olarak desteklenmez (normalize_dep reddeder).
      class DeferredSpec
        attr_reader :id, :parent_id, :role, :type_name, :prompt, :system_prompt,
                    :workspace, :model, :max_steps, :deps, :provider
        attr_accessor :state, :cancel_reason

        def initialize(id:, role:, prompt:, type_name:, deps:, parent_id: "agent-0", system_prompt: nil,
                       workspace: "inherit", model: "inherit", max_steps: nil, provider: nil)
          @id = id
          @parent_id = parent_id
          @role = role
          @prompt = prompt
          @type_name = type_name
          @deps = deps
          @system_prompt = system_prompt
          @workspace = workspace
          @model = model
          @max_steps = max_steps
          @provider = provider
          @state = :queued
          @cancel_reason = nil
        end

        def queued? = @state == :queued
        def spawning? = @state == :spawning
        def cancelled? = @state == :cancelled

        # Duck-type yüzeyi: render'lar (list/status/wait) Instance ile
        # DeferredSpec'i AYIRT ETMEDEN kullanır — dallanma yok.
        def running? = false
        def active? = false
        def uptime = 0.0
        def started_at = nil
        def current_step = 0
        def result = nil
        def transcript_uri = nil
        def last_error = @cancel_reason
        def terminal_and_settled? = false
        def redeployable? = false
        # send_message'in deliverable? kapısı spec'e de değebilir (get,
        # kuyruk fallback'i döndürür): bir spec henüz doğmadı — teslim
        # edilemez.
        def deliverable? = false

        def depends_on = @deps.map { |d| "#{d[:id]}:#{d[:type]}" }

        def to_h
          { id: @id, parent_id: @parent_id, role: @role, type: @type_name, state: @state.to_s,
            depends_on: depends_on, current_step: 0, max_steps: @max_steps, uptime_seconds: 0.0,
            started_at: nil, ended_at: nil, transcript: nil, last_error: @cancel_reason,
            result_summary: nil, result: nil }
        end
      end

      # Saf graf fonksiyonları — kilit yok, IO yok, izole test edilebilir.
      module DependencyGraph
        module_function

        # "subagent-1" => FS varsayılan; {id:, type:} => FS|SS zorunlu.
        def normalize_dep(raw)
          return { id: raw.to_s.strip, type: "FS" } if raw.is_a?(String)

          id = raw.is_a?(Hash) ? (raw[:id] || raw["id"]) : nil
          raise ArgumentError, "Invalid dependency #{raw.inspect}: expected 'subagent-N' or {id:, type: 'FS'|'SS'}" if id.nil? || id.to_s.strip.empty?

          type = (raw[:type] || raw["type"] || "FS").to_s.upcase.strip
          unless ["FS", "SS"].include?(type)
            raise ArgumentError, "Unsupported dependency type '#{type}' (only FS and SS; " \
                                 "express finish-to-finish as FS on the successor and wait on both)"
          end

          { id: (raw[:id] || raw["id"]).to_s.strip, type: type }
        end

        def normalize_deps(list)
          Array(list).compact.map { |raw| normalize_dep(raw) }
        end

        # Üç renkli DFS; graf dışı komşular terminaldir (Instance'lar kenar
        # taşımaz). Döngü => yol ismiyle ArgumentError (hiçbir şey rezerve
        # edilmeden önce çağrılır — fail fast).
        def assert_acyclic!(graph)
          color = Hash.new(:unvisited)
          path = []
          graph.each_key do |start|
            next unless color[start] == :unvisited

            cycle = dfs(start, graph, color, path)
            raise ArgumentError, "Dependency cycle detected: #{cycle.join(' -> ')}" if cycle
          end
        end

        def dfs(node, graph, color, path)
          color[node] = :open
          path << node
          graph[node].each do |dep|
            next unless graph.key?(dep)

            return path.dup << dep if color[dep] == :open

            if color[dep] == :unvisited && (cycle = dfs(dep, graph, color, path))
              return cycle
            end
          end
          path.pop
          color[node] = :done
          nil
        end
      end

      # Supervisor düzlemi: rezervasyon, DAG doğrulama, bırakma motoru ve
      # iptal zinciri. Kilit sözleşmesi: @deferred mutasyonları @monitor
      # altında; emit ASLA kilit altında değil (topla-sonra-yay).
      module DependencySupervisor
        # Tool girişi: spec'leri normalize et, geçici id'ler ata, DAG'ı
        # doğrula (döngü/ölü öncül/bilinmeyen referans => ArgumentError,
        # HİÇBİR ŞEY rezerve edilmeden), sonra rezerve et ve hazır olanları
        # talep et. Dönen çiftler: [:launched, Instance] | [:queued, DeferredSpec].
        def spawn_batch(specs)
          reserved = []
          claimed = []
          @monitor.synchronize do
            base = @counter
            normalized = specs.each_with_index.map { |s, i| normalize_batch_spec(s, base + i + 1) }
            refute_dead_dependencies!(normalized)
            refute_unknown_dependencies!(normalized)
            DependencyGraph.assert_acyclic!(dependency_graph(normalized))
            normalized.each do |spec|
              @deferred[spec.id] = spec
              reserved << spec
            end
            @counter += normalized.size
            reserved.each do |spec|
              next unless dependencies_evaluate(spec) == :ready

              spec.state = :spawning
              claimed << spec
            end
          end

          reserved.map do |spec|
            claimed.include?(spec) ? launch_claimed!(spec) : resolve_outcome(spec)
          end
        end

        # Bırakma süpürmesi: rezervasyon sırasıyla, kuyruktakileri değerlendir.
        # :ready => talep et (atomik), :dead => iptal (öncül failed/kayboldu),
        # :blocked => bekle. İptal dalgaları SABİT NOKTAYA kadar kademelenir —
        # iptal edilmiş bir öncülün kendi bağımlıları da ölür (yoksa sonsuza
        # dek :queued sıkışır). Emit'ler kilidin DIŞINDA.
        def release_ready!
          claimed = []
          cancelled = []
          @monitor.synchronize do
            loop do
              wave = []
              @deferred.each_value do |spec|
                next unless spec.queued?

                case dependencies_evaluate(spec)
                when :ready
                  spec.state = :spawning
                  claimed << spec
                when :dead
                  cancel_spec!(spec, "predecessor failed or is no longer tracked")
                  wave << spec
                end
              end
              cancelled.concat(wave)
              break if wave.empty?
            end
          end
          announce_cancellations(cancelled)
          claimed.each { |spec| launch_claimed!(spec) }
        end

        # wait_for'un döngü koşulu için: hedef id'ler arasında hâlâ kuyrukta
        # bekleyen var mı? (Kuyruğa takılı zincir wait'i canlı tutar.)
        def deferred_pending?(ids)
          @monitor.synchronize do
            ids.any? do |id|
              spec = @deferred[id.to_s]
              spec && (spec.queued? || spec.spawning?)
            end
          end
        end

        # spawn kuyruğunun kuyruk-sweep'i (spawn tail) spec'i bu arada
        # bırakmış olabilir — etiketi GERÇEK duruma göre çöz (SS batch'inde
        # "QUEUED" diyip arka planda koşan spec yanıltır).
        def resolve_outcome(spec)
          @monitor.synchronize do
            inst = @instances[spec.id]
            return [:launched, inst] if inst
            return [:cancelled, spec] if spec.cancelled?

            [:queued, spec]
          end
        end

        private

        # Bir spesifikasyonun bağımlılık durumu: :ready / :blocked / :dead.
        # FS: öncül completed => hazır, failed => ölü, yoksa => bloklu.
        # SS: öncül hiç start olmadıysa (pending) => bloklu, aksi halde hazır.
        # Kuyrukta İPTAL edilmiş bir öncül her tip için ölüdür — yoksa
        # bağımlıları sonsuza dek :queued sıkışır (liveness).
        def dependencies_evaluate(spec)
          verdicts = spec.deps.map do |d|
            deferred_pred = @deferred[d[:id]]
            return :dead if deferred_pred&.cancelled?
            return :dead if deferred_pred.nil? && @instances[d[:id]].nil? && (@finished || {})[d[:id]].nil?

            inst = @instances[d[:id]] || (@finished || {})[d[:id]]

            if d[:type] == "FS"
              return :dead if inst&.failed?
              return :blocked if inst.nil? || !inst.completed?
            elsif inst.nil? || inst.pending?
              return :blocked
            end
            :ok
          end
          verdicts.all? { |v| v == :ok } ? :ready : :blocked
        end

        # Gerçek spawn koreografisi (child ctx, scoped registry, asker
        # provide, start_async + fresh unit). REZERVE ID KORUNUR — modelin
        # depends_on/wait ile referans verdiği kimlik bırakılan instance'ın
        # kimliğidir. Başarı => spec silinir; ConcurrencyExceeded =>
        # :queued'a geri (slot açılınca sıradaki süpürme alır); başka hata
        # => iptal (sessiz yeniden deneme döngüsü yok — fail loud). Spawn
        # ÖNCESİ/SONRASI kill yarışına karşı yeniden doğrulama: kill anlık
        # :spawning spec'i işaretler, burada uyumlu hale getirilir.
        def launch_claimed!(spec)
          @monitor.synchronize do
            return [:cancelled, spec] if spec.cancelled? || !@deferred.key?(spec.id)
          end

          inst = spawn(role: spec.role, prompt: spec.prompt, type_name: spec.type_name,
                       system_prompt: spec.system_prompt, parent_id: spec.parent_id,
                       workspace: spec.workspace, model: spec.model, max_steps: spec.max_steps,
                       provider: spec.provider, reserved_id: spec.id)

          killed_midflight = false
          @monitor.synchronize do
            killed_midflight = spec.cancelled?
            @deferred.delete(spec.id)
          end
          inst&.kill if killed_midflight
          killed_midflight ? [:cancelled, spec] : [:launched, inst]
        rescue ConcurrencyExceededError
          @monitor.synchronize { spec.state = :queued unless spec.cancelled? }
          [:queued, spec]
        rescue StandardError => e
          cancelled = nil
          @monitor.synchronize do
            cancel_spec!(spec, "launch failed: #{e.class}: #{e.message}")
            cancelled = spec
          end
          announce_cancellations([cancelled])
          [:cancelled, spec]
        end

        # Ölü öncülün kendi bağımlılarını da sabit noktaya kadar iptal et —
        # iptal edilmiş spec için gelecekte süpürme tetiklenmeyecek.
        def cancel_dependents_of(dead_ids)
          cancelled = []
          @monitor.synchronize do
            until dead_ids.empty?
              wave = @deferred.values.select do |spec|
                spec.queued? && spec.deps.any? { |d| dead_ids.include?(d[:id]) }
              end
              break if wave.empty?

              wave.each do |spec|
                cancel_spec!(spec, "predecessor failed or is no longer tracked")
                cancelled << spec
              end
              dead_ids = wave.map(&:id)
            end
          end
          cancelled
        end

        def cancel_spec!(spec, reason)
          spec.cancel_reason = reason
          spec.state = :cancelled
        end

        def announce_cancellations(specs)
          specs.each do |spec|
            Notices.emit(@event_bus, Notices::COMPLETED_EVENT,
                         { id: spec.id, role: spec.role, state: :cancelled, max_steps: spec.max_steps })
          end
        end

        def normalize_batch_spec(raw, provisional_id)
          role = raw[:role].to_s.strip
          prompt = raw[:prompt].to_s.strip
          raise ArgumentError, "Subagent role cannot be empty" if role.empty?
          raise ArgumentError, "Subagent prompt cannot be empty" if prompt.empty?

          DeferredSpec.new(
            id: "subagent-#{provisional_id}", role: role, prompt: prompt,
            type_name: (raw[:type_name] || "research").to_s.strip, deps: DependencyGraph.normalize_deps(raw[:depends_on]),
            system_prompt: raw[:system_prompt], workspace: (raw[:workspace] || "inherit").to_s,
            model: (raw[:model] || "inherit").to_s, max_steps: (raw[:max_steps] || @default_max_steps).to_i,
            provider: raw[:provider], parent_id: (raw[:parent_id] || "agent-0").to_s
          )
        end

        def refute_dead_dependencies!(specs)
          specs.each do |spec|
            spec.deps.each do |d|
              inst = @instances[d[:id]] || (@finished || {})[d[:id]]
              if inst
                # Tek tüketici: atomlar yeterli — yeni bir Instance
                # predicate'ine gerek yok (settled? disposed'u dışlar,
                # buradaki küme onu da içerir).
                if d[:type] == "FS" && (inst.failed? || inst.disposed? || inst.canceling?)
                  raise ArgumentError, "FS dependency '#{d[:id]}' already #{inst.state} — a dependent on a failed predecessor is refused"
                end
              elsif @deferred[d[:id]]&.cancelled?
                raise ArgumentError, "Dependency '#{d[:id]}' is cancelled — re-dispatch without it"
              end
            end
          end
        end

        def refute_unknown_dependencies!(specs)
          known = @instances.keys + (@finished || {}).keys + @deferred.keys + specs.map(&:id)
          specs.each do |spec|
            spec.deps.each do |d|
              next if known.include?(d[:id])

              raise ArgumentError, "Unknown dependency '#{d[:id]}' for #{spec.id}"
            end
          end
        end

        # Kenarlar: spec id => bağımlılık id'leri (yalnız graf içi id'ler;
        # Instance'lar terminal). Döngü tespiti saf DependencyGraph'ta.
        def dependency_graph(specs)
          graph = {}
          (@deferred.values + specs).each { |spec| graph[spec.id] = spec.deps.map { |d| d[:id] } }
          graph
        end

        # Kilit-altı kill çekirdeği: ASLA emit etmez, ASLA süpürme yapmaz —
        # mutasyon + iptal listesi toplama (announce/sweep arayanın işi,
        # kilidin dışında). :spawning spec SİLİNMEZ (launch_claimed! ile
        # uzlaştırılır): yalnız işaretlenir, bırakma yarışı burada ölür.
        def kill_locked(id, cascade, cancelled)
          if (spec = @deferred[id])
            if spec.spawning?
              spec.cancel_reason = "killed while launching"
              spec.state = :cancelled
            else
              @deferred.delete(id)
            end
            cancelled.concat(cancel_dependents_of([spec.id]))
            true
          elsif (inst = @instances[id])
            if cascade
              @instances.values.select { |c| c.parent_id == inst.id }.each do |child|
                kill_locked(child.id, cascade, cancelled)
              end
            end
            cancelled.concat(cancel_dependents_of([inst.id]))
            inst.kill
            true
          else
            false
          end
        end

        def queued_spec(id)
          @deferred[id.to_s]
        end
      end
    end
  end
end
