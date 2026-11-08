# frozen_string_literal: true

module Rubik
  # THE single home of the event bus's name vocabulary. Publishers and
  # subscribers across layers (orchestrator, repl, storage, kernel) read
  # these constants instead of redeclaring the names — a redeclaration is
  # one rename away from a silently dead subscription. Zero requires, a
  # dependency-free leaf like Coeffects/Uris: any layer can bind to the
  # shared names without dragging another layer's logic in.
  module Events
    SUBAGENT_COMPLETED = :subagent_completed
    SUBAGENT_MESSAGE_TO_PARENT = :subagent_message_to_parent
    TURN_FINISHED = :turn_finished
    GOAL_FINISHED = :goal_finished
    GOAL_SUSPENDED = :goal_suspended
    UNIT_STATE_CHANGED = :unit_state_changed
  end
end
