# frozen_string_literal: true

require "monitor"

module Rubik
  module Skills
    # In-memory immutable snapshot of discovered skills (name => Skill),
    # Monitor-guarded. Registry#install swaps the whole snapshot atomically:
    # readers observe either the complete old or the complete new index —
    # that is the zero-downtime mechanism behind Manager#reload! (the system
    # prompt is rebuilt per turn, so the next turn renders the fresh index).
    class Registry
      def initialize
        @skills = {}.freeze
        @shadowed = {}.freeze
        @issues = [].freeze
        @monitor = Monitor.new
      end

      # Precedence merge: the first occurrence of a name wins (Storage scans
      # project > user > extra in that order); shadowed duplicates are
      # recorded with their scopes and surfaced by `!skill list`.
      def install(discovery)
        merged = {}
        shadowed = {}
        discovery.skills.each do |skill|
          if (winner = merged[skill.name])
            entry = (shadowed[skill.name] ||= { winner_scope: winner.scope, loser_scopes: [] })
            entry[:loser_scopes] << skill.scope
          else
            merged[skill.name] = skill
          end
        end
        @monitor.synchronize do
          @skills = merged.freeze
          @shadowed = shadowed.transform_values(&:freeze).freeze
          @issues = discovery.issues.freeze
        end
        self
      end

      def all
        @monitor.synchronize { @skills.values.sort_by(&:name) }
      end

      def find(name)
        @monitor.synchronize { @skills[name.to_s] }
      end

      def size
        @monitor.synchronize { @skills.size }
      end

      def shadowed
        @monitor.synchronize { @shadowed.dup }
      end

      # Validation issues from the last install (fatal rejections + warnings).
      def issues
        @monitor.synchronize { @issues.dup }
      end
    end
  end
end
