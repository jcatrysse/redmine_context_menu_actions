# frozen_string_literal: true

module RedmineContextMenuActions
  # One answer per action to "may this user do this to these issues?", shared by
  # the context menu and the endpoint, so the menu never offers an action the
  # endpoint would refuse. Every answer is Redmine's own rule for the issue page.
  module Predicates
    DATE_FIELDS = %w[start_date due_date].freeze

    module_function

    # Issue#notes_addable?: the add_issue_notes permission, per tracker, and never
    # on a closed or archived project.
    def notes_addable?(issues, user = User.current)
      issues = Array(issues)
      issues.any? && issues.all? { |issue| issue.notes_addable?(user) }
    end

    # The private_notes safe attribute: set_notes_private on the issue's project.
    def private_notes_allowed?(issues, user = User.current)
      issues = Array(issues)
      issues.any? && issues.all? { |issue| issue.safe_attribute?('private_notes', user) }
    end

    # The safe attribute names every issue shares, computed the way the context
    # menu computes @safe_attributes.
    def common_safe_attribute_names(issues, user = User.current)
      Array(issues).map { |issue| issue.safe_attribute_names(user) }.reduce(:&) || []
    end

    # The date fields that may be changed on all of them: edit permission,
    # not read-only in the workflow, not disabled for the tracker and not derived
    # from subtasks. Takes the shared safe attribute names, so the menu can pass
    # the @safe_attributes core already computed.
    def date_fields(safe_attribute_names)
      DATE_FIELDS & Array(safe_attribute_names)
    end
  end
end
