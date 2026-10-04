# CHANGELOG

## 1.0.0

First release. Requires Redmine 5.1 or later and Ruby 3.0 or later; tested on
5.1, 6.0, 6.1 and 7.0, PostgreSQL and MySQL. No migration.

### Added
* **Add a note** in the issue context menu, for one or several issues, without
  opening them. A dialog with a notes field like core's (toolbar, preview, `#` and
  `@` autocomplete, private notes when allowed); Ctrl+Enter submits, Esc closes
  it at once, the close button, Cancel and leaving the page ask first when
  something typed would be lost. After a save the Last notes block of each saved issue
  is updated in place, without a page reload. A failed issue keeps the
  dialog open with the text and the reason; a retry goes only to the issues that
  failed. When the answer is lost on the way, submitting again is safe: no issue
  gets the same note twice from one dialog.
* **Add a note** link in the Last notes block of the issue list.
* **Dates** in the issue context menu: change or clear start and due date of one
  or several issues, with an optional note. Emptying a filled in date clears it.
  Ported from redmine_issue_todo_lists2 2.2.2, where it was broken in four ways,
  each fixed here: the fields had no ids,
  so labels, the date picker and the Clear checkbox did nothing; the dialog was
  hidden inside the menu; Redmine 6 showed no icon; a validation error left the
  list for the bulk edit page.
* Add a note and Dates sit together in the menu, right above Edit or at its end.
* Settings: each action on or off, and the position of both in the menu.
  A warning when redmine_issue_todo_lists2 before 2.3.0 adds Dates as well.
* All 50 languages Redmine ships.
