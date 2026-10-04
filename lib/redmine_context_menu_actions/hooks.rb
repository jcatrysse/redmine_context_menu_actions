# frozen_string_literal: true

module RedmineContextMenuActions
  # Every entry point is a core view hook; no core view is overridden.
  class Hooks < Redmine::Hook::ViewListener
    render_on :view_layouts_base_html_head, :partial => 'context_menu_actions/hooks/html_head'
    render_on :view_issues_context_menu_start, :partial => 'context_menu_actions/hooks/context_menu_start'
    render_on :view_issues_context_menu_end, :partial => 'context_menu_actions/hooks/context_menu_end'
    render_on :view_issues_index_bottom, :partial => 'context_menu_actions/hooks/issues_index_bottom'
  end
end
