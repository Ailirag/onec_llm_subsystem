import { mkdir, writeFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import { chromium } from 'playwright';

function readArgument(name, fallback = '') {
  const prefix = `--${name}=`;
  const value = process.argv.find((item) => item.startsWith(prefix));
  return value ? value.slice(prefix.length) : fallback;
}

function oneLine(value) {
  return String(value || '').replace(/\s+/g, ' ').trim();
}

const url = readArgument('url');
const artifactDirectory = resolve(readArgument('artifact-dir', '.'));
const timeout = Number(readArgument('timeout-ms', '15000'));
const jsonPath = resolve(artifactDirectory, 'startup-error-details.json');
const textPath = resolve(artifactDirectory, 'startup-error-details.txt');
const screenshotPath = resolve(artifactDirectory, 'startup-error-details.png');

if (!url) {
  throw new Error('Web UI startup diagnostic requires --url.');
}

await mkdir(artifactDirectory, { recursive: true });

let browser;
const result = {
  schemaVersion: 1,
  url,
  state: 'diagnostic-error',
  originalMessage: '',
  details: '',
  detailsOpened: false,
  screenshot: '',
  error: '',
};

try {
  browser = await chromium.launch({ headless: true });
  const page = await browser.newPage();
  await page.goto(url, { waitUntil: 'domcontentloaded', timeout });

  let outcome = 'unknown';
  try {
    outcome = await page.waitForFunction(() => {
      const visible = (element) => Boolean(element && element.offsetWidth > 0);
      if (document.querySelector('#themesCell_theme_0')) return 'client';
      if (visible(document.querySelector('#messageBoxText'))) return 'blocked';
      return false;
    }, null, { timeout }).then((handle) => handle.jsonValue());
  } catch {
    outcome = 'unknown';
  }

  if (outcome === 'client') {
    result.state = 'healthy-on-retry';
  } else if (outcome === 'blocked') {
    result.state = 'blocked';
    result.originalMessage = await page.locator('#messageBoxText').innerText().catch(() => '');

    const detailsLink = page.locator('#startupErrorDetails');
    if (await detailsLink.isVisible().catch(() => false)) {
      await detailsLink.click({ timeout: 3000 });
      result.detailsOpened = true;
      await page.waitForTimeout(300);
    }

    const evidence = await page.evaluate(() => {
      const visible = (element) => Boolean(element && element.offsetWidth > 0);
      const values = Array.from(document.querySelectorAll('textarea, input'))
        .filter(visible)
        .map((element) => String(element.value || '').trim())
        .filter(Boolean);
      const windows = Array.from(document.querySelectorAll('[role="dialog"], [id$="win"]'))
        .filter(visible)
        .map((element) => String(element.innerText || '').trim())
        .filter(Boolean);
      return { values, windows };
    });

    const candidates = [...evidence.values, ...evidence.windows]
      .map((value) => value.trim())
      .filter((value) => value && value !== result.originalMessage);
    result.details = candidates.find((value) =>
      /Описание ошибки|CommonModule|ОбщийМодуль|по причине:/i.test(value)) || candidates[0] || '';
  } else {
    result.state = 'not-reproduced';
  }

  await page.screenshot({ path: screenshotPath, fullPage: true });
  result.screenshot = screenshotPath;
} catch (error) {
  result.state = 'diagnostic-error';
  result.error = error instanceof Error ? error.message : String(error);
  process.exitCode = 2;
} finally {
  await browser?.close().catch(() => {});
}

await writeFile(jsonPath, `${JSON.stringify(result, null, 2)}\n`, 'utf8');
const text = [
  `state: ${result.state}`,
  `url: ${result.url}`,
  result.originalMessage ? `message: ${result.originalMessage}` : '',
  result.details ? `details:\n${result.details}` : '',
  result.error ? `diagnostic error: ${result.error}` : '',
  result.screenshot ? `screenshot: ${result.screenshot}` : '',
].filter(Boolean).join('\n');
await writeFile(textPath, `${text}\n`, 'utf8');

console.log(`Web UI startup diagnostic: ${result.state}`);
if (result.details) console.log(`Web UI startup details: ${oneLine(result.details)}`);
if (result.error) console.log(`Web UI startup diagnostic error: ${oneLine(result.error)}`);
console.log(`Web UI startup diagnostic artifact: ${jsonPath}`);
