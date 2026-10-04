'use strict';

// The dialog in other places the issue context menu appears, and the editor
// helpers it shares with core's notes field.

const { test, before, after, beforeEach } = require('node:test');
const assert = require('node:assert/strict');
const h = require('./helpers');

let env;

before(async () => { env = await h.launch(); await h.login(env.page); });
after(async () => { await env.browser.close(); });
beforeEach(() => { env.errors.length = 0; env.dialogs.seen.length = 0; env.dialogs.mode = 'accept'; });

async function visibleSuggestions(page) {
  return page.$$eval('.tribute-container li', (items) => items.filter((li) => li.offsetParent).map((li) => li.innerText.trim()));
}

// .codex/browser_test.sh turns CSRF protection back on, which Redmine's test
// environment switches off: every request in these specs carries a real token.
test('runs with CSRF protection on, as production does', async () => {
  const { page, errors } = env;
  await h.openList(page);
  assert.ok(await page.getAttribute('meta[name="csrf-token"]', 'content'), 'csrf meta tag');
  await h.openNotesFromMenu(page, 1);
  await page.keyboard.type('With a real token');
  const request = page.waitForRequest((r) => /context_menu_actions\/notes/.test(r.url()) && r.method() === 'POST');
  await page.keyboard.press('Control+Enter');
  // rails-ujs sends it as a header; Rails 7 also puts it in a remote form.
  const sent = await request;
  const token = sent.headers()['x-csrf-token'] || (/authenticity_token=([^&]+)/.exec(sent.postData() || '') || [])[1];
  assert.ok(token, 'the request carries a token');
  await page.waitForSelector('#ajax-modal', { state: 'hidden' });
  assert.match(await h.lastNotesText(page, 1), /With a real token/);
  h.assertNoErrors(errors);
});

test('suggests users after @, as the issue page does', async () => {
  const { page, errors } = env;
  await h.openList(page);
  await h.openNotesFromMenu(page, 1);

  await page.keyboard.type('Ask @js');
  await page.waitForSelector('.tribute-container li:has-text("John Smith")', { state: 'visible', timeout: 10000 });
  await page.click('.tribute-container li:has-text("John Smith")');
  assert.match(await page.inputValue('#cma_notes'), /@jsmith/);
  h.assertNoErrors(errors);
  await page.keyboard.press('Escape');
  await page.waitForSelector('#ajax-modal', { state: 'hidden' });
});

// Parity rather than a version check: whatever core's own notes field
// suggests after "#Cannot" on this Redmine, the dialog suggests the same.
// Sampled once the answer is in and the list had time to show, not after a
// fixed delay: under load a fixed delay read an empty list on one side.
async function suggestionsAfter(page, text) {
  const answer = page.waitForResponse((r) => /\/issues\/auto_complete\?.*q=Cannot/.test(r.url()));
  await page.keyboard.type(text);
  await answer;
  await page.waitForFunction(() => [...document.querySelectorAll('.tribute-container li')].some((li) => li.offsetParent),
    null, { timeout: 2000 }).catch(() => {});
  await page.waitForTimeout(200);
  return visibleSuggestions(page);
}

test('suggests issues after #, exactly as the issue page does', async () => {
  const { page, errors } = env;
  await page.goto(h.BASE + '/issues/3/edit');
  await page.click('#issue_notes');
  const core = await suggestionsAfter(page, 'see #Cannot');
  console.log(`core suggests: ${JSON.stringify(core)}`);

  await h.openList(page);
  await h.openNotesFromMenu(page, 1);
  assert.deepEqual(await suggestionsAfter(page, 'see #Cannot'), core);

  await page.keyboard.press('Escape');
  if (core.length) {
    assert.equal(await h.modalOpen(page), true, 'Esc closes the suggestions first, not the dialog');
    await page.keyboard.press('Escape');
  }
  await page.waitForSelector('#ajax-modal', { state: 'hidden' });
  h.assertNoErrors(errors);
});

test('previews the note with the toolbar', async () => {
  const { page, errors } = env;
  await h.openList(page);
  await h.openNotesFromMenu(page, 1);
  await page.keyboard.type('Preview *this*');
  await page.click('#ajax-modal .jstTabs .tab-preview');
  await page.waitForFunction(() => /this/.test($('#ajax-modal .wiki-preview').text()), null, { timeout: 10000 });
  // Textile renders *this* as strong, CommonMark as em: either way, formatted.
  assert.match(await page.innerHTML('#ajax-modal .wiki-preview'), /<(strong|em)>this<\/(strong|em)>/);
  h.assertNoErrors(errors);
  await page.keyboard.press('Escape');
  await page.waitForSelector('#ajax-modal', { state: 'hidden' });
});

test('adds a note from the Gantt chart, where there is no Last notes block', async () => {
  const { page, errors } = env;
  await page.goto(h.BASE + '/projects/ecookbook/issues/gantt?set_filter=1&f[]=status_id&op[status_id]=*&month=1&year=2026&months=24');
  await page.waitForSelector('div.issue-subject.hascontextmenu');
  await page.click('div.issue-subject.hascontextmenu >> nth=0', { button: 'right', position: { x: 2, y: 5 } });
  await page.waitForSelector('#context-menu a.cma-menu-link', { state: 'visible' });
  await page.click('#context-menu a.cma-menu-link');
  await page.waitForSelector('#ajax-modal textarea#cma_notes', { state: 'visible' });
  await page.keyboard.type('Noted from the Gantt chart');
  await page.keyboard.press('Control+Enter');
  await page.waitForSelector('#ajax-modal', { state: 'hidden' });
  assert.match(await page.textContent('#cma-notice'), /Note added/);
  h.assertNoErrors(errors);
});

// My page shows several issue lists, each with its own columns. A Last notes
// row is only added to the list the action came from, if it shows Last notes.
test('on My page, adds a Last notes row only to the list the note came from', async () => {
  const { page, errors } = env;
  await h.openList(page, '/my/page');
  const id = await page.evaluate(() => {
    const cell = [...document.querySelectorAll('#block-issuesassignedtome td.subject')].find((td) => /On my page twice/.test(td.innerText));
    return cell ? parseInt(cell.closest('tr').id.replace('issue-', ''), 10) : null;
  });
  assert.ok(id, 'the issue is in the assigned list');
  assert.equal(await page.$$eval(`#block-issuesreportedbyme tr#issue-${id}`, (rows) => rows.length), 1, 'and in the reported list');

  await page.click(`#block-issuesassignedtome tr#issue-${id} td.status`, { button: 'right' });
  await page.waitForSelector('#context-menu a.cma-menu-link', { state: 'visible' });
  await page.click('#context-menu a.cma-menu-link');
  await page.waitForSelector('#ajax-modal textarea#cma_notes', { state: 'visible' });
  await page.keyboard.type('Added from My page');
  await page.keyboard.press('Control+Enter');
  await page.waitForSelector('#ajax-modal', { state: 'hidden' });

  const notesRow = (block) => page.evaluate(([b, issueId]) => {
    const next = document.querySelector(`#${b} tr#issue-${issueId}`).nextElementSibling;
    const cell = next && next.querySelector('td.last_notes');
    return cell ? cell.innerText : null;
  }, [block, id]);
  assert.match(await notesRow('block-issuesassignedtome'), /Added from My page/);
  assert.equal(await notesRow('block-issuesreportedbyme'), null, 'no Last notes row in a list without that column');
  assert.equal(await page.evaluate(() => window.cmaNoReload), true);
  h.assertNoErrors(errors);
});

test('leaves core modals as they were after a dialog closes', async () => {
  const { page, errors } = env;
  await h.openList(page);
  await h.openNotesFromMenu(page, 1);
  await page.keyboard.press('Escape');
  await page.waitForSelector('#ajax-modal', { state: 'hidden' });

  // Core's own modal on the same container: Watchers > Add from the context menu.
  await h.rightClickIssue(page, 1);
  await page.hover('#context-menu li.folder:has(a.icon-add) > a.submenu').catch(() => {});
  await page.evaluate(() => {
    const link = document.querySelector('#context-menu a.icon-add[href*="watchers/new"]');
    if (link) { link.click(); }
  });
  await page.waitForSelector('#ajax-modal #new-watcher-form, #ajax-modal form', { state: 'visible', timeout: 10000 });
  const parent = await page.evaluate(() => document.querySelector('.ui-dialog').parentElement.tagName);
  assert.equal(parent, 'BODY', 'core modal attached to body again');
  assert.equal(await page.evaluate(() => $('#ajax-modal').hasClass('cma-modal')), false);
  // jQuery UI's own placement, which keeps the title bar on screen.
  const position = await page.evaluate(() => {
    const p = $('#ajax-modal').dialog('option', 'position');
    return { collision: p.collision, using: typeof p.using };
  });
  assert.deepEqual(position, { collision: 'fit', using: 'function' });
  h.assertNoErrors(errors);
});

test('keeps the dialog title on screen in a low window', async () => {
  const { page, errors } = env;
  await page.setViewportSize({ width: 1280, height: 360 });
  try {
    await h.openList(page);
    await page.evaluate(() => window.scrollTo(0, 400));
    await h.openNotesFromMenu(page, 1);
    const top = await page.evaluate(() => document.querySelector('.ui-dialog').getBoundingClientRect().top);
    assert.ok(top >= 0, `dialog top at ${top}`);
    assert.equal(await page.isVisible('.ui-dialog .ui-dialog-titlebar-close'), true);
    await page.keyboard.press('Escape');
    await page.waitForSelector('#ajax-modal', { state: 'hidden' });
  } finally {
    await page.setViewportSize({ width: 1280, height: 800 });
  }
  h.assertNoErrors(errors);
});

// Core appends the table and code language pickers of the wiki toolbar to
// <body>; above a modal overlay they must still take the click.
test('the toolbar table and code language pickers work in the dialog', async () => {
  const { page, errors } = env;
  await h.openList(page);
  await h.openNotesFromMenu(page, 1);

  async function clickOnTop(selector) {
    const box = await page.locator(selector).first().boundingBox();
    const x = box.x + box.width / 2;
    const y = box.y + box.height / 2;
    const onTop = await page.evaluate(([px, py, sel]) => {
      const hit = document.elementFromPoint(px, py);
      return !!(hit && hit.closest(sel));
    }, [x, y, selector]);
    assert.equal(onTop, true, `${selector} is above the overlay`);
    await page.mouse.click(x, y);
  }

  await page.click('#ajax-modal .jstb_table');
  await page.waitForSelector('table.table-generator', { state: 'visible' });
  await clickOnTop('table.table-generator td[data-row="2"][data-col="2"]');
  assert.match(await page.inputValue('#cma_notes'), /\|/, 'a table was inserted');

  await page.fill('#cma_notes', '');
  await page.click('#ajax-modal .jstb_precode');
  await page.waitForSelector('ul.ui-menu li', { state: 'visible' });
  const language = (await page.textContent('ul.ui-menu li >> nth=0')).trim();
  await clickOnTop('ul.ui-menu li');
  assert.ok((await page.inputValue('#cma_notes')).includes(language), `code block for ${language}`);

  await page.fill('#cma_notes', '');
  await page.keyboard.press('Escape');
  await page.waitForSelector('#ajax-modal', { state: 'hidden' });
  h.assertNoErrors(errors);
});

// Core lays the wiki toolbar out on one line and clips what does not fit. The
// dialogs are narrower than the issue page and tab labels are longer in some
// languages: every button must stay reachable. Last in this file, it switches
// the language and back.
test('shows every wiki toolbar button in both dialogs, also with longer labels', async () => {
  const { page, errors } = env;
  const clipped = () => page.evaluate(() => {
    const box = document.querySelector('#ajax-modal .jstTabs').getBoundingClientRect();
    return [...document.querySelectorAll('#ajax-modal .jstElements button')]
      .filter((b) => b.offsetParent && b.getBoundingClientRect().right > box.right + 0.5)
      .map((b) => b.className);
  });
  const language = async (code) => {
    await page.goto(h.BASE + '/my/account');
    await page.selectOption('#user_language', code);
    await Promise.all([page.waitForNavigation(), page.click('#my_account_form input[type=submit]')]);
  };
  const check = async (code) => {
    await h.openList(page);
    await h.openNotesFromMenu(page, 1);
    assert.deepEqual(await clipped(), [], `${code}: notes dialog`);
    await page.keyboard.press('Escape');
    await page.waitForSelector('#ajax-modal', { state: 'hidden' });
    await h.rightClickIssue(page, 1);
    await page.click('#context-menu a.icon-calendar');
    await page.waitForSelector('#ajax-modal form.cma-dates-form', { state: 'visible' });
    await page.focus('#ajax-modal .cma-dates-notes legend');
    await page.keyboard.press('Enter');
    assert.equal(await page.isVisible('#cma_dates_notes'), true);
    assert.deepEqual(await clipped(), [], `${code}: dates dialog`);
    await page.keyboard.press('Escape');
    await page.waitForSelector('#ajax-modal', { state: 'hidden' });
  };

  await check('en');
  try {
    await language('nl');
    await check('nl');
  } finally {
    await language('en');
  }
  h.assertNoErrors(errors);
});
