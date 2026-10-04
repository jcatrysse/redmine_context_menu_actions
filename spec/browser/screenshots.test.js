'use strict';

// Screenshots for the README and the UX review. Runs only with CMA_SCREENSHOTS
// set to the directory to write to:
//   CMA_SCREENSHOTS=docs/screenshots/6.1 ./.codex/browser_test.sh screenshots

const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const h = require('./helpers');

const DIR = process.env.CMA_SCREENSHOTS;
const skip = !DIR && 'set CMA_SCREENSHOTS to write screenshots';
const LIST = h.LIST.replace('&c[]=last_notes', '&c[]=due_date&c[]=last_notes');
let env;

before(async () => {
  if (skip) { return; }
  env = await h.launch();
  await env.page.setViewportSize({ width: 1100, height: 720 });
  await h.login(env.page);
});
after(async () => { if (env) { await env.browser.close(); } });

// The part of the page around an element, so the dialog or menu is shown in
// its context without the whole page.
async function shot(name, selector, pad = 40) {
  const { page } = env;
  const box = await page.locator(selector).first().boundingBox();
  assert.ok(box, `${selector} not visible for ${name}`);
  const viewport = page.viewportSize();
  const x = Math.max(0, box.x - pad);
  const y = Math.max(0, box.y - pad);
  const clip = { x, y, width: Math.min(viewport.width - x, box.width + 2 * pad), height: Math.min(viewport.height - y, box.height + 2 * pad) };
  await page.screenshot({ path: path.join(DIR, `${name}.png`), clip });
}

// Escape closes an open @mention list first, the dialog with the next press.
async function closeDialog() {
  env.dialogs.mode = 'accept';
  for (let i = 0; i < 3 && await h.modalOpen(env.page); i++) {
    await env.page.keyboard.press('Escape');
    await env.page.waitForTimeout(150);
  }
  await env.page.waitForSelector('#ajax-modal', { state: 'hidden' });
}

async function menuFor(ids) {
  const { page } = env;
  await h.openList(page, LIST);
  for (const id of ids) { await page.click(`tr#issue-${id} td.checkbox input`); }
  await page.click(`tr#issue-${ids[ids.length - 1]} td.status`, { button: 'right' });
  await page.waitForSelector('#context-menu a.cma-menu-link', { state: 'visible' });
  await page.mouse.move(0, 0);
}

test('context menu, one issue and several', { skip }, async () => {
  await menuFor([1]);
  await shot('01-context-menu-single', '#context-menu', 60);
  await menuFor([1, 3, 7]);
  await shot('02-context-menu-multi', '#context-menu', 60);
});

test('notes dialog, one issue', { skip }, async () => {
  const { page } = env;
  await h.openList(page, LIST);
  await h.openNotesFromMenu(page, 1);
  await page.keyboard.type('Agreed in the meeting: @jsmith prepares the test plan, see #3.');
  await shot('03-notes-dialog-single', '.ui-dialog', 20);
  await closeDialog();
});

test('notes dialog, several issues', { skip }, async () => {
  const { page } = env;
  await menuFor([1, 3, 7]);
  await page.click('#context-menu a.cma-menu-link');
  await page.waitForSelector('#ajax-modal textarea#cma_notes', { state: 'visible' });
  await page.click('#ajax-modal .cma-issues summary');
  await page.keyboard.type('Status reviewed in the weekly meeting.');
  await shot('04-notes-dialog-multi', '.ui-dialog', 20);
  await closeDialog();
});

test('notes dialog, error and partial success', { skip }, async () => {
  const { page } = env;
  await h.openList(page, LIST);
  await h.openNotesFromMenu(page, 2);
  await page.keyboard.type('This issue needs a due date first.');
  await page.keyboard.press('Control+Enter');
  await page.waitForSelector('#ajax-modal #errorExplanation');
  await shot('05-notes-dialog-error', '.ui-dialog', 20);
  await closeDialog();

  await menuFor([2, 3]);
  await page.click('#context-menu a.cma-menu-link');
  await page.waitForSelector('#ajax-modal textarea#cma_notes', { state: 'visible' });
  await page.keyboard.type('Discussed, see the minutes.');
  await page.keyboard.press('Control+Enter');
  await page.waitForSelector('#ajax-modal #errorExplanation');
  await shot('06-notes-dialog-partial', '.ui-dialog', 20);
  await closeDialog();
});

test('list after a save, with the Last notes link', { skip }, async () => {
  const { page } = env;
  await h.openList(page, LIST);
  await h.openNotesFromMenu(page, 7);
  await page.keyboard.type('Customer confirmed the date, closing next week.');
  await page.keyboard.press('Control+Enter');
  await page.waitForSelector('#ajax-modal', { state: 'hidden' });
  await page.waitForTimeout(300);
  await page.evaluate(() => window.scrollTo(0, document.querySelector('tr#issue-7').getBoundingClientRect().top + window.scrollY - 260));
  const viewport = page.viewportSize();
  await page.screenshot({ path: path.join(DIR, '07-list-after-save.png'), clip: { x: 0, y: 0, width: viewport.width, height: 480 } });

  await page.waitForTimeout(2300);
  await page.hover('tr#issue-1 + tr td.last_notes a.cma-last-notes-link');
  await shot('08-last-notes-link', 'tr#issue-1 + tr td.last_notes', 40);
});

test('dates dialog, one issue, mixed values and an error', { skip }, async () => {
  const { page } = env;
  await h.openList(page, LIST);
  await h.rightClickIssue(page, 1);
  await page.click('#context-menu a.icon-calendar');
  await page.waitForSelector('#ajax-modal form.cma-dates-form', { state: 'visible' });
  // A real mouse click: Playwright's actionability check refuses the flex legend
  // of 6.x although a click at that point does open it.
  const legend = await page.locator('#ajax-modal .cma-dates-notes legend').boundingBox();
  await page.mouse.click(legend.x + legend.width / 2, legend.y + legend.height / 2);
  await shot('09-dates-dialog-single', '.ui-dialog', 20);
  await closeDialog();

  await menuFor([1, 3]);
  await page.click('#context-menu a.icon-calendar');
  await page.waitForSelector('#ajax-modal form.cma-dates-form', { state: 'visible' });
  await shot('10-dates-dialog-mixed', '.ui-dialog', 20);
  await closeDialog();

  await h.openList(page, LIST);
  await h.rightClickIssue(page, 3);
  await page.click('#context-menu a.icon-calendar');
  await page.waitForSelector('#ajax-modal form.cma-dates-form', { state: 'visible' });
  await page.fill('#cma_start_date', '2031-05-10');
  await page.fill('#cma_due_date', '2031-05-01');
  await page.click('#ajax-modal .cma-submit');
  await page.waitForSelector('#ajax-modal #errorExplanation');
  await shot('11-dates-dialog-error', '.ui-dialog', 20);
  await closeDialog();
});

test('settings page', { skip }, async () => {
  const { page } = env;
  await page.goto(h.BASE + '/settings/plugin/redmine_context_menu_actions');
  await shot('12-settings', '#settings', 20);
});
