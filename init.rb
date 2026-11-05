# frozen_string_literal: true

Redmine::Plugin.register :redmine_context_menu_actions do
  name 'Redmine Context Menu Actions Plugin'
  author 'Jan Catrysse'
  description 'Add a note, change the dates or export as JSON one or more issues from the issue context menu, without opening them'
  version '1.0.0'
  url 'https://github.com/jcatrysse/redmine_context_menu_actions'
  author_url 'https://github.com/jcatrysse'

  requires_redmine version_or_higher: '5.1'

  # Off for every role until an administrator grants it. read: an export changes
  # nothing, so it works on a closed project, as viewing issues does.
  project_module :issue_tracking do
    permission :export_issues_json, {:context_menu_actions_export => [:issues]}, :read => true
  end

  settings default: RedmineContextMenuActions::DEFAULT_SETTINGS, partial: 'settings/context_menu_actions_settings'
end

# A ViewListener registers itself when its class is loaded.
RedmineContextMenuActions::Hooks
