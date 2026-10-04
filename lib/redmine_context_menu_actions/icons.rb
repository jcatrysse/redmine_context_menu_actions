# frozen_string_literal: true

module RedmineContextMenuActions
  # Menu and link labels the way core draws them on each version: an SVG from the
  # sprite plus a label from 6.0 on, a bare label (with a CSS icon class on the
  # link) on 5.1.
  module Icons
    # Icons core's sprite does not have; the plugin ships them in its own sprite.
    PLUGIN_ICONS = %w[calendar].freeze

    module_function

    # Decided by version, not by respond_to?(:sprite_icon): another plugin can
    # define a sprite_icon of its own on 5.1, where core's CSS has no place for it.
    def sprites?
      Redmine::VERSION::MAJOR >= 6
    end

    def label(view, icon, text)
      return text unless sprites?

      if PLUGIN_ICONS.include?(icon)
        view.sprite_icon(icon, text, :plugin => PLUGIN_ID.to_s)
      else
        view.sprite_icon(icon, text)
      end
    end
  end
end
