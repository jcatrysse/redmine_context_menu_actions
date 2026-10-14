# Redmine 7 migration

Branch `redmine70-migration`. Production stays on `main`.

## Goal

The plugin runs on Redmine 7.0-stable-GEOxyz (PostgreSQL), alone and together
with the other GEOxyz plugins: rspec suite green, every function checked in a
browser, no open failures.

Target: https://github.com/jcatrysse/redmine, branch `7.0-stable-GEOxyz` at
1d8c2a3 (Rails 8.1.3.1), Ruby 3.3.6, PostgreSQL 16.15.

## Measured state at the start (2026-10-14)

The plugin already supported 7.0 (1.0.0 is tested on 5.1 to 7.0), so no code had
to be ported. The coordinator's combined run (44 GEOxyz plugins, plugin head
4048149): 472 examples, 2 failures, 4 pending.

| Run | Result |
|---|---|
| Alone, 4048149 | 472 examples, 0 failures, 4 pending |
| 40 plugins (see below), 4048149 | 472 examples, 2 failures, 4 pending: `notes_endpoint_spec.rb:525`, `security_spec.rb:98` |

The 4 pending examples are the 5.1-only `sprite_icon` cases, pending on 6.0 and
later by design.

## Work list

| # | Item | State |
|---|---|---|
| 1 | `notes_endpoint_spec.rb:525`: description block missing with redmine_view_issue_description | done, 1ce45b0 |
| 2 | `security_spec.rb:98`: NoMethodError logged instead of the database error | done, 7b290c4 |
| 3 | `.codex` kit as root without sudo | done, 343a8ad |
| 4 | Suite alone and combined | done |
| 5 | Browser run alone and combined, screenshots for 7.0 | done |

## Findings and decisions

### 1. Description block missing (spec only)

redmine_view_issue_description hides the description from roles without
`view_issue_description`. The roles the specs build (`cma_member`) state exactly
the permissions a spec needs, so they lacked it. Intended behaviour of that
plugin. Fix as in issue_recurring, agile and todo_lists2: `cma_member` adds the
permission only when that plugin is installed. Nothing changes alone.

### 2. NoMethodError in the log

Attribution: redmine_agile's `controller_issues_bulk_edit_before_save` calls
`context[:controller].api_request?`. The spec called `IssueUpdater` directly
without a controller, so the hook raised before the stubbed save. In production
the endpoint always passes the controller (as core does), so this is no
production bug. The spec now goes through the endpoint, like a real request.

Asked: should the plugin handle that error safely too. It already reported any
error per issue, but logged the message of every error except a database error.
That message can carry the note text as well (an inspected journal in a
NoMethodError on Ruby before 3.3, another plugin's own exception). Decision: the
log line has the class and backtrace for every error, never the message. New
spec: a NoMethodError whose message carries the note; it logged the note before
the change.

Choice for Jan (B), decided by Jan on 2026-10-14: A.

* A. No message for any error (implemented, decided). Never leaks; the backtrace still
  names the file and line.
* B. Log the message with the note text replaced. More detail, but an escaped or
  inspected note (`\n`, quotes) is not found and leaks.
* C. Back to the message for anything but a database error.

Recommendation was A; Jan chose A.

### 3. Test kit as root

`test_setup.sh` needed sudo even as root. `cma_as_root` runs directly as root,
`cma_as_postgres` uses `runuser` as root; a normal user still goes through sudo.
Checked by `test_scripts.sh` (stubs, fails without the change) and for real as
root with sudo removed.

### Not this plugin's

* With redmine_drive, redmine_questions, redmine_reporter and redmine_resources
  from `master` (no `redmine70-migration` branch) added, 22 examples fail: every
  issue mail raises `super: no superclass method 'details_to_strings'` in the
  chain of redmine_drive (`alias_method`) and redmine_checklists (`prepend`).
  Those four are left out of the combined set below. Jan decided (2026-10-14)
  they do not move to Redmine 7: out of scope.
* In the combined browser run Puma logs 102 "SSL connection to a non-SSL Puma"
  lines (0 alone): some plugin's page requests an https URL. No failed request,
  no test affected.

## Results

The combined set is 39 other GEOxyz
plugins on their `redmine70-migration` heads:

bless_this_redmine_sso a659c68, view_customize fe6195e, redmine_ai_summary
d1bef93, redmine_custom_workflows 5deeb4a, redmine_depending_custom_fields
ba8f07f, redmine_description_macros 65eb419, redmine_drawio fa681e7,
redmine_editauthor d74ebb4, redmine_extended_api d103a2d, redmine_impersonate
ca7c2b8, redmine_inline_edit_issues 84ab829, redmine_issue_field_visibility
a725b6c, redmine_issue_templates 97d0296, redmine_issue_todo_lists2 a441945,
redmine_issue_view_columns 19c1078, redmine_itil_priority 064fd6f,
redmine_ldap_sync c950681, redmine_mail_digest 310df68, redmine_mermaid_macro
f3a9929, redmine_more_previews 8202ac6, redmine_parent_child_filters c47aaa6,
redmine_paste_as_wiki_tables e83b5ea, computed_custom_field 5af3f23,
redmine_project_workflows 18c02ad, redmine_stealth 8b8757e, redmine_subtask
2875a16, redmine_tint_issues 51c0d2d, redmine_user_specific_theme 5c426ce,
redmine_wiki_extensions 63e3042, redmine_agile 8b79801, redmine_ai_triage
7fbf741, redmine_checklists d868b4b, redmine_contacts 7bbe914,
redmine_contacts_helpdesk ff0387a, redmine_people 24db293, redmineup_tags
e59224c, redmine_zenedit f36e1ff, redmine_view_issue_description ed584b4.

| Run | Result |
|---|---|
| rspec alone | 473 examples, 0 failures, 4 pending |
| rspec with redmine_view_issue_description only | 472 examples, 0 failures, 4 pending (after 1ce45b0) |
| rspec with the 39 plugins | 473 examples, 0 failures, 4 pending |
| Browser alone (Chromium, Playwright 1.56.1) | 40 tests, 33 pass, 0 fail, 7 skipped (the screenshot specs, run separately) |
| Browser screenshots alone | 7 tests, 7 pass; written to `docs/screenshots/7.0` |
| Browser with the 39 plugins | 40 tests, 33 pass, 0 fail, 7 skipped; no 5xx in the server log |
| Coordinator, 44-plugin set, 177eb5e | 473 examples, 0 failures, 4 pending |
| `.codex/test_scripts.sh` | 31 checks, 0 failures |
| ShellCheck, RuboCop 1.88.2 | clean |

The browser specs cover every function: Add a note for one and several issues
(dialog, toolbar, private notes, Ctrl+Enter, Esc, unsaved text warning, errors,
partial success, retry, lost answer), the Last notes link, Dates (single, mixed
values, Clear, errors, reload to the same scroll position), My page with two
lists, and the settings.
