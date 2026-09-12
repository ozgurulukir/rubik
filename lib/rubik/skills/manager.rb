# frozen_string_literal: true

require "monitor"
require_relative "frontmatter"
require_relative "storage"
require_relative "registry"

module Rubik
  module Skills
    # = Rubik::Skills::Manager
    #
    # Lifecycle facade of the Agent Skills subsystem (agentskills.io),
    # provided as the +skill_manager+ coeffect (Composition.build →
    # wire_runtime_context) and read per turn by the prompt builder.
    #
    # == AGENTS.md treatment
    # A skill is DATA (frontmatter + markdown): never evaluated, no threads,
    # no listeners — so the lifecycle-bearing unit is the Manager itself and
    # the skills need no fibers. The Manager's single revertible effect is
    # registering the +skill+ tool into the shared tool registry; that effect
    # is opened on the Manager's OWN sub-context epoch (MCP::Manager
    # pattern): enable/disable cycles extend/dispose the epoch, so inverses
    # never stack across reloads (zero-restart rule, §1.A/§6) and disposal is
    # local to the code that produced the effect (no detached teardown, §5).
    class Manager
      # Head-only body cap for the `skill` tool output. StepExecutor
      # re-truncates every tool output on EITHER axis (tools.max_output_chars
      # AND tools.max_output_lines) with head_tail, which would cut the middle
      # out of ordered instructions — so Manager#body pre-truncates head-only
      # below BOTH limits (see #body) and the read_file pointer is the
      # recovery path for the omitted tail.
      DEFAULT_MAX_BODY_CHARS = 8_000
      # Lines the tool envelope adds around the body (3 header + truncation
      # notice + recovery pointer) — headroom under the StepExecutor line
      # budget (tools.max_output_lines).
      BODY_LINE_ALLOWANCE = 8

      attr_reader :config, :registry

      def initialize(config:, root_dir:, home_dir:, runtime_context: nil)
        @config = config
        @root_dir = File.expand_path(root_dir.to_s)
        @home_dir = home_dir ? File.expand_path(home_dir) : nil
        @runtime_context = runtime_context
        @registry = Registry.new
        @epoch_context = nil
        @monitor = Monitor.new
        reload!
      end

      # Capability gate (MCP::Manager#enabled? precedent): disabling keeps
      # the coeffect provided (Context has no unprovide) but empties the
      # prompt index and closes the tool epoch.
      def enabled?
        fetch("skills.enabled", true) != false
      end

      def max_body_chars
        (fetch("skills.max_body_chars", DEFAULT_MAX_BODY_CHARS) || DEFAULT_MAX_BODY_CHARS).to_i
      end

      # Residual line budget for the body, under the StepExecutor envelope.
      def max_body_lines
        raw = fetch("tools.max_output_lines", Rubik::Tools::Truncator::DEFAULT_MAX_LINES) ||
              Rubik::Tools::Truncator::DEFAULT_MAX_LINES
        [raw.to_i - BODY_LINE_ALLOWANCE, 1].max
      end

      def disabled_names
        Array(fetch("skills.disabled", [])).map(&:to_s)
      end

      def all
        return [] unless enabled?

        @registry.all
      end

      def find(name)
        return nil unless enabled?

        @registry.find(name)
      end

      # Level-1 progressive-disclosure payload for the prompt layer (pure
      # data, I/O-free downstream): name + description + scope only.
      def prompt_index
        all.map { |skill| { name: skill.name, description: skill.description, scope: skill.scope } }
      end

      # Level-2 read: the SKILL.md body, head-truncated below BOTH
      # StepExecutor budgets (chars and lines) so the downstream head_tail
      # pass can never amputate the middle; a read_file pointer covers the
      # omitted tail — progressive disclosure doubles as the recovery path.
      def body(name)
        skill = find(name)
        return nil unless skill

        parsed = Frontmatter.parse(File.read(skill.path))
        text = parsed[:body]
        return safe(text) if text.bytesize <= max_body_chars && text.lines.size <= max_body_lines

        trunc = Rubik::Tools::Truncator.truncate(text, max_chars: max_body_chars, max_lines: max_body_lines, strategy: :head_only)
        "#{safe(trunc[:text])}Load the omitted tail with read_file: #{skill.path}\n"
      rescue StandardError => e
        Rubik::Platform.debug_warn("Failed to read skill '#{name}': #{e.class}: #{e.message}")
        nil
      end

      # Re-discover from disk and atomically swap the snapshot. Per-skill
      # validation problems are collected warnings (spec: skip invalid
      # skills); a hard storage failure keeps the previous snapshot alive.
      def reload!
        result = storage.discover(disabled: disabled_names)
        @registry.install(result)
        result.issues.each { |issue| Rubik::Platform.debug_warn("skill #{issue.path}: #{issue.field} #{issue.message}") }
        true
      rescue StandardError => e
        warn "[rubik] skills reload failed (previous snapshot kept): #{e.class}: #{e.message}"
        false
      end

      # Validation issues from the last discovery (fatal rejections +
      # warnings), for !skill output. Severity split via ValidationIssue#level.
      def issues
        @registry.issues
      end

      def status_summary
        skills = all
        {
          enabled: enabled?,
          total: skills.size,
          by_scope: skills.group_by(&:scope).transform_values(&:size),
          disabled: disabled_names,
          skipped: @registry.issues.count(&:error?),
          notes: @registry.issues.count(&:warning?),
          shadowed: @registry.shadowed
        }
      end

      # --- Epoch management: the revertible tool registration ---

      # Registers the `skill` tool together with its unregister inverse on a
      # dedicated sub-context. No-op when the epoch is already open or the
      # subsystem is disabled. An activation failure disposes the partial
      # sub-context (atomic rollback) and re-raises.
      def open_epoch!(tool_registry)
        @monitor.synchronize do
          return if @epoch_context || !enabled? || tool_registry.nil?

          context = @runtime_context&.extend || Rubik::Runtime::Context.new
          begin
            tool = Rubik::Tools::SkillTool.new(self, runtime_context: @runtime_context)
            tool_registry.register(tool, origin: :builtin)
            context.register_disposable { tool_registry.unregister(Rubik::Tools::SkillTool::NAME) }
            @epoch_context = context
          rescue StandardError
            context.dispose
            raise
          end
        end
      end

      # Disposes the epoch sub-context; the LIFO inverse unregisters the
      # `skill` tool. Safe to call repeatedly.
      def close_epoch!
        @monitor.synchronize do
          @epoch_context&.dispose
          @epoch_context = nil
        end
      end

      # ConfigWiring handler for skills.* knobs: re-read config, refresh the
      # snapshot, and open/close the epoch only on an enabled flip.
      def apply_config!(tool_registry: nil)
        if enabled?
          reload!
          if tool_registry
            open_epoch!(tool_registry)
          else
            Rubik::Platform.debug_warn("skills are enabled but no tool registry is available; the skill tool stays unregistered")
          end
        else
          close_epoch!
          reload!
        end
      end

      def epoch_open?
        @monitor.synchronize { !@epoch_context.nil? }
      end

      private

      # Built per discovery (not memoized): skills.paths must be re-read from
      # live config on every reload! so `!config set skills.paths [...]`
      # takes effect without a restart.
      def storage
        Storage.new(
          root_dir: @root_dir,
          home_dir: @home_dir,
          extra_paths: Array(fetch("skills.paths", []))
        )
      end

      # fetch-with-default without the `|| default` idiom: an explicit
      # config value of false/nil must survive (see Loop#safe_config hazard).
      def fetch(key, default)
        return default unless @config.respond_to?(:fetch)

        @config.fetch(key, default)
      end

      # Encoding hygiene for File.read output reaching the model/history
      # (byteslice truncation can split a multibyte character).
      def safe(text)
        Rubik::Platform.safe_utf8(text)
      end
    end
  end
end
