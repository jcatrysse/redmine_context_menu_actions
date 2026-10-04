'use strict';

// Shared steps for the browser specs. Plain node:test + Playwright, see
// .codex/browser_test.sh.

const assert = require('node:assert/strict');
const { chromium } = require(process.env.PLAYWRIGHT_MODULE || 'playwright');

const BASE = process.env.CMA_BASE_URL || 'http://127.0.0.1:3333';
const VERSION = process.env.CMA_REDMINE_VERSION || '';

// The issue list of the meeting: ordered by id, with the Last notes block.
const LIST = '/projects/ecookbook/issues?set_filter=1&f[]=status_id&op[status_id]=*' +
  '&c[]=tracker&c[]=status&c[]=subject&c[]=last_notes&sort=id&per_page=100';

async function launch() {
  const browser = await chromium.launch();
  const context = await browser.newContext({ viewport: { width: 1280, height: 800 } });
  const page = await context.newPage();
  const errors = [];
  page.on('pageerror', (error) => errors.push(String(error)));
  page.on('console', (message) => {
    if (message.type() === 'error') { errors.push(message.text()); }
  });
  // window.confirm and friends: recorded, then accepted or dismissed as the
  // spec says.
  const dialogs = { mode: 'accept', seen: [] };
  page.on('dialog', (dialog) => {
    dialogs.seen.push(dialog.message());
    return dialogs.mode === 'accept' ? dialog.accept() : dialog.dismiss();
  });
  return { browser, context, page, errors, dialogs };
}

async function login(page, login = 'admin', password = 'admin') {
  await page.goto(BASE + '/login');
  await page.fill('#username', login);
  await page.fill('#password', password);
  await Promise.all([page.waitForNavigation(), page.click('#login-submit')]);
}

async function openList(page, path = LIST) {
  await page.goto(BASE + path);
  await page.waitForSelector('table.list.issues');
  // Marks this document: a reload would lose it.
  await page.evaluate(() => { window.cmaNoReload = true; });
}

async function rightClickIssue(page, id) {
  // The status cell: core ignores a right click on a link, and the subject is one.
  await page.click(`tr#issue-${id} td.status`, { button: 'right' });
  await page.waitForSelector('#context-menu', { state: 'visible' });
}

async function openNotesFromMenu(page, id) {
  await rightClickIssue(page, id);
  await page.click('#context-menu a.cma-menu-link');
  await page.waitForSelector('#ajax-modal.cma-modal textarea#cma_notes', { state: 'visible' });
}

async function modalOpen(page) {
  return page.evaluate(() => $('#ajax-modal').is(':visible'));
}

function lastNotesText(page, id) {
  return page.evaluate((issueId) => {
    const row = document.querySelector(`tr#issue-${issueId}`);
    let next = row && row.nextElementSibling;
    while (next && !next.classList.contains('hascontextmenu')) {
      const cell = next.querySelector('td.last_notes');
      if (cell) { return cell.innerText; }
      next = next.nextElementSibling;
    }
    return null;
  }, id);
}

function assertNoErrors(errors) {
  assert.deepEqual(errors.filter((e) => !/favicon/.test(e)), []);
}

module.exports = {
  BASE, VERSION, LIST, launch, login, openList, rightClickIssue,
  openNotesFromMenu, modalOpen, lastNotesText, assertNoErrors
};
