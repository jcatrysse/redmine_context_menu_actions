# Decisions

Class A decisions are settled by convention, by Redmine core or by the brief, and
are listed as one-liners. Class B decisions are matters of taste or product
behaviour: a safe default is implemented, and the options are listed for Jan.

## Beslist

- No permissions and no project module of its own: every action reuses core permissions, so the rules equal core and an administrator configures nothing.
- Supported: Redmine 5.1, 6.0, 6.1 and 7.0 (`requires_redmine 5.1`), tested on PostgreSQL and MySQL; MariaDB is left to the local scripts.
- Scaffolding, CI, RuboCop config and spec layout copied from redmine_parent_child_filters, `PCF_` renamed to `CMA_`.
- `.codex` scripts also select a Ruby through rbenv when mise is absent, picking the newest installed Ruby the checkout accepts.
- Fixed while copying: the lower bound of the Ruby constraint was never read (the regex expected a quote after `>=`); `test_scripts.sh` covers it now.
- Specs wrap each example in a non-joinable transaction, so journals fire their after_commit mail as in production and the mail assertions are real.
- Settings with an absent key fall back to the default, `'0'`, `'false'`, `false` and blank read as off (same rule as redmine_parent_child_filters).
- The Last notes link is only active while Add a note is enabled, since it opens the same dialog.

### Add a note (F1)

- Own endpoint (`ContextMenuActionsController`), because core `bulk_update` is authorized by `edit_issues` / `edit_own_issues` only; it loads issues with core `find_issues` (404 none, 403 invisible).
- One predicate per action (`RedmineContextMenuActions::Predicates`), used by the menu and the endpoint; the endpoint answers 403 when the menu would not have offered the action, 404 when the action is switched off.
- The service (`IssueUpdater`) follows core bulk edit: reload, `init_journal`, `safe_attributes=`, `controller_issues_bulk_edit_before_save`, `save`, issue by issue. Hook params have core's bulk edit shape (`notes`, `issue[...]`); `issue` is always there, an empty hash for a note-only request, as core's bulk edit form always posts it.
- Every attribute about to be set must be a safe attribute for that user on that issue; nothing is dropped silently.
- A private note without `set_notes_private` is refused, not published as a public note (core would drop the flag).
- Anonymous users are treated as in core: the Anonymous role with `add_issue_notes` may add notes.
- `StaleObjectError`: one retry on a freshly loaded issue, a second conflict is reported with core's `notice_issue_update_conflict`. An issue deleted meanwhile (its save updates no row, the retry finds nothing) is a failure of that issue only.
- An unexpected error on one issue is reported for that issue, not turned into an error page, so a retry never adds a second note to the issues that saved. The log line has the class and backtrace; the message of a database error is left out, it carries the note text.
- A second submit after a lost answer: the form carries the time it was opened (`cma_since`). A note this user already added to an issue since then, with exactly the same text and the same private or public flag, is not added again; dates sent with it are still applied (unchanged, they change nothing), and the issue is reported as saved. Each issue is read for update (`SELECT ... FOR UPDATE`) in its own transaction before the check, so a second request for the same issue waits for the first and then finds its note; the check runs again on a retry. The text is compared again in Ruby because a MySQL collation ignores case. A different text, another user, a dialog opened later, or no or an implausible time (more than a day old) all add the note. The same text added by the same user from another tab while the dialog was open counts as the same note; telling them apart would need a table of submit tokens, which means a migration.
- No answer, or a server error: the outcome is unknown, so the dialog says that and that submitting again is safe (`text_cma_request_unknown`), and keeps the text. 401 shows core's `error_session_expired`, 403/404/422 core's own messages.
- Every answer names the dialog it belongs to (`cma_dialog`, made in the browser). A late answer to a dialog that was closed meanwhile updates the list and shows its notice (an error notice when it failed), and leaves the dialog open now alone: its text, its issues and its errors. A reload that answer asks for waits until that dialog closes.
- A missing Last notes row is only added in the list the action came from; My page shows several lists, each with its own columns. In a collapsed group the new row starts hidden.
- Blank or whitespace-only notes: submit disabled in the dialog, refused by the server with core's "Notes cannot be blank". Text is stored exactly as typed.
- Partial success: saved issues are updated on the page, the dialog keeps the text and shows core's `notice_failed_to_save_issues` plus one line per issue, and the form is narrowed to the failed issues.
- Ctrl/Cmd+Enter is core's own handler for remote forms; the plugin only puts the cursor back after a failed submit (core blurs the textarea).
- @mention suggestions use core's source, which core only offers with `add_issue_watchers`; the previous source is restored when the dialog closes.
- The Last notes cell is rendered server side with core's `column_content` after one `Issue.load_visible_last_notes` call; the list's `c[]` columns (posted by core with every context menu request) tell where to insert a missing row and whether it needs a caption.
- Confirmation: a fixed `flash notice` ("Note added", core key) that stays in view, plus a short highlight of the changed rows.
- Wording reuses core keys, so every language reads as Redmine: `label_add_note`, `label_issue_note_added`, `label_x_issues`, `notice_failed_to_save_issues`.
- Assets: the plugin's own small JS and CSS on every page while an action is on; core's wiki toolbar and date picker heads only on pages with a context menu; the dialog works without them (plain textarea).
- Browser specs use Node's `node:test` with the Playwright library against a test server on its own database (`.codex/browser_test.sh`); `@playwright/test` and chromedriver are not needed.
- MySQL stores whole seconds: a note added in the second the issue was last saved leaves the issue row untouched (core behaviour); the stale object specs age the issue first.

### Add a note from Last notes (F3)

- Decided on the server in `view_issues_index_bottom`: the setting, the Last notes block in the query, and `notes_addable?` per issue of the page (roles are cached per project, no query per row). The page gets the ids and a template link; the JavaScript only places it.
- Same endpoint and dialog as F1; the link passes the list's columns, like the context menu does.
- Idempotent and a no-op without the markup; re-applied after a save replaces a cell. Focus returns to the new link of the same issue.
- The opener of a dialog is recorded in the capture phase: rails-ujs stops all other click listeners of a remote link.
- Issues without a Last notes row get no link; they use the context menu.

### Dates (F2)

- Port of the Dates entry of redmine_issue_todo_lists2 2.2.2, on the same endpoint and service as notes, with its four defects fixed and covered by a spec each: unique ids with labels, a working date picker fallback and Clear checkbox (core binds `data-disables` inside `#content` only, so the dialog binds it itself); no markup hidden in the menu; a calendar icon on 6.x (plugin sprite, Tabler `calendar`, as core has none) and core's `calendar.png` on 5.1; errors in the dialog instead of the bulk edit page.
- Fields: those in the safe attributes every selected issue shares (edit permission, workflow read-only, disabled core fields, parents with derived dates), the same rule as core's context menu. A value for any other field refuses the whole request.
- Semantics of core bulk edit: empty means no change, Clear (`none`) removes the date. Emptying a date that was filled in counts as Clear: the box is ticked on submit, so the dialog shows what is sent. A field left empty because of mixed values stays "no change".
- Prefill: the value of one issue, or the value several issues share; otherwise empty with "(mixed values)".
- Optional note in a collapsed core fieldset, only with `add_issue_notes`; it lands in the same journal as the date change.
- Start after due is checked in the browser with core's own message before the request; the server still validates everything (relations, parents, invalid dates).
- After a save the list reloads (dates change sorting, filters, overdue styling and can reschedule following issues) and comes back to the same scroll position, with the notice. Nothing asked, nothing saved, no reload.
- The menu entry sits right below Add a note, both where the position setting says (see choice 9), and reuses the `@safe_attributes` core computed, so it adds no query.
- The endpoint computes the safe attributes per issue, as core's context menu and bulk edit do; that cost grows with the selection in core too.

### Settings, docs and browser checks

- Settings page in core's tabular box: one checkbox per action with a hidden `0` (as core's `setting_check_box`), the menu position as a select. Labels are core words where they exist (`label_add_note`, "Last notes: Add a note" composed from two core strings).
- Coexistence: the warning reads redmine_issue_todo_lists2's setting the way that plugin reads it (Ruby truthiness, its defaults until first saved), and only before 2.3.0. The other plugin is not patched.
- Found in the screenshots and fixed: the wiki toolbar tabs were unstyled, because core styles them, and delegates the preview tab, inside `#content` only, and a dialog lives in `<body>`. While open, the plugin's dialog is attached to `#content`; it is handed back to `<body>` on close. Its position option is re-applied, never replaced, so core's own modals keep jQuery UI's placement.
- Found in the UX pass after the second review: the wiki toolbar was clipped in the dialogs. Core keeps it on one line and hides what does not fit; the Dates dialog lost several buttons, the notes dialog its help button, and more in languages with longer tab labels (Dutch: "Bewerken", "Voorbeeldweergave"). Both dialogs are now 720px wide, so the English toolbar fits on one row, and inside them the buttons wrap next to the tabs instead of being hidden. A browser spec checks every button in both dialogs, in English and Dutch. The screenshots were regenerated.
- The table and code language pickers of the wiki toolbar are appended to `<body>` without a z-index and would open under the modal overlay; the plugin CSS lifts them while one of its dialogs is open.
- Found in the screenshots and fixed: the context menu stayed open behind the dialog, because rails-ujs stops core's click handler that hides it. The plugin hides it when one of its items is clicked.
- The folded note in the Dates dialog opens with Enter or Space too (`tabindex` on the legend); core's own folded fieldsets are mouse only.
- Browser specs run in CI on 5.1, 6.0, 6.1 and 7.0 (PostgreSQL) and on 6.1 (MySQL), with Playwright 1.56.1 pinned. The test environment switches CSRF protection off; `browser_test.sh` switches it back on for its server (a temporary initializer that only acts with `CMA_BROWSER_CSRF=1`), so every request carries a real token.
- The submit button has no `title="Ctrl+Enter"`: it was not translated and wrong on a Mac. Screenshots are produced by the same suite (`CMA_SCREENSHOTS`), with a stub of redmine_issue_todo_lists2 2.2.2 for the warning, created and removed by the script for that run only.

### Independent review, second round

Findings of the independent reviewer and what was done. Each fix has a spec that
fails without it (checked by reverting the fix).

| # | Finding | Resolution |
|---|---|---|
| M1 | A late answer was applied to whatever dialog was open: it could close it, or narrow it to other issues | answers carry the dialog token; browser spec with a held request, saved and failed |
| m1 | An issue deleted during a save turned the request into a 404 after other issues were saved | the retry is inside the per-issue rescue; rspec with a deleted issue |
| m2 | No answer or a 5xx said "Failed to save", and a retry could add the note twice | "outcome unknown, submitting again is safe" message, made true by the second-submit check; 401 message; rspec and browser spec |
| m3 | The dialog replaced the position option of the shared `#ajax-modal` | re-applies the option it has; browser spec checks core's modal afterwards |
| m4 | Toolbar table and code pickers opened under the overlay | CSS z-index while a dialog is open; browser spec clicks both |
| m5 | Emptying a prefilled date enabled Submit and changed nothing | counts as Clear; browser spec |
| m6 | My page: a Last notes row could be added to a list without that column | only in the list the action came from |
| n1 | Note-only requests passed no `issue` parameter to the bulk edit hook | always passed; rspec |
| n2 | Docs said the dialog is not in `#content` | COMPATIBILITY.md and the contract spec say why it is, and assert it |
| n3 | Browser CI on 5.1 and 6.1 only; CSRF never exercised end to end; no Ruby 2.7 run | browser CI on every version plus MySQL; CSRF on in the browser server; Ruby 2.7 left open (item 10) |
| n4 | Local MySQL browser runs had no rights on the browser database | `test_setup.sh` and `start_database.sh` grant it |
| n5 | Dialog title, `<details>` list, untranslated submit title | title and list are open item 2; the title attribute is gone |
| n6 | No reload before each issue, as core does | reload added; rspec where an earlier save changes a later issue |
| n7 | A row inserted in a collapsed group was visible | starts hidden; browser spec |

### Keuzes van Jan (4 October 2026)

The ten open items of the first report, as Jan decided them.

1. Menu label: "Add a note", core's `label_add_note`, as built.
2. Dialog title: "Add a note", the issue named on the first line, as built.
3. An action that is not allowed is hidden, not greyed out, as built.
4. Changed by Jan on 5 October: Esc closes the dialog at once; the close button and Cancel ask before typed text or changed dates are lost, with core's text; leaving the page asks too. Both follow the user's Redmine preference "Warn me when leaving a page with unsaved text", as core's own warning does. Core already warns on leaving a page with a changed textarea; the plugin adds the cases core does not see: changed dates, and text kept after a failed save (core forgets a textarea once its form was submitted).
5. No Add a note link on issues without a Last notes row; they use the context menu, as built.
6. Relative date shift: an idea for 1.1, not in 1.0.
7. The optional note in the Dates dialog stays, collapsed, as built.
8. Version 1.0.0.
9. Left to Claude. Chosen: Dates right below Add a note, both above Edit by default and both at the end when the setting says so. It keeps the two meeting actions together, the shortest path for the mouse, and one setting places both. The setting is renamed `menu_position`; 1.0.0 is the first release, so there is nothing stored to migrate. On the settings page it moved below both actions.
10. Ruby 3.0 or later is the plugin's minimum (README, CHANGELOG; RuboCop targets 3.0). There is no runtime check: a check that refuses to load would stop Redmine itself from booting.

### Code review by gpt-5.5 (OpenAI API, 5 October)

Jan asked for a second opinion from another model. The production code (29 files, about 17,000 tokens) went to `gpt-5.5` with high reasoning effort, asking for defects only. Each finding was checked against the code and core before acting on it.

| # | Finding | Verdict | Resolution |
|---|---|---|---|
| 1 | The duplicate check ran once, before the saves, without a lock: two identical submits running at the same time could both add the note; a stale retry reused the old check | Real | Each issue is locked for update before the check, and the check runs again on a retry. Verified on a live server with two identical submits fired at once and the bulk edit hook slowed by 2 seconds: the previous code added the note twice on PostgreSQL and MySQL, the new code once. The double click case it also named was already covered (Submit is off while a request runs; browser spec); a guard in the submit handler now covers any other way to submit |
| 2 | A slow answer to an earlier dialog request replaced a dialog opened after it, losing what was typed | Real | An older dialog request still on its way is aborted when a new one starts; browser spec with a held request |
| 3 | The duplicate check ignored the private flag | Real | The flag is part of the check; rspec. The other-tab case is left as described above |
| 4 | `sprite_icon('angle-right', :rtl => true)` would pass the hash as the label | Not a defect | Every Redmine with `sprite_icon` (6.0, 6.1, 7.0) takes keyword arguments, and core calls it the same way (`context_menus/time_entries.html.erb`) |

## Open, keuze voor Jan

None.
