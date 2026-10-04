# frozen_string_literal: true

module RedmineContextMenuActions
  # redmine_issue_todo_lists2 before 2.3.0 adds its own Dates entry to the issue
  # context menu. With both on, the menu shows Dates twice. The other plugin is
  # not patched; the settings page of this one says what to do.
  module Coexistence
    TODO_LISTS = :redmine_issue_todo_lists2
    TODO_LISTS_FIXED_IN = '2.3.0'

    module_function

    # The installed version of redmine_issue_todo_lists2 when it still adds
    # Dates to the context menu, nil otherwise.
    def todo_lists_dates_conflict
      plugin = Redmine::Plugin.registered_plugins[TODO_LISTS]
      return unless plugin && older_than_fix?(plugin.version)
      return unless todo_lists_dates_enabled?

      plugin.version.to_s
    end

    def older_than_fix?(version)
      Gem::Version.new(version.to_s) < Gem::Version.new(TODO_LISTS_FIXED_IN)
    rescue ArgumentError
      false
    end

    # Read exactly as that plugin reads it in its context menu partial: Ruby
    # truthiness of the stored value. Its settings page stores "1" or nothing,
    # and Redmine returns its defaults (on) until the settings are first saved.
    def todo_lists_dates_enabled?
      settings = Setting.respond_to?(:"plugin_#{TODO_LISTS}") ? Setting.send(:"plugin_#{TODO_LISTS}") : nil
      return false unless settings.respond_to?(:[])

      (settings['enable_dates_context_menu'] || settings[:enable_dates_context_menu]) ? true : false
    end
  end
end
