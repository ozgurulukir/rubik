# frozen_string_literal: true

module Rubik
  module Buffer
    module PathValidator
      # Uzantısız/noktasız özel dosya adları — path separator veya uzantı olmadan
      # geçerli sayılması gereken dosyalar.
      SPECIAL_FILENAMES = %w[
        Gemfile Rakefile Makefile Dockerfile Procfile
        LICENSE CHANGELOG Vagrantfile Jenkinsfile Justfile
        Berksfile Capfile Guardfile Podfile Appraisals
      ].freeze

      # Geçersiz dosya adı karakterleri — LLM kod fragmanı sızıntısını işaret eder.
      # Not: `,` ve `?` burada da var, ancak contains_invalid_chars? onları açıkça
      # kontrol eder (self-documentation için); chars.any? zaten yakalar.
      INVALID_PATH_CHARS = %w[, ? * " < > |].freeze

      class << self
        # Bir dosya yolunun geçerli olup olmadığını kontrol eder.
        #
        # @param path [String, nil] kontrol edilecek yol
        # @return [Boolean] yol geçerliyse true
        def valid?(path)
          return false if path.nil? || path.to_s.strip.empty?

          cleaned = path.to_s.strip

          # 1. NEGATİF KONTROL: Geçersiz karakterler içeren yolları reddet.
          #    Bu, pozitif kontrollerden ÖNCE çalışır — LLM kod fragmanı sızıntılarını
          #    (sondaki virgül, baştaki soru işareti, vb.) yakalar.
          return false if contains_invalid_chars?(cleaned)

          # 2. Özel dosya adları (uzantısız/noktasız)
          return true if SPECIAL_FILENAMES.include?(cleaned)

          # 3. Geçerli dosya uzantısı — nokta içeren ve noktadan sonra en az 1 karakter
          return true if cleaned.include?(".") && !cleaned.end_with?(".")

          # 4. Path separator içeren yollar
          return true if cleaned.include?("/") || cleaned.include?("\\")

          # 5. Hiçbir koşula uymayan — garbage
          false
        end

        private

        def contains_invalid_chars?(cleaned)
          # Sondaki virgül: LLM'in argüman sızıntısı (RubyAdapter.new,)
          return true if cleaned.end_with?(",")

          # Baştaki soru işareti: LLM sembol sızıntısı (?error)
          return true if cleaned.start_with?("?")

          # Diğer geçersiz karakterler (* " < > |)
          cleaned.chars.any? { |c| INVALID_PATH_CHARS.include?(c) }
        end
      end
    end
  end
end