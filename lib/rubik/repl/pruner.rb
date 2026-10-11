# frozen_string_literal: true

module Rubik
  module REPL
    # Pruner — yarı deterministik KÖK konuşma penceresi budayıcısı
    # (context-pruner planı 2026-10-09, vakanüvis iki-düzlem modeli):
    #
    #   Düzlem 1 (deterministik): tetik kapısı, brif kurulumu, plan
    #   doğrulaması ve turn sınırındaki aşamalı uygulama (Rules/Brief/Gate).
    #   Düzlem 2 (LLM): sessiz "Context Pruner" subagent'ı keep/drop/
    #   summarize planını ÖNERİR — yazma yetkisi yoktur; öneri katı
    #   doğrulamadan geçmezse pencere dokunulmadan kalır.
    #
    # Deterministik sıkıştırma yığını (trim_conversation_window! /
    # ContextCompactor / EmergencyCompactor) DEĞİŞMEZ ve her zaman güvenlik
    # ağıdır; subagent kanallarının budama mekanizmaları bu özellikten
    # tamamen bağımsız, tam deterministik kalır. DEFAULT ON
    # (subagents.pruner.enabled; opt-out: false — 2026-10-10).
    module Pruner
      SUBSYSTEM = :repl

      module_function

      # Vakanüvis.log_via emsali: dmesg yoksa Log'a, ikisi de patlarsa
      # stderr'e — günlükleme asla akışı bozmaz.
      def log_via(dmesg, level, message)
        dmesg.respond_to?(:log) ? dmesg.log(SUBSYSTEM, level, message) : Rubik::Log.send(level, SUBSYSTEM, message)
      rescue StandardError
        Rubik::Log.warn(SUBSYSTEM, message)
      end
    end
  end
end

require_relative "pruner/rules"
require_relative "pruner/brief"
require_relative "pruner/gate"
require_relative "pruner/harness"
require_relative "pruner/service"
