# frozen_string_literal: true

# Quick actions in the issue context menu. The plugin has no permissions and no
# project module of its own: every action is allowed exactly when Redmine itself
# would allow the same change on the issue page.
module RedmineContextMenuActions
  PLUGIN_ID = :redmine_context_menu_actions

  DEFAULT_SETTINGS = {
    'enable_notes' => true,
    'menu_position' => 'top',
    'enable_last_notes_link' => true,
    'enable_dates' => true
  }.freeze

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

  def self.any_enabled?
    notes_enabled? || dates_enabled?
  end

  # The c[] column names an issue list posts with its context menu request, kept
  # only when they are plain strings: anything else would make the URL helpers
  # raise on unpermitted parameters.
  def self.column_names(value)
    Array(value).select { |name| name.is_a?(String) || name.is_a?(Symbol) }.map(&:to_s).reject(&:empty?).first(200)
  end
end
