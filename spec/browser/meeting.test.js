'use strict';

// The meeting this plugin is for: go down a filtered list, add a note to each
// issue. Ten issues with the mouse, then the same ten with the keyboard only.
// Every click and key press other than the note itself is counted.

const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const h = require('./helpers');

let env;
let ids;
const LIST = h.LIST;

before(async () => { env = await h.launch(); await h.login(env.page); });
after(async () => { await env.browser.close(); });

test('ten issues with the mouse: 2 clicks and Ctrl+Enter each, no reload', async () => {
  const { page, errors } = env;
  await h.openList(page, LIST);
  // Ten rows further down the list, past the fixtures.
  ids = (await page.$$eval('tr.hascontextmenu', (rows) => rows.map((r) => parseInt(r.id.replace('issue-', ''), 10)))).slice(15, 25);
  assert.equal(ids.length, 10);
  let clicks = 0;
  let keys = 0;

  for (const [i, id] of ids.entries()) {
    await page.click(`tr#issue-${id} td.status`, { button: 'right' }); clicks++;
    await page.click('#context-menu a.cma-menu-link'); clicks++;
    await page.waitForSelector('#ajax-modal textarea#cma_notes', { state: 'visible' });
    await page.keyboard.type(`Mouse round, item ${i + 1}`);
    await page.keyboard.press('Control+Enter'); keys++;
    await page.waitForSelector('#ajax-modal', { state: 'hidden' });
    assert.match(await h.lastNotesText(page, id), new RegExp(`Mouse round, item ${i + 1}`));
  }

  assert.equal(await page.evaluate(() => window.cmaNoReload), true, 'one page load for the whole round');
  console.log(`mouse: ${ids.length} issues, ${clicks} clicks, ${keys} shortcuts, ${(clicks + keys) / ids.length} actions per issue`);
  assert.equal(clicks, 2 * ids.length);
  h.assertNoErrors(errors);
});

test('the same issues with the keyboard only: Tab to the link, Enter, type, Ctrl+Enter', async () => {
  const { page, errors } = env;
  await h.openList(page, LIST);
  const link = (id) => `tr#issue-${id} + tr td.last_notes a.cma-last-notes-link`;
  await page.focus(link(ids[0]));
  let tabs = 0;
  let keys = 0;
  const tabsPerStep = [];

  for (const [i, id] of ids.entries()) {
    if (i > 0) {
      let steps = 0;
      while (!(await page.evaluate((sel) => document.activeElement === document.querySelector(sel), link(id)))) {
        await page.keyboard.press('Tab'); steps++;
        assert.ok(steps < 30, 'the next link is reachable with Tab');
      }
      tabs += steps;
      tabsPerStep.push(steps);
    }
    await page.keyboard.press('Enter'); keys++;
    await page.waitForSelector('#ajax-modal textarea#cma_notes', { state: 'visible' });
    assert.equal(await page.evaluate(() => document.activeElement.id), 'cma_notes');
    await page.keyboard.type(`Keyboard round, item ${i + 1}`);
    await page.keyboard.press('Control+Enter'); keys++;
    await page.waitForSelector('#ajax-modal', { state: 'hidden' });
    assert.match(await h.lastNotesText(page, id), new RegExp(`Keyboard round, item ${i + 1}`));
    assert.equal(await page.evaluate((sel) => document.activeElement === document.querySelector(sel), link(id)), true,
      'focus is back on the link of the issue just saved');
  }

  console.log(`keyboard: ${ids.length} issues, ${keys} Enter/Ctrl+Enter, ${tabs} Tab presses (${tabsPerStep.join(', ')} between issues), 0 clicks`);
  assert.equal(await page.evaluate(() => window.cmaNoReload), true);
  h.assertNoErrors(errors);
});
