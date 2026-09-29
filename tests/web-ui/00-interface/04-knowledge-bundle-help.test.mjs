import { uiCommandTimeout, waitForUiReady } from './_wait-ready.mjs';

export const name = 'F1 открывает справку «Наборы знаний»';
export const tags = ['interface', 'help', 'knowledge-bundles'];
export const severity = 'critical';
export const timeout = uiCommandTimeout;

export default async function(ctx) {
  const { navigateLink, getPage, assert, step } = ctx;
  const page = getPage();

  await step('Открыть карточку набора знаний', async () => {
    await navigateLink('Catalog.AI_НаборыЗнаний');
    await waitForUiReady(getPage);
  });

  await step('Открыть справку по F1', async () => {
    await page.keyboard.press('F1');

    let actualTitle = '';
    for (let attempt = 0; attempt < 12; attempt += 1) {
      for (const frame of page.frames()) {
        actualTitle = await frame.locator('h1').first().textContent().catch(() => '') ?? '';
        if (actualTitle.trim() === 'Наборы знаний') {
          return;
        }
      }
      await page.waitForTimeout(500);
    }

    assert.equal(
      actualTitle.trim(),
      'Наборы знаний',
      `F1 не открыл нужную страницу справки; получено: ${actualTitle.trim() || 'нет страницы'}`,
    );
  });
}
