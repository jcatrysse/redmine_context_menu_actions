# frozen_string_literal: true

Redmine::Plugin.register :redmine_context_menu_actions do
  name 'Redmine Context Menu Actions Plugin'
  author 'Jan Catrysse'
  description 'Add a note or change the dates of one or more issues from the issue context menu, without opening them'
  version '1.0.0'
  url 'https://github.com/jcatrysse/redmine_context_menu_actions'
  author_url 'https://github.com/jcatrysse'

  requires_redmine version_or_higher: '5.1'

  settings default: RedmineContextMenuActions::DEFAULT_SETTINGS, partial: 'settings/context_menu_actions_settings'
end

# A ViewListener registers itself when its class is loaded.
RedmineContextMenuActions::Hooks
