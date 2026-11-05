# frozen_string_literal: true

# Quick actions in the issue context menu. Add a note and Dates are allowed
# exactly when Redmine itself would allow the same change on the issue page. The
# JSON export has a permission of its own, export_issues_json, in the issue
# tracking module, and is off until an administrator switches it on.
module RedmineContextMenuActions
  PLUGIN_ID = :redmine_context_menu_actions

  DEFAULT_SETTINGS = {
    'enable_notes' => true,
    'menu_position' => 'top',
    'enable_last_notes_link' => true,
    'enable_dates' => true,
    'enable_export_json' => false,
    'export_json_limit' => '100',
    'export_json_include' => %w[journals attachments relations children watchers changesets]
  }.freeze

  # The include values of GET /issues/:id.json the export may ask for, in core's
  # spelling. allowed_statuses is left out: it describes what the exporting user
  # may do next, not the issue.
  EXPORT_PARTS = %w[journals attachments relations children watchers changesets].freeze

  # The export is a GET with ids[] in the URL, like core's bulk links. Ten to
  # eighteen bytes per id, plus the back_url: 200 ids stay well under the 8 KB
  # request line most proxies and servers accept.
  EXPORT_LIMIT_MAX = 200

  MENU_POSITIONS = %w[top bottom].freeze

  # Redmine does not merge plugin defaults into stored settings, so an instance
  # that saved its settings before a release added a key has no such key at all.
  # An absent key falls back to the default; a key stored as '0' stays off.
  def self.setting(key)
    key = key.to_s
    stored = Setting.respond_to?(:"plugin_#{PLUGIN_ID}") ? Setting.send(:"plugin_#{PLUGIN_ID}") : nil
    stored = {} unless stored.respond_to?(:key?)
    if stored.key?(key)
      stored[key]
    elsif stored.key?(key.to_sym)
      stored[key.to_sym]
    else
      DEFAULT_SETTINGS[key]
    end
  end

  def self.enabled?(key)
    value = setting(key)
    return false if value.nil? || value == false

    !%w[0 false].include?(value.to_s.strip) && value.to_s.strip != ''
  end

  def self.notes_enabled?
    enabled?('enable_notes')
  end

  def self.dates_enabled?
    enabled?('enable_dates')
  end

  # The link in the Last notes block opens the notes dialog, so it is only
  # offered while the notes action itself is on.
  def self.last_notes_link_enabled?
    notes_enabled? && enabled?('enable_last_notes_link')
  end

  def self.menu_position
    position = setting('menu_position').to_s
    MENU_POSITIONS.include?(position) ? position : DEFAULT_SETTINGS['menu_position']
  end

  def self.export_json_enabled?
    enabled?('enable_export_json')
  end

  # The most issues one export may hold, 1 to EXPORT_LIMIT_MAX; the default when
  # the stored value is not a number.
  def self.export_json_limit
    value = setting('export_json_limit').to_s.strip
    limit = value.match?(/\A\d+\z/) ? value.to_i : DEFAULT_SETTINGS['export_json_limit'].to_i
    limit.clamp(1, EXPORT_LIMIT_MAX)
  end

  # The parts of the API response the export includes, in core's order. A
  # stored list keeps only the known parts; an absent key means all of them.
  def self.export_json_include
    value = setting('export_json_include')
    value = value.values if value.is_a?(Hash)
    EXPORT_PARTS & Array(value).map(&:to_s)
  end

  def self.any_enabled?
    notes_enabled? || dates_enabled? || export_json_enabled?
  end

  # The c[] column names an issue list posts with its context menu request, kept
  # only when they are plain strings: anything else would make the URL helpers
  # raise on unpermitted parameters.
  def self.column_names(value)
    Array(value).select { |name| name.is_a?(String) || name.is_a?(Symbol) }.map(&:to_s).reject(&:empty?).first(200)
  end
end
