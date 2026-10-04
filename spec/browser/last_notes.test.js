'use strict';

// F3: the "Add a note" link in each Last notes cell.

const { test, before, after, beforeEach } = require('node:test');
const assert = require('node:assert/strict');
const h = require('./helpers');

let env;

before(async () => { env = await h.launch(); await h.login(env.page); });
after(async () => { await env.browser.close(); });
beforeEach(() => { env.errors.length = 0; env.dialogs.seen.length = 0; env.dialogs.mode = 'accept'; });

function linksIn(page, id) {
  return page.evaluate((issueId) => {
    const row = document.querySelector(`tr#issue-${issueId}`);
    let next = row && row.nextElementSibling;
    while (next && !next.classList.contains('hascontextmenu')) {
      const cell = next.querySelector('td.last_notes');
      if (cell) { return cell.querySelectorAll('a.cma-last-notes-link').length; }
      next = next.nextElementSibling;
    }
    return null;
  }, id);
}

test('puts one link in every Last notes cell, and running again adds none', async () => {
  const { page, errors } = env;
  await h.openList(page);
  assert.equal(await linksIn(page, 1), 1);
  await page.evaluate(() => RedmineContextMenuActions.applyLastNotesLinks());
  await page.evaluate(() => RedmineContextMenuActions.applyLastNotesLinks());
  assert.equal(await linksIn(page, 1), 1);
  assert.equal(await page.$$eval('td.last_notes', (cells) => cells.every((c) => c.querySelectorAll('a.cma-last-notes-link').length === 1)), true);
  h.assertNoErrors(errors);
});

test('opens the dialog for that issue and puts the link back after the save', async () => {
  const { page, errors } = env;
  await h.openList(page);
  await page.click('tr#issue-1 + tr td.last_notes a.cma-last-notes-link');
  await page.waitForSelector('#ajax-modal textarea#cma_notes', { state: 'visible' });
  const ids = await page.$$eval('#ajax-modal input[name="ids[]"]', (inputs) => inputs.map((i) => i.value));
  assert.deepEqual(ids, ['1']);

  await page.keyboard.type('From the Last notes link');
  await page.keyboard.press('Control+Enter');
  await page.waitForSelector('#ajax-modal', { state: 'hidden' });
  assert.match(await h.lastNotesText(page, 1), /From the Last notes link/);
  assert.equal(await linksIn(page, 1), 1, 'link re-applied to the new cell');
  assert.equal(await page.evaluate(() => document.activeElement.classList.contains('cma-last-notes-link')), true, 'focus back on the link');
  assert.equal(await page.evaluate(() => window.cmaNoReload), true);
  h.assertNoErrors(errors);
});

test('works with the keyboard only', async () => {
  const { page, errors } = env;
  await h.openList(page);
  await page.focus('tr#issue-1 + tr td.last_notes a.cma-last-notes-link');
  await page.keyboard.press('Enter');
  await page.waitForSelector('#ajax-modal textarea#cma_notes', { state: 'visible' });
  assert.equal(await page.evaluate(() => document.activeElement.id), 'cma_notes');
  await page.keyboard.type('Keyboard only');
  await page.keyboard.press('Control+Enter');
  await page.waitForSelector('#ajax-modal', { state: 'hidden' });
  assert.match(await h.lastNotesText(page, 1), /Keyboard only/);
  h.assertNoErrors(errors);
});

test('does nothing on a page without Last notes', async () => {
  const { page, errors } = env;
  await page.goto(h.BASE + '/projects/ecookbook/issues?set_filter=1&c[]=subject');
  assert.equal(await page.$$eval('a.cma-last-notes-link', (links) => links.length), 0);
  await page.evaluate(() => RedmineContextMenuActions.applyLastNotesLinks());
  h.assertNoErrors(errors);
});
