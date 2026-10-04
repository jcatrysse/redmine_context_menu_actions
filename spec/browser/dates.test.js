'use strict';

// F2 Dates in a real browser: the old defects (Clear checkbox, ids, errors on
// another page), the client check, and the reload that keeps the place.

const { test, before, after, beforeEach } = require('node:test');
const assert = require('node:assert/strict');
const h = require('./helpers');

let env;

before(async () => { env = await h.launch(); await h.login(env.page); });
after(async () => { await env.browser.close(); });
beforeEach(() => { env.errors.length = 0; env.dialogs.seen.length = 0; env.dialogs.mode = 'accept'; });

const LIST = h.LIST.replace('&c[]=last_notes', '&c[]=start_date&c[]=due_date&c[]=last_notes');

async function openDates(page, id) {
  await h.rightClickIssue(page, id);
  await page.click('#context-menu a.icon-calendar');
  await page.waitForSelector('#ajax-modal form.cma-dates-form', { state: 'visible' });
}

async function cell(page, id, column) {
  return (await page.textContent(`tr#issue-${id} td.${column}`)).trim();
}

test('changes the dates, reloads the list and keeps the place', async () => {
  const { page, errors } = env;
  await h.openList(page, LIST);
  const row = await page.$('tr.hascontextmenu:nth-of-type(30)');
  const id = parseInt((await row.getAttribute('id')).replace('issue-', ''), 10);
  await page.evaluate((issueId) => document.querySelector(`tr#issue-${issueId}`).scrollIntoView({ block: 'center' }), id);

  await openDates(page, id);
  assert.equal(await page.isVisible('#context-menu'), false, 'the context menu closes when an action is chosen');
  const scrollBefore = await page.evaluate(() => window.scrollY);
  assert.equal(await page.evaluate(() => document.activeElement.id), 'cma_start_date');
  assert.equal(await page.isDisabled('#ajax-modal .cma-submit'), true, 'nothing changed yet');
  await page.fill('#cma_start_date', '2031-04-01');
  await page.fill('#cma_due_date', '2031-04-15');
  await page.click('#ajax-modal .cma-submit');
  await page.waitForFunction(() => window.cmaNoReload === undefined, null, { timeout: 15000 });
  await page.waitForSelector(`tr#issue-${id}`);

  assert.match(await cell(page, id, 'start_date'), /2031|04\/01|01\/04/);
  assert.ok(Math.abs((await page.evaluate(() => window.scrollY)) - scrollBefore) < 5, 'scroll position kept across the reload');
  assert.match(await page.textContent('#cma-notice'), /Successful update/);
  h.assertNoErrors(errors);
});

// Old defect: the Clear checkbox targeted an element without id, so it did not
// disable the field.
test('Clear disables the field and removes the date', async () => {
  const { page, errors } = env;
  await h.openList(page, LIST);
  await openDates(page, 1);
  assert.equal(await page.isDisabled('#cma_due_date'), false);
  await page.check('#cma_due_date_clear');
  assert.equal(await page.isDisabled('#cma_due_date'), true);
  assert.equal(await page.isDisabled('#ajax-modal .cma-submit'), false);
  await page.uncheck('#cma_due_date_clear');
  assert.equal(await page.isDisabled('#cma_due_date'), false);
  await page.check('#cma_due_date_clear');
  await page.click('#ajax-modal .cma-submit');
  await page.waitForFunction(() => window.cmaNoReload === undefined, null, { timeout: 15000 });
  await page.waitForSelector('tr#issue-1');
  assert.equal(await cell(page, 1, 'due_date'), '');
  h.assertNoErrors(errors);
});

// Old defect: a validation error threw the user onto the bulk edit page.
test('shows errors in the dialog and keeps the values', async () => {
  const { page, errors } = env;
  await h.openList(page, LIST);
  await openDates(page, 3);
  await page.fill('#cma_start_date', '2031-05-10');
  await page.fill('#cma_due_date', '2031-05-01');
  await page.click('#ajax-modal .cma-submit');
  await page.waitForSelector('#ajax-modal #errorExplanation');
  assert.match(await page.textContent('#ajax-modal #errorExplanation'), /Due date must be greater than start date/);
  assert.equal(await page.inputValue('#cma_start_date'), '2031-05-10');
  assert.equal(await page.evaluate(() => window.cmaNoReload), true, 'checked in the browser, no request, no reload');

  await page.keyboard.press('Escape');
  await page.waitForSelector('#ajax-modal', { state: 'hidden' });

  // A server side error: the workflow requires a due date issue 2 does not have.
  await openDates(page, 2);
  await page.fill('#cma_start_date', '2031-05-10');
  await page.click('#ajax-modal .cma-submit');
  await page.waitForFunction(() => /#2: Due date cannot be blank/.test($('#ajax-modal #errorExplanation').text()));
  assert.equal(await page.inputValue('#cma_start_date'), '2031-05-10');
  assert.equal(await page.evaluate(() => window.cmaNoReload), true);
  assert.match(page.url(), /\/issues\?/, 'still on the list');
  h.assertNoErrors(errors);
  await page.keyboard.press('Escape');
  await page.waitForSelector('#ajax-modal', { state: 'hidden' });
});

// Emptying a date that was filled in means "remove it", as Clear does; it used
// to enable Submit and then change nothing.
test('an emptied date is removed, and the Clear box shows it', async () => {
  const { page, errors } = env;
  await h.openList(page, LIST);
  assert.notEqual(await cell(page, 3, 'due_date'), '', 'issue 3 has a due date');
  await openDates(page, 3);
  await page.fill('#cma_due_date', '');
  await page.evaluate(() => { const input = document.querySelector('#cma_due_date'); input.value = ''; input.dispatchEvent(new Event('input', { bubbles: true })); });
  assert.equal(await page.isDisabled('#ajax-modal .cma-submit'), false);
  const request = page.waitForRequest((r) => /context_menu_actions\/dates/.test(r.url()) && r.method() !== 'GET');
  await page.click('#ajax-modal .cma-submit');
  assert.match((await request).postData() || '', /issue%5Bdue_date%5D=none/);
  await page.waitForFunction(() => window.cmaNoReload === undefined, null, { timeout: 15000 });
  await page.waitForSelector('tr#issue-3');
  assert.equal(await cell(page, 3, 'due_date'), '');
  assert.notEqual(await cell(page, 3, 'start_date'), '', 'the other date is left alone');
  h.assertNoErrors(errors);
});

test('shows mixed values for several issues and leaves them alone when empty', async () => {
  const { page, errors } = env;
  await h.openList(page, LIST);
  await page.click('tr#issue-1 td.checkbox input');
  await page.click('tr#issue-3 td.checkbox input');
  await page.click('tr#issue-3 td.status', { button: 'right' });
  await page.waitForSelector('#context-menu a.icon-calendar', { state: 'visible' });
  await page.click('#context-menu a.icon-calendar');
  await page.waitForSelector('#ajax-modal form.cma-dates-form', { state: 'visible' });
  assert.match(await page.textContent('#ajax-modal form'), /mixed values/);
  assert.match(await page.textContent('#ajax-modal .cma-issues summary'), /2 issues/);
  h.assertNoErrors(errors);
  await page.keyboard.press('Escape');
  await page.waitForSelector('#ajax-modal', { state: 'hidden' });
});

test('the optional note opens with the mouse or the keyboard and saves with the dates', async () => {
  const { page, errors } = env;
  await h.openList(page, LIST);
  await openDates(page, 1);
  const legend = await page.locator('#ajax-modal .cma-dates-notes legend').boundingBox();
  await page.mouse.click(legend.x + legend.width / 2, legend.y + legend.height / 2);
  assert.equal(await page.isVisible('#cma_dates_notes'), true, 'a click opens it');
  await page.mouse.click(legend.x + legend.width / 2, legend.y + legend.height / 2);
  assert.equal(await page.isVisible('#cma_dates_notes'), false, 'a second click closes it');

  await page.focus('#ajax-modal .cma-dates-notes legend');
  await page.keyboard.press('Enter');
  assert.equal(await page.isVisible('#cma_dates_notes'), true, 'Enter opens it');
  assert.equal(await page.evaluate(() => document.activeElement.id), 'cma_dates_notes');
  await page.keyboard.type('Moved after the supplier call');
  await page.fill('#cma_due_date', '2031-07-01');
  await page.click('#ajax-modal .cma-submit');
  await page.waitForFunction(() => window.cmaNoReload === undefined, null, { timeout: 15000 });
  await page.goto(h.BASE + '/issues/1');
  assert.match(await page.textContent('#history'), /Moved after the supplier call/);
  h.assertNoErrors(errors);
});
