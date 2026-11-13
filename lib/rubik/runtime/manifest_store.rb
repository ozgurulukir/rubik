# frozen_string_literal: true

require "json"
require "time"
# save_manifest atomik yazımı Platform.atomic_write kullanır; dosyanın tek başına
# require edilmesi durumunda da çözümlenebilsin diye açık yüklenir.
require_relative "../platform"
require_relative "../plugin/package_inventory"

module Rubik
  module Runtime
    # Single home of the manifest primitives shared by Plugin::Storage and
    # Runtime::OverlayStorage (issue #426): path resolution, load/save (atomic
    # write via Platform.atomic_write), per-basename hash recording, hash
    # verification (ONE comparison policy — constant-time, via
    # Plugin::PackageInventory.secure_compare), the RUBIK_TRUST_OVERLAYS
    # trust-mode seam, and the fail-closed corrupt-manifest contract.
    #
    # A store is directory-agnostic: callers resolve which directory a scope
    # maps to. An optional `validate_path` callable receives (path, dir)
    # before any manifest I/O — OverlayStorage wires its overlay-dir and
    # containment checks here; Plugin::Storage passes nil (its directories
    # are self-created under root/home).
    class ManifestStore
      MANIFEST_NAME = ".manifest.json"

      def initialize(validate_path: nil)
        @validate_path = validate_path
      end

      def manifest_path(dir)
        path = File.join(dir, MANIFEST_NAME)
        @validate_path&.call(path, dir)
        path
      end

      def load_manifest(dir)
        path = manifest_path(dir)
        return {} unless File.exist?(path)

        JSON.parse(File.read(path))
      rescue JSON::ParserError, ArgumentError
        {}
      end

      # Atomik yazım (tmp + rename): kilitsiz okuyucuların yarım manifest
      # görmesini engeller (Platform.atomic_write).
      def save_manifest(dir, manifest)
        Platform.atomic_write(manifest_path(dir), JSON.pretty_generate(manifest))
      end

      # Per-basename hash record: load → merge → save. The caller owns hash
      # computation (file vs normalized content) and pre-write guards; the
      # store owns the entry shape and the manifest mutation.
      def record_hash(dir, filename, hash, scope:)
        manifest = load_manifest(dir)
        manifest[filename] = {
          "sha256" => hash,
          "scope" => scope.to_s,
          "created_at" => Time.now.iso8601
        }
        save_manifest(dir, manifest)
      end

      # Symmetric retraction: remove a basename and persist. Returns whether
      # the key existed (mirrors Hash#delete's semantics).
      def remove_entry(dir, filename)
        manifest = load_manifest(dir)
        existed = manifest.delete(filename)
        save_manifest(dir, manifest) if existed
        !existed.nil?
      end

      # The ONE hash-comparison policy. Returns :verified, :drift (recorded
      # hash mismatch) or :unknown (basename not consented). Callers own the
      # user-facing warn wording for :drift/:unknown — both map to :rejected.
      def verify_entry(manifest, basename, current_hash)
        return :unknown unless manifest.key?(basename)
        return :verified if Rubik::Plugin::PackageInventory.secure_compare(current_hash, manifest[basename]["sha256"])

        :drift
      end

      # Single trust-mode seam (issue #426): the blanket operator override
      # read exactly once, here. Both storage planes (plugin and overlay)
      # delegate to this predicate.
      def trust_mode?
        ENV["RUBIK_TRUST_OVERLAYS"] == "1"
      end

      # Three-state manifest probe: :missing / :valid / :corrupt. load_manifest
      # deliberately keeps its {} behavior; the record/delete paths refuse
      # through refuse_corrupt_manifest! instead of silently healing.
      def manifest_state(dir)
        path = manifest_path(dir)
        return :missing unless File.exist?(path)

        parsed = JSON.parse(File.read(path))
        parsed.is_a?(Hash) ? :valid : :corrupt
      rescue JSON::ParserError
        :corrupt
      end

      # Single home of the fail-closed corrupt-manifest contract (issue #407):
      # record and delete refuse through this one raise instead of healing a
      # corrupt manifest (which would evict the other consented entries).
      # `verb` reproduces the per-site message ("cannot record '...'" vs
      # "cannot delete '...'"); the rest of the template is verbatim shared.
      def refuse_corrupt_manifest!(dir, verb, filename)
        return unless manifest_state(dir) == :corrupt

        raise "cannot #{verb} '#{filename}': .manifest.json in #{dir} is corrupt; delete it and re-record overlays"
      end
    end
  end
end
