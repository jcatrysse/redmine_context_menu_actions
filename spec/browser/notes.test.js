'use strict';

// F1 Add a note, in a real browser: the meeting flow, the error path, partial
// success, unsaved text and double submits.

const { test, before, after, beforeEach } = require('node:test');
const assert = require('node:assert/strict');
const h = require('./helpers');

let env;

before(async () => { env = await h.launch(); await h.login(env.page); });
after(async () => { await env.browser.close(); });
beforeEach(() => { env.errors.length = 0; env.dialogs.seen.length = 0; env.dialogs.mode = 'accept'; });

async function issueIdBySubject(page, subject) {
  return page.evaluate((text) => {
    const cell = [...document.querySelectorAll('tr.hascontextmenu td.subject')].find((td) => td.innerText.trim() === text);
    return cell ? parseInt(cell.closest('tr').id.replace('issue-', ''), 10) : null;
  }, subject);
}

test('adds a note from the context menu without reloading or losing the place', async () => {
  const { page, errors } = env;
  await h.openList(page);
  const id = await issueIdBySubject(page, 'Meeting item 30');
  assert.ok(id);
  await page.evaluate((issueId) => document.querySelector(`tr#issue-${issueId}`).scrollIntoView({ block: 'center' }), id);
  assert.equal(await h.lastNotesText(page, id), null, 'no Last notes row yet');

  await h.openNotesFromMenu(page, id);
  assert.equal(await page.isVisible('#context-menu'), false, 'the context menu closes when an action is chosen');
  // Measured once the dialog is open: Playwright itself scrolls a link into view
  // before it clicks it, which a user does not need.
  const scrollBefore = await page.evaluate(() => window.scrollY);
  assert.ok(scrollBefore > 300, `list should be scrolled, is at ${scrollBefore}`);
  assert.equal(await page.evaluate(() => document.activeElement.id), 'cma_notes', 'the textarea has the focus');
  assert.equal(await page.isDisabled('#ajax-modal .cma-submit'), true, 'nothing to submit yet');
  assert.match(await page.textContent('#ajax-modal .cma-issues-summary'), new RegExp(`#${id}: Meeting item 30`));

  await page.keyboard.type('Agreed in the meeting: *ship it*');
  assert.equal(await page.isDisabled('#ajax-modal .cma-submit'), false);
  await page.keyboard.press('Control+Enter');
  await page.waitForSelector('#ajax-modal', { state: 'hidden' });

  assert.match(await h.lastNotesText(page, id), /Agreed in the meeting: ship it/);
  assert.equal(await page.evaluate(() => window.cmaNoReload), true, 'no page reload');
  assert.equal(await page.evaluate(() => window.scrollY), scrollBefore, 'scroll position kept');
  assert.match(await page.textContent('#cma-notice'), /Note added/);
  assert.equal(await page.isVisible('#cma-notice'), true);
  assert.equal(await page.evaluate((issueId) => document.querySelector(`tr#issue-${issueId}`).classList.contains('context-menu-selection'), id), true, 'row still selected');
  assert.equal(await page.evaluate((issueId) => !!document.activeElement.closest(`tr#issue-${issueId}`), id), true, 'focus back on the row');
  h.assertNoErrors(errors);
});

test('replaces an existing Last notes block in place', async () => {
  const { page, errors } = env;
  await h.openList(page);
  assert.ok(await h.lastNotesText(page, 1), 'issue 1 has notes in the fixtures');

  await h.openNotesFromMenu(page, 1);
  await page.keyboard.type('Replaced in place');
  await page.click('#ajax-modal .cma-submit');
  await page.waitForSelector('#ajax-modal', { state: 'hidden' });

  assert.match(await h.lastNotesText(page, 1), /Replaced in place/);
  const rows = await page.evaluate(() => {
    const row = document.querySelector('tr#issue-1');
    let count = 0;
    let next = row.nextElementSibling;
    while (next && !next.classList.contains('hascontextmenu')) { if (next.querySelector('td.last_notes')) { count++; } next = next.nextElementSibling; }
    return count;
  });
  assert.equal(rows, 1, 'still exactly one Last notes row');
  assert.equal(await page.evaluate(() => window.cmaNoReload), true);
  h.assertNoErrors(errors);
});

test('keeps the text and shows the error when the issue cannot be saved', async () => {
  const { page, errors } = env;
  await h.openList(page);
  await h.openNotesFromMenu(page, 2);
  await page.keyboard.type('This will not save');
  await page.keyboard.press('Control+Enter');
  await page.waitForSelector('#ajax-modal #errorExplanation');

  assert.equal(await h.modalOpen(page), true, 'the dialog stays open');
  assert.equal(await page.inputValue('#cma_notes'), 'This will not save');
  assert.match(await page.textContent('#ajax-modal #errorExplanation'), /#2: Due date cannot be blank/);
  assert.equal(await page.isDisabled('#ajax-modal .cma-submit'), false, 'the user can retry');
  h.assertNoErrors(errors);

  env.dialogs.mode = 'accept';
  await page.keyboard.press('Escape');
  await page.waitForSelector('#ajax-modal', { state: 'hidden' });
});

test('saves what it can and narrows a retry to the issues that failed', async () => {
  const { page, errors } = env;
  await h.openList(page);
  await page.click('tr#issue-1 td.checkbox input');
  await page.click('tr#issue-2 td.checkbox input');
  await page.click('tr#issue-2 td.status', { button: 'right' });
  await page.waitForSelector('#context-menu a.cma-menu-link', { state: 'visible' });
  await page.click('#context-menu a.cma-menu-link');
  await page.waitForSelector('#ajax-modal textarea#cma_notes', { state: 'visible' });
  assert.match(await page.textContent('#ajax-modal .cma-issues summary'), /2 issues/);

  await page.keyboard.type('Partial success');
  await page.keyboard.press('Control+Enter');
  await page.waitForSelector('#ajax-modal #errorExplanation');

  assert.match(await h.lastNotesText(page, 1), /Partial success/);
  assert.match(await page.textContent('#ajax-modal #errorExplanation'), /Failed to save 1 issue\(s\) on 2 selected: #2\./);
  const ids = await page.$$eval('#ajax-modal input[name="ids[]"]', (inputs) => inputs.map((i) => i.value));
  assert.deepEqual(ids, ['2']);
  assert.equal(await page.inputValue('#cma_notes'), 'Partial success');
  h.assertNoErrors(errors);
  await page.keyboard.press('Escape');
  await page.waitForSelector('#ajax-modal', { state: 'hidden' });
});

// Jan's choice: Esc closes at once; the close button and Cancel ask before
// typed text is lost, with core's text.
test('Esc closes at once, the close button and Cancel ask first when text would be lost', async () => {
  const { page, errors, dialogs } = env;
  await h.openList(page);
  await h.openNotesFromMenu(page, 3);
  await page.keyboard.type('Half a thought');
  await page.keyboard.press('Escape');
  await page.waitForSelector('#ajax-modal', { state: 'hidden' });
  assert.deepEqual(dialogs.seen, [], 'Esc asks nothing');

  await h.openNotesFromMenu(page, 3);
  assert.equal(await page.inputValue('#cma_notes'), '', 'a new dialog starts empty');
  await page.keyboard.type('Second thought');
  dialogs.mode = 'dismiss';
  await page.click('.ui-dialog .ui-dialog-titlebar-close');
  assert.equal(dialogs.seen.length, 1);
  assert.match(dialogs.seen[0], /unsaved text/);
  assert.equal(await h.modalOpen(page), true, 'still open after No');
  assert.equal(await page.inputValue('#cma_notes'), 'Second thought');

  dialogs.mode = 'accept';
  await page.click('#ajax-modal a:has-text("Cancel")');
  await page.waitForSelector('#ajax-modal', { state: 'hidden' });
  assert.equal(dialogs.seen.length, 2, 'Cancel asks too');

  await h.openNotesFromMenu(page, 3);
  await page.click('.ui-dialog .ui-dialog-titlebar-close');
  await page.waitForSelector('#ajax-modal', { state: 'hidden' });
  assert.equal(dialogs.seen.length, 2, 'nothing typed, nothing asked');

  assert.doesNotMatch((await h.lastNotesText(page, 3)) || '', /Half a thought|Second thought/, 'nothing saved');
  assert.equal(await page.evaluate(() => window.cmaNoReload), true);
  h.assertNoErrors(errors);
});

// Leaving the page asks while a dialog holds something not saved. Core's own
// warning (every page) covers a changed textarea until its form is submitted;
// the plugin covers the rest: changed dates, and text kept after a failed
// save. Each case on a page of its own: Chromium leaves a page whose prompt
// was answered No unable to navigate on.
test('asks before the page is left while a dialog holds something not saved', async () => {
  async function leave(prepare) {
    const page = await env.context.newPage();
    const seen = [];
    page.on('dialog', (dialog) => { seen.push(dialog.type()); return dialog.accept(); });
    await h.openList(page);
    await prepare(page);
    const closed = page.waitForEvent('close');
    await page.close({ runBeforeUnload: true });
    await closed;
    return seen;
  }

  assert.deepEqual(await leave(async (page) => {
    await h.openNotesFromMenu(page, 3);
    await page.keyboard.type('Not saved yet');
  }), ['beforeunload'], 'typed text');

  assert.deepEqual(await leave(async (page) => {
    await h.openNotesFromMenu(page, 2);
    await page.keyboard.type('Kept after a failed save');
    await page.keyboard.press('Control+Enter');
    await page.waitForSelector('#ajax-modal #errorExplanation');
  }), ['beforeunload'], 'text kept after a failed save');

  assert.deepEqual(await leave(async (page) => {
    await h.rightClickIssue(page, 1);
    await page.click('#context-menu a.icon-calendar');
    await page.waitForSelector('#ajax-modal form.cma-dates-form', { state: 'visible' });
    await page.fill('#cma_start_date', '2031-08-01');
  }), ['beforeunload'], 'a changed date');

  assert.deepEqual(await leave(async (page) => {
    await h.openNotesFromMenu(page, 3);
  }), [], 'nothing changed');
});

// A dialog asked for first but answered late must not replace the one the
// user opened after it and is typing in.
test('a late answer to an earlier dialog request does not replace the open dialog', async () => {
  const { page, errors } = env;
  await h.openList(page);
  let held = null;
  await page.route('**/context_menu_actions/notes/new**', (route) => {
    if (!held && /ids%5B%5D=1(&|$)/.test(route.request().url())) { held = route; return undefined; }
    return route.continue();
  });
  try {
    await h.rightClickIssue(page, 1);
    await page.click('#context-menu a.cma-menu-link');
    for (let i = 0; i < 100 && !held; i++) { await page.waitForTimeout(50); }
    assert.ok(held, 'the first request is on its way');
    await h.openNotesFromMenu(page, 3);
    await page.keyboard.type('Typed for issue 3');
    await held.continue().catch(() => {});
    await page.waitForTimeout(800);

    assert.equal(await h.modalOpen(page), true);
    const ids = await page.$$eval('#ajax-modal input[name="ids[]"]', (inputs) => inputs.map((i) => i.value));
    assert.deepEqual(ids, ['3']);
    assert.equal(await page.inputValue('#cma_notes'), 'Typed for issue 3');
  } finally {
    await page.unroute('**/context_menu_actions/notes/new**');
  }
  await page.keyboard.press('Escape');
  await page.waitForSelector('#ajax-modal', { state: 'hidden' });
  h.assertNoErrors(errors);
});

test('writes one note when submit is hit twice', async () => {
  const { page, errors } = env;
  await h.openList(page);
  await h.openNotesFromMenu(page, 3);
  await page.keyboard.type('Only once please');
  await page.keyboard.press('Control+Enter');
  await page.keyboard.press('Control+Enter');
  await page.waitForSelector('#ajax-modal', { state: 'hidden' });

  await page.goto(h.BASE + '/issues/3');
  const count = await page.$$eval('.journal .wiki', (notes) => notes.filter((n) => n.innerText.includes('Only once please')).length);
  assert.equal(count, 1);
  h.assertNoErrors(errors);
});

test('explains a refused or failed request in the user language and keeps the text', async () => {
  const { page } = env;
  await h.openList(page);
  await page.route('**/context_menu_actions/notes', (route) => route.fulfill({ status: 403, body: '' }));
  await h.openNotesFromMenu(page, 3);
  await page.keyboard.type('Refused');
  await page.keyboard.press('Control+Enter');
  await page.waitForSelector('#ajax-modal #errorExplanation');
  assert.match(await page.textContent('#ajax-modal #errorExplanation'), /You are not authorized to access this page/);
  assert.equal(await page.inputValue('#cma_notes'), 'Refused');

  await page.unroute('**/context_menu_actions/notes');
  await page.route('**/context_menu_actions/notes', (route) => route.fulfill({ status: 401, body: '' }));
  await page.click('#ajax-modal .cma-submit');
  await page.waitForFunction(() => /Your session has expired/.test($('#ajax-modal #errorExplanation').text()));
  assert.equal(await page.inputValue('#cma_notes'), 'Refused');

  await page.unroute('**/context_menu_actions/notes');
  await page.route('**/context_menu_actions/notes', (route) => route.abort('connectionfailed'));
  await page.click('#ajax-modal .cma-submit');
  // No answer: the outcome is unknown, and the message says so.
  await page.waitForFunction(() => /The request did not complete/.test($('#ajax-modal #errorExplanation').text()));
  assert.equal(await page.inputValue('#cma_notes'), 'Refused');
  assert.equal(await page.evaluate(() => document.activeElement.id), 'cma_notes');
  await page.unroute('**/context_menu_actions/notes');
  await page.keyboard.press('Escape');
  await page.waitForSelector('#ajax-modal', { state: 'hidden' });
});

// An answer that arrives after its dialog was closed, while another dialog is
// open: it updates the list, and leaves the open dialog, its text and its
// issues alone.
test('a late answer to a closed dialog leaves the dialog open now alone', async () => {
  const { page, errors, dialogs } = env;
  await h.openList(page);
  const held = [];
  await page.route('**/context_menu_actions/notes', (route) => { held.push(route); });
  try {
    await lateAnswers(page, held, dialogs);
  } finally {
    await page.unroute('**/context_menu_actions/notes');
  }
  h.assertNoErrors(errors);
});

async function lateAnswers(page, held, dialogs) {
  async function submitAndCancel(id, text) {
    await h.openNotesFromMenu(page, id);
    await page.keyboard.type(text);
    await page.keyboard.press('Control+Enter');
    for (let i = 0; i < 100 && held.length === 0; i++) { await page.waitForTimeout(50); }
    assert.equal(held.length, 1, 'the request is on its way');
    await page.click('#ajax-modal a:has-text("Cancel")');
    await page.waitForSelector('#ajax-modal', { state: 'hidden' });
  }

  async function assertUntouched(id, text) {
    assert.equal(await h.modalOpen(page), true, 'the open dialog stays open');
    assert.equal(await page.inputValue('#cma_notes'), text);
    const ids = await page.$$eval('#ajax-modal input[name="ids[]"]', (inputs) => inputs.map((i) => i.value));
    assert.deepEqual(ids, [String(id)]);
    assert.equal(await page.$('#ajax-modal #errorExplanation'), null);
  }

  // A saved answer.
  await submitAndCancel(3, 'Late answer');
  await h.openNotesFromMenu(page, 7);
  await page.keyboard.type('Typed meanwhile');
  await held.shift().continue();
  await page.waitForFunction(() => /Late answer/.test($('tr#issue-3').nextAll('tr').first().find('td.last_notes').text()));
  await assertUntouched(7, 'Typed meanwhile');
  await page.click('#ajax-modal a:has-text("Cancel")');
  await page.waitForSelector('#ajax-modal', { state: 'hidden' });

  // A failed answer: it must not narrow the open dialog to the issue that failed.
  await submitAndCancel(2, 'Will fail late');
  await h.openNotesFromMenu(page, 7);
  await page.keyboard.type('Still mine');
  await held.shift().continue();
  await page.waitForFunction(() => /Failed to save/.test($('#cma-notice').text()));
  assert.equal(await page.evaluate(() => $('#cma-notice').hasClass('error')), true);
  await assertUntouched(7, 'Still mine');

  assert.equal(dialogs.seen.length, 3, 'Cancel asks, once per dialog with typed text');
  assert.ok(dialogs.seen.every((m) => /unsaved text/.test(m)));
  assert.equal(await page.evaluate(() => window.cmaNoReload), true);
  await page.click('#ajax-modal a:has-text("Cancel")');
  await page.waitForSelector('#ajax-modal', { state: 'hidden' });
}

// Core's toggleRowGroup flips every row of a group: a Last notes row added to
// a collapsed group must start hidden, so expanding shows it with its issue.
test('a Last notes row added in a collapsed group stays hidden until the group opens', async () => {
  const { page, errors } = env;
  await h.openList(page, h.LIST + '&group_by=status');
  const hidden = await issueIdBySubject(page, 'Meeting item 38');
  assert.ok(hidden);
  assert.equal(await h.lastNotesText(page, hidden), null, 'no Last notes row yet');

  await page.click(`tr#issue-${hidden} td.checkbox input`);
  await page.click('tr#issue-8 td.checkbox input');
  const toggle = (id) => page.evaluate((issueId) => {
    const group = $(`tr#issue-${issueId}`).prevAll('tr.group').first();
    group.find('[onclick*="toggleRowGroup"]').first().trigger('click');
  }, id);
  await toggle(hidden);
  assert.equal(await page.isVisible(`tr#issue-${hidden}`), false, 'group collapsed');

  await page.click('tr#issue-8 td.status', { button: 'right' });
  await page.waitForSelector('#context-menu a.cma-menu-link', { state: 'visible' });
  await page.click('#context-menu a.cma-menu-link');
  await page.waitForSelector('#ajax-modal textarea#cma_notes', { state: 'visible' });
  assert.match(await page.textContent('#ajax-modal .cma-issues summary'), /2 issues/);
  await page.keyboard.type('Noted in a collapsed group');
  await page.keyboard.press('Control+Enter');
  await page.waitForFunction(() => !$('#ajax-modal').is(':visible') || $('#ajax-modal #errorExplanation').length > 0);
  assert.equal(await page.evaluate(() => $('#ajax-modal #errorExplanation').text()), '');

  const notesRowVisible = (id) => page.evaluate((issueId) => $(`tr#issue-${issueId}`).nextAll('tr').first().find('td.last_notes').is(':visible'), id);
  assert.match(await h.lastNotesText(page, hidden), /Noted in a collapsed group/);
  assert.equal(await notesRowVisible(hidden), false, 'hidden with its group');
  assert.equal(await notesRowVisible(8), true);
  await toggle(hidden);
  assert.equal(await page.isVisible(`tr#issue-${hidden}`), true);
  assert.equal(await notesRowVisible(hidden), true, 'shown with its group');
  assert.equal(await page.evaluate(() => window.cmaNoReload), true);
  h.assertNoErrors(errors);
});
