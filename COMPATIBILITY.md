# What this plugin assumes about Redmine

A plugin that lives in the issue context menu and in core's modal leans on core
markup, core JavaScript and core model rules. This file lists every place where
it does, what the assumption is and what breaks if Redmine changes it.
`spec/core_contract_spec.rb` asserts each one, so an upgrade that moves any of
them fails a named example instead of breaking a menu or a dialog.

Verified against Redmine 5.1, 6.0, 6.1 and 7.0.

## View hooks

| Hook | Assumed | Breaks if |
|---|---|---|
| `view_issues_context_menu_start` | first item of `context_menus/issues.html.erb`, with `issues`, `can`, `back`; the view has `@safe_attributes` | Add a note and Dates can no longer sit above Edit |
| `view_issues_context_menu_end` | last item of the same view | Add a note and Dates disappear when set to the end of the menu |
| `view_issues_index_bottom` | called on the issue list with `issues`, `project`, `query` | the Last notes links disappear |
| `view_layouts_base_html_head` | called before `yield :header_tags`, so `content_for :header_tags` from the hook still reaches the head | the wiki toolbar and the date picker setup are missing in the dialog, which then still works as a plain field |

On 7.0 the context menu controller is `ContextMenus::IssuesController`; the hooks
are still in the view, and the plugin does not touch the controller.

## Markup

| What | Assumed | Breaks if |
|---|---|---|
| `layouts/base.html.erb` | `<div id="ajax-modal" style="display:none;"></div>` | no dialog opens |
| `issues/_list.html.erb` | `tr#issue-<id>.hascontextmenu`, followed by one `<tr class="odd|even">` per block column, `<td colspan=... class="<column> block_column">`, a caption `<span>` when there is more than one block column | the Last notes block is not updated in place; the save itself is unaffected |
| `issues/_list.html.erb` | `query_columns_hidden_tags` posts the list columns as `c[]` with the context menu request | a new Last notes row is not inserted (existing ones are still replaced) |
| `QueriesHelper#column_value` | Last notes is `<div class="wiki">` rendered by `textilizable` | the inserted block looks different from core's |
| context menu items | 6.x: `context_menu_link sprite_icon(name, label), url, class: 'icon icon-<name>'`; 5.1: CSS icon classes | the plugin's items look different from core's |
| core sprite | has `comment`, has no `calendar` (the plugin ships its own) | an icon is missing |
| collapsible fieldset | `legend.icon.icon-collapsed` with `toggleFieldset(this)`, 6.x adds an `angle-right` icon | the note in the Dates dialog does not fold |

## JavaScript

| What | Assumed | Breaks if |
|---|---|---|
| `showModal(id, width)`, `hideModal(el)` | open and close `#ajax-modal` as a jQuery UI dialog | no dialog |
| rails-ujs | `data-remote` links and forms; it ends a remote link click with `stopImmediatePropagation`; `ajax:beforeSend` carries the request | the plugin records the opener of a dialog in the capture phase for that reason, and hides the context menu itself; it aborts an older dialog request still on its way |
| jQuery UI dialog close | Esc closes with the keydown event, core's `hideModal` (Cancel) without an event, the close button with its click | Esc would ask, or Cancel would not, before typed text is lost |
| `warnLeavingUnsaved` | every page warns on leaving with a changed textarea, until its form is submitted, unless the user's `warn_on_leaving_unsaved` is `0` | the plugin warns too, with the same preference and text, for changed dates and for text kept after a failed save; without core's warning it still does |
| Ctrl/Cmd+Enter | core submits a remote form from a textarea by clicking its first submit button, and blurs the textarea | the plugin has no handler of its own; it puts the cursor back after a failed submit |
| `[data-auto-complete=true]` | core attaches inline autocomplete on focus, anywhere in the document | no `#` / `@` suggestions |
| `rm.AutoComplete.dataSources` | set on every page; `users` added per page | the plugin sets `users` for the dialog and restores the previous value |
| `data-disables` | core binds it inside `#content` only | the dialog is in `#content` while open, so core's handler applies; the plugin binds the Clear checkbox too, for a layout without `#content`. Both set the same state |
| `#content .tabs`, `#content .jstTabs`, `.tab-preview` | the wiki toolbar tabs are styled, and the preview tab is delegated, inside `#content` only | the plugin attaches its dialog to `#content` while it is open, and gives it back to `<body>` when it closes, for core's own modals |
| jQuery UI dialog `position` | `showModal` sets none, so the dialog keeps jQuery UI's own (centred, `collision: fit`, title bar kept on screen) | after moving the dialog the plugin re-applies that same option, it never replaces it: a core modal opened later is placed as before |
| `jsToolBar` layout | the toolbar is `li.tab-elements > .jstElements` in `.jstTabs.tabs`; core keeps it on one line (42px items, a clipped bar) | inside its dialogs the plugin lets the buttons wrap; with other markup the dialog falls back to core's layout, where buttons that do not fit are hidden |
| `jsToolBar` table and code language pickers | appended to `<body>`, without a z-index | they would open under the modal overlay; the plugin CSS lifts them while one of its dialogs is open |
| `toggleRowGroup(el)` | collapses and expands a group by toggling each of its rows | a Last notes row inserted into a collapsed group starts hidden, so the group opens and closes as one |
| `context_menu.js` | a click on a link leaves the selection alone; nothing is unselected while `#ajax-modal` is visible; `contextMenuHide()` | the selection is lost after a save |
| `jsToolBar`, `datepickerOptions`, `datepickerFallback` | loaded by `heads_for_wiki_formatter` and `include_calendar_headers_tags` | the plugin checks for them and leaves the field plain |

## Models and controllers

| What | Assumed | Breaks if |
|---|---|---|
| `ApplicationController#find_issues` | `params[:id] || params[:ids]`, 404 when none, `Unauthorized` (403) when one is not visible, sets `@projects`, `@project` | the endpoint's loading and its first authorization |
| `IssuesController#bulk_update` | reload, `init_journal`, `safe_attributes=`, `controller_issues_bulk_edit_before_save` with `params` and `issue`, `save`, issue by issue; its form always posts `issue[...]` | the service mirrors it, and always passes an `issue` parameter to the hook; another plugin's bulk hook would see a different call |
| `bulk_update` permission | `edit_issues` / `edit_own_issues` only | the reason for the plugin's own endpoint |
| `parse_params_for_bulk_update` | empty means no change, `none` clears | the Dates semantics would differ from core's bulk edit |
| `Issue#notes_addable?` | `add_issue_notes` per tracker, never on a closed project | the menu and the endpoint offer notes where core would not |
| `Issue#safe_attribute_names` | `notes` with `add_issue_notes`, `private_notes` with `set_notes_private`, dates with edit permission minus workflow read-only, disabled core fields and derived parent dates | the actions offer fields core would refuse; the service refuses them anyway |
| `Issue#init_journal`, `notes=`, `private_notes=` | notes are delegated to the current journal; a note-only save journals and touches `updated_on` | the note would not be saved, or not notified |
| `Issue.locking_enabled?` | optimistic locking on `lock_version`; the plugin retries a stale save once, and reports an issue deleted meanwhile for that issue only | a concurrent edit is reported instead of retried |
| `Issue.lock` | `SELECT ... FOR UPDATE` on PostgreSQL and MySQL (InnoDB) | two requests for the same issue would no longer wait for each other, and a note submitted twice at once could be added twice |
| `Issue.load_visible_last_notes(issues, user)` | the last note per issue, private notes by `Journal.visible_notes_condition` (author always sees their own) | the updated Last notes block would show the wrong note |
| `Journal` | sends its notification and `@` mentions after commit | notifications would differ from core |

## Routes and translations

| What | Assumed |
|---|---|
| `preview_issue_path(project_id:, issue_id:)`, `preview_text_path` | preview for one issue, and for several |
| `watchers_autocomplete_for_mention_path` | `@` suggestions, authorized by `add_issue_watchers` |
| core locale keys | `label_add_note`, `label_issue_note_added`, `label_last_notes`, `label_x_issues`, `field_notes`, `field_private_notes`, `field_start_date`, `field_due_date`, `button_submit`, `button_cancel`, `button_clear`, `notice_successful_update`, `notice_failed_to_save_issues`, `notice_not_authorized`, `notice_file_not_found`, `notice_issue_update_conflict`, `error_invalid_authenticity_token`, `error_session_expired`, `text_warn_on_leaving_unsaved` exist in every core locale |

## Database engines

MySQL stores datetimes in whole seconds. A note added in the second the issue was
last saved leaves `updated_on` unchanged, so core writes the journal without
updating the issue row and without the optimistic lock. That is core behaviour;
the specs that simulate a concurrent edit age the issue first.

A MySQL collation compares text without regard to case and, in older ones,
trailing spaces. The check that keeps a note from being added twice after a lost
response compares the text again in Ruby, so "Agreed" and "agreed" are two notes
on every engine.
