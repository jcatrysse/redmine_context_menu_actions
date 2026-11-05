'use strict';

// Export (JSON) from the context menu: the browser downloads one file, the list
// stays where it was, and the file holds the selected issues in the API format.

const { test, before, after, beforeEach } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const h = require('./helpers');

let env;

before(async () => { env = await h.launch(); });
after(async () => { await env.browser.close(); });
beforeEach(() => { env.errors.length = 0; });

// Each test signs in as someone else; /login redirects a signed in user.
async function loginAs(page, login, password) {
  await page.context().clearCookies();
  await h.login(page, login, password);
}

async function selectAndOpenMenu(page, ids) {
  await h.openList(page);
  for (const id of ids) { await page.click(`tr#issue-${id} td.checkbox input`); }
  await page.click(`tr#issue-${ids[ids.length - 1]} td.status`, { button: 'right' });
  await page.waitForSelector('#context-menu', { state: 'visible' });
}

async function setLimit(page, limit) {
  await page.goto(h.BASE + '/settings/plugin/redmine_context_menu_actions');
  await page.fill('#settings_export_json_limit', String(limit));
  await Promise.all([page.waitForNavigation(), page.click('#settings input[type=submit]')]);
}

test('downloads the selected issues as one JSON file and keeps the list', async () => {
  const { page, errors } = env;
  await loginAs(page, 'jsmith', 'jsmith');
  await selectAndOpenMenu(page, [1, 3]);

  const link = page.locator('#context-menu a.cma-export-link');
  assert.match(await link.innerText(), /\(JSON\)/);
  const [download] = await Promise.all([page.waitForEvent('download'), link.click()]);

  assert.match(download.suggestedFilename(), /^issues-\d{8}-\d{6}\.json$/);
  const document = JSON.parse(fs.readFileSync(await download.path(), 'utf8'));
  assert.deepEqual(Object.keys(document), ['exported_on', 'exported_by', 'redmine_version', 'issues', 'skipped']);
  assert.deepEqual(document.issues.map((issue) => issue.id), [1, 3]);
  assert.deepEqual(document.skipped, []);
  assert.equal(document.exported_by.name, 'John Smith');
  assert.ok(Array.isArray(document.issues[0].journals), 'journals included');
  assert.equal(document.issues[0].project.id, 1);

  // The page did not navigate, and the selection is still there.
  assert.equal(await page.evaluate(() => window.cmaNoReload), true);
  assert.equal(await page.locator('tr.context-menu-selection').count(), 2);
  assert.equal(await page.locator('#context-menu').isVisible(), false);
  h.assertNoErrors(errors);
});

test('the file holds what GET /issues/:id.json holds for the same user', async () => {
  const { page } = env;
  await loginAs(page, 'jsmith', 'jsmith');
  await selectAndOpenMenu(page, [1]);
  const [download] = await Promise.all([
    page.waitForEvent('download'), page.click('#context-menu a.cma-export-link')
  ]);
  const raw = fs.readFileSync(await download.path(), 'utf8');

  // The API of the browser server, with jsmith's key (REST is on in the seed).
  const key = await page.evaluate(async (base) => {
    const html = await (await fetch(base + '/my/api_key')).text();
    return (html.match(/<pre[^>]*>([0-9a-f]{40})<\/pre>/) || [])[1];
  }, h.BASE);
  assert.ok(key, 'no API key shown on /my/api_key');
  const api = await page.evaluate(async ([base, apiKey]) => {
    const response = await fetch(base + '/issues/1.json?include=journals,attachments,relations,children,watchers,changesets',
      { headers: { 'X-Redmine-API-Key': apiKey }, credentials: 'omit' });
    return response.text();
  }, [h.BASE, key]);
  const inner = api.replace(/^\{"issue":/, '').replace(/\}$/, '');
  assert.ok(raw.includes(inner), 'the entry differs from the API response');
});

test('is not in the menu without the permission', async () => {
  const { page } = env;
  await loginAs(page, 'dlopper', 'foo');
  await selectAndOpenMenu(page, [1]);
  assert.equal(await page.locator('#context-menu a.cma-export-link').count(), 0);
});

test('over the limit: no file, a message on the list', async () => {
  const { page, errors } = env;
  await loginAs(page, 'admin', 'admin');
  await setLimit(page, 2);
  try {
    await selectAndOpenMenu(page, [1, 2, 3]);
    await Promise.all([page.waitForNavigation(), page.click('#context-menu a.cma-export-link')]);
    const flash = await page.locator('#flash_error').innerText();
    assert.match(flash, /3 issues selected, more than the export limit of 2/);
    assert.match(page.url(), /\/projects\/ecookbook\/issues/);
  } finally {
    await setLimit(page, 100);
  }
  h.assertNoErrors(errors);
});
