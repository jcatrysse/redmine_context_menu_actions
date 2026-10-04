# Translating this plugin

The plugin ships all 50 languages Redmine does, and has very few strings of its
own. This explains why, because a contributor who adds strings where Redmine
already has them makes the plugin read worse.

## Redmine's words first

Most of what the plugin shows is Redmine's own translation in that language:

| Shown as | Key | Where |
|---|---|---|
| Add a note | `label_add_note` | menu item, dialog title, link in Last notes, setting |
| Note added | `label_issue_note_added` | confirmation |
| Notes, Private notes, Start date, Due date | `field_notes`, `field_private_notes`, `field_start_date`, `field_due_date` | dialog fields |
| Submit, Cancel, Clear | `button_submit`, `button_cancel`, `button_clear` | dialog buttons |
| 5 issues | `label_x_issues` | dialog for several issues |
| Failed to save 1 issue(s) on 2 selected: #12. | `notice_failed_to_save_issues` | partial success |
| Your session has expired. Please login again. | `error_session_expired` | a request after the session ended |
| The issue has been updated by an other user while you were editing it. | `notice_issue_update_conflict` | an issue changed twice while saving |
| Last notes | `label_last_notes` | setting label |

A user who reads "Notitie toevoegen" on the issue page reads the same words in
the context menu. Where Redmine's own translation is still English in a locale,
the plugin is English there too, and the fix belongs upstream, in Redmine.

## The plugin's own keys

| Key | English |
|---|---|
| `label_cma_dates` | Dates |
| `label_cma_mixed_values` | (mixed values) |
| `label_cma_menu_position` | Position in the context menu |
| `label_cma_position_top` / `_bottom` | Top / Bottom |
| `text_cma_todo_lists_dates_conflict` | the warning about redmine_issue_todo_lists2 before 2.3.0 |
| `text_cma_request_unknown` | the request did not complete; some changes may be saved, submitting again is safe |

Keys carry the `cma_` prefix so they cannot collide with another plugin's
(redmine_issue_todo_lists2 has its own `field_dates`).

The word for Dates follows the language's word for the start and due date
fields, for example "Termine" in German and "Datums" in Dutch.

## Rules

* Every locale file has the same keys; `spec/locales_spec.rb` fails otherwise,
  and fails on a blank value or an en dash or em dash.
* No English pasted into another language. The spec checks that too; a word that
  really is the same (French "Dates") is listed as an exception in the spec.
* Keys and values are quoted. Psych reads a bare `no:` as `false`, which is the
  Norwegian locale key.
* `%{version}` and `%{fixed}` stay as they are.

## Checking your work

```bash
./.codex/redmine_clone.sh 6.1-stable
./.codex/test_setup.sh
./.codex/test_plugin.sh spec/locales_spec.rb spec/settings_spec.rb
```
