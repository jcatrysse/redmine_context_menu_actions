# frozen_string_literal: true

module RedmineContextMenuActions
  # Menu and link labels the way core draws them on each version: an SVG from the
  # sprite plus a label from 6.0 on, a bare label (with a CSS icon class on the
  # link) on 5.1.
  module Icons
    # Icons core's sprite does not have; the plugin ships them in its own sprite.
    PLUGIN_ICONS = %w[calendar].freeze

    module_function

    def label(view, icon, text)
      return text unless view.respond_to?(:sprite_icon)

      if PLUGIN_ICONS.include?(icon)
        view.sprite_icon(icon, text, :plugin => PLUGIN_ID.to_s)
      else
        view.sprite_icon(icon, text)
      end
    end
  end
end
