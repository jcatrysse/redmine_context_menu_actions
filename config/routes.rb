# frozen_string_literal: true

get 'context_menu_actions/notes/new', :to => 'context_menu_actions#new_note', :as => 'context_menu_actions_new_note'
post 'context_menu_actions/notes', :to => 'context_menu_actions#create_note', :as => 'context_menu_actions_notes'
get 'context_menu_actions/dates/edit', :to => 'context_menu_actions#edit_dates', :as => 'context_menu_actions_edit_dates'
patch 'context_menu_actions/dates', :to => 'context_menu_actions#update_dates', :as => 'context_menu_actions_dates'
