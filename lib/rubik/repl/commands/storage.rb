# frozen_string_literal: true

require_relative "base"
require_relative "../../coeffects"

module Rubik
  module REPL
    module Commands
      # !storage — merkezi rubik://storage FS-DB'ye kullanıcı tarafı bakış
      # (storage-show-surface planı B): "raporu göster" isteğini modeli tamamen
      # devre dışı bırakarak karşılar. Depo araç-eylemlerinin aksine bu komut
      # sadece OKUR — yazma düzlemi storage aracında kalır.
      module Storage
        extend Base

        USAGE_STORAGE = "Usage: !storage [<type|id|type.row|row|hash-prefix|ref>] [refs]"

        def self.register(shell)
          handler = lambda do |args, ctx|
            store = resolve_store(ctx)
            unless store
              ctx.out.puts "Central storage is not available in this runtime (config storage.enabled=false or standalone construction)."
              return
            end

            dispatch(args, ctx, store)
          end

          shell.register_command(
            "storage",
            description: "Browse the central rubik://storage database (entities and refs)",
            usage: USAGE_STORAGE,
            audience: :both,
            &handler
          )
        end

        def self.dispatch(args, ctx, store)
          return render_refs_table(ctx, store) if args.include?("refs")
          return ctx.out.print(Rubik::Storage::Render.project(store.project, store.project_summary)) if args.empty?

          selector = args.first.to_s
          return render_type_listing(ctx, store, selector.downcase) if Rubik::Storage::Store::TYPES.include?(selector.downcase)

          record = resolve_any(store, selector)
          if record
            ctx.out.print(Rubik::Storage::Render.card(record, project: store.project, refs: store.refs))
          else
            ctx.out.puts "Storage entity not found: '#{selector}' in project '#{store.project}'. " \
                         "Try '!storage' for counts, '!storage refs' for aliases, or '!storage <type>' for a listing."
          end
        end

        # Store#get tip ister; kullanıcı seçicisi tipsiz gelir — tüm tiplerde
        # çöz (tam id → type.row → row → hash öneki → alias zinciri meta
        # referanslı olduğu için yalnız eşleşen tipin kayıtlarında tutarlı).
        def self.resolve_any(store, selector)
          Rubik::Storage::Store::TYPES.lazy.map { |t| store.get(type: t, id: selector) }.find(&:itself)
        end

        def self.render_type_listing(ctx, store, type)
          summaries = store.list(type: type).map(&:to_h)
          ctx.out.print(Rubik::Storage::Render.listing(project: store.project, type: type,
                                                       summaries: summaries, refs: store.refs))
        end

        def self.render_refs_table(ctx, store)
          refs = store.refs
          if refs.empty?
            ctx.out.puts "No refs defined in project '#{store.project}'."
            return
          end

          ctx.out.puts "Refs in '#{store.project}':"
          refs.sort.each { |name, id| ctx.out.puts "  #{name} → #{id}" }
        end

        def self.resolve_store(ctx)
          rt = ctx.respond_to?(:runtime_manager) ? ctx.runtime_manager : nil
          rt&.context ? Rubik::Coeffects.get(rt.context, Rubik::Coeffects::STORAGE_STORE) : nil
        end
      end
    end
  end
end
