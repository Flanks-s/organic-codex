// Existing Playwright + Chromium; this process owns only its blank test profile.
import { createRequire } from 'node:module';
import { createInterface } from 'node:readline';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const root = path.dirname(fileURLToPath(import.meta.url));
const modules = path.join(process.env.ORGANIC_CORE_RESOURCES, 'cua_node/lib/node_modules');
const require = createRequire(modules + '/playwright/package.json');
const { chromium } = require('playwright');
const executable = process.env.ORGANIC_CORE_CHROMIUM || undefined;
let browser;
const pages = new Map();
const historySessions = new Map();
const navigationOptions = { timeout: 15000, waitUntil: 'domcontentloaded' };
let sequence = 0;
async function historySession(page) {
  let session = historySessions.get(page);
  if (!session) {
    session = await page.context().newCDPSession(page);
    historySessions.set(page, session);
  }
  return session;
}
async function navigationState(page) {
  const session = await historySession(page);
  const { currentIndex, entries } = await session.send('Page.getNavigationHistory');
  return { canGoBack: currentIndex > 0, canGoForward: currentIndex + 1 < entries.length };
}
async function releaseHistorySession(page) {
  const session = historySessions.get(page);
  historySessions.delete(page);
  if (session) await session.detach().catch(() => {});
}
async function getBrowser() {
  const proxy=process.env.ORGANIC_BROWSER_PROXY;
  browser ??= await chromium.launch({ executablePath: executable, headless: true, ...(proxy?{proxy:{server:proxy,bypass:'localhost,127.0.0.1,[::1]'}}:{}) });
  return browser;
}
async function snapshot(page, id) { return { tabId: id, url: page.url(), title: await page.title(), dom: await page.locator('body').ariaSnapshot(), controls: await page.locator('input,button,output').evaluateAll(nodes => nodes.map(n => ({tag:n.tagName.toLowerCase(),id:n.id,label:n.getAttribute('aria-label'),text:n.textContent,value:n.value}))) }; }
async function execute(p) {
  if (p.action === 'tabs') {
    const tabs = await Promise.all([...pages].map(async ([id, page]) => ({
      tabId: id, url: page.url(), title: await page.title(), ...await navigationState(page),
    })));
    return { backend: 'independent-chromium', tabs };
  }
  if (p.action === 'discover') return { backend: 'independent-chromium', runtime: 'existing-playwright-1.57.0', browserVersion: browser?.version(), tabs: await Promise.all([...pages].map(([id, page]) => snapshot(page, id))) };
  if (p.action === 'new') {
    const page = await (await getBrowser()).newPage({ viewport: { width: 1100, height: 760 } });
    const id = String(++sequence);
    pages.set(id, page);
    page.once('close', () => {
      pages.delete(id);
      void releaseHistorySession(page);
    });
    const session = await historySession(page);
    await page.goto(p.url || 'about:blank');
    // The first opened URL starts the tab's history; discard Chromium's initial blank entry.
    await session.send('Page.resetNavigationHistory');
    return snapshot(page, id);
  }
  const page = pages.get(p.tabId);
  if (!page) throw new Error('Unknown owned browser tab: ' + p.tabId);
  if (p.action === 'back' || p.action === 'forward' || p.action === 'reload') {
    const history = await navigationState(page);
    if (p.action === 'back' && history.canGoBack) await page.goBack(navigationOptions);
    if (p.action === 'forward' && history.canGoForward) await page.goForward(navigationOptions);
    if (p.action === 'reload') await page.reload(navigationOptions);
    return snapshot(page, p.tabId);
  }
  if (p.action === 'snapshot') return snapshot(page, p.tabId);
  if (p.action === 'fill') { await page.locator(p.selector).fill(p.value); return snapshot(page, p.tabId); }
  if (p.action === 'click') { await page.locator(p.selector).click(); return snapshot(page, p.tabId); }
  if (p.action === 'screenshot') return { tabId:p.tabId,url:page.url(),title:await page.title(),...page.viewportSize(),mimeType: 'image/png', data: (await page.screenshot()).toString('base64') };
  if (p.action === 'close') {
    await releaseHistorySession(page);
    await page.close();
    return { closed: p.tabId };
  }
  throw new Error('Unknown action: ' + p.action);
}
const input = createInterface({ input: process.stdin });
for await (const line of input) {
  const msg = JSON.parse(line);
  try { process.stdout.write(JSON.stringify({ id: msg.id, result: await execute(msg.params) }) + '\n'); }
  catch (e) { process.stdout.write(JSON.stringify({ id: msg.id, error: { code: -32000, message: e.message } }) + '\n'); }
}
await browser?.close();

