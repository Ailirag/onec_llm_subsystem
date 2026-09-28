import fs from 'node:fs';
import { uiCommandTimeout, waitForUiReady } from './_wait-ready.mjs';

// Список проверяемых объектов не задан здесь и не задан картой в политике: он
// выводится из diff ветки скриптом Get-ChangedUiTargets.ps1 и приходит артефактом.
// Так проверка всегда адресная — открывается именно то, что изменено, — и не
// требует поддержки соответствия «объект → тест» руками.
//
// Артефакт может отсутствовать: сьют запускают и напрямую, без фазы. Тогда
// проверять нечего, и это не ошибка. Пустой params прогонщику не отдаём: файл без
// проверок выглядит как потерянный тест, поэтому оставляем одну информационную.
const artifactUrl = new URL('../../../.build/workflow/changed-ui-targets.json', import.meta.url);

// Отсутствие артефакта и его порча обрабатываются РАЗНО, и это принципиально.
// Отсутствие законно: сьют запускают и напрямую, без фазы, — тогда проверять нечего.
// Порча — дефект: если проглотить ошибку разбора, «изменений нет» и «артефакт
// испорчен» станут неразличимы, и прогон отчитается зелёным, ничего не проверив.
function readArtifact() {
  let raw;
  try {
    raw = fs.readFileSync(artifactUrl, 'utf8');
  }
  catch {
    return { targets: [], missing: true };
  }
  const parsed = JSON.parse(raw);
  if (!parsed || !Array.isArray(parsed.targets)) {
    throw new Error(
      `Артефакт изменённых объектов не содержит массива targets: ${String(artifactUrl)}`,
    );
  }
  return { targets: parsed.targets, missing: false };
}

const artifact = readArtifact();
const targets = artifact.targets.filter(t => t && t.openable && t.link);

export const name = 'Изменённый объект открывается: {title}';
export const params = targets.length > 0
  ? targets.map((t) => {
      const base = t.synonym ? `${t.synonym} (${t.link})` : t.link;
      // Расширение указывается в заголовке: в монорепозитории один и тот же объект
      // может меняться и в основной конфигурации, и в расширении, и без пометки
      // непонятно, чья правка проверяется.
      const from = Array.isArray(t.extensions) && t.extensions.length > 0
        ? ` из ${t.extensions.join(', ')}`
        : '';
      return { title: `${base}${from}`, link: t.link, empty: false };
    })
  : [{
      title: artifact.missing
        ? 'артефакт изменённых объектов отсутствует'
        : 'изменённых объектов интерфейса нет',
      empty: true,
      missing: artifact.missing,
    }];

export const tags = ['smoke', 'interface', 'changed-objects'];
export const severity = 'critical';
export const timeout = uiCommandTimeout;

export default async function(ctx) {
  const { link, title, empty, missing } = ctx.testInfo.param;
  const { navigateLink, getFormState, getPage, assert, step, log } = ctx;

  if (empty) {
    if (missing) {
      log('Артефакт изменённых объектов отсутствует: сьют запущен напрямую, без фазы.');
      log('Внутри фазы его пишет шаг changed-ui-targets, и тогда проверка становится адресной.');
    }
    else {
      log('В diff ветки нет изменённых объектов метаданных, открываемых из интерфейса.');
      log('Проверка выполнена вхолостую намеренно: объём прогона равен объёму правки.');
    }
    return;
  }

  await step(`Открыть ${title}`, async () => {
    // Навигационная ссылка вместо командного интерфейса: объект может не входить ни
    // в одну подсистему, и тогда openCommand до него не доберётся. Движок сам
    // разворачивает «Вид.Имя» в e1cib/app для отчётов и обработок и в e1cib/list
    // для списочных видов.
    await navigateLink(link);
    await waitForUiReady(getPage);

    // Проверяются только модальные и всплывающие ошибки, но НЕ stateText.
    // Свежеоткрытый отчёт законно пишет «Отчет не сформирован. Нажмите
    // "Сформировать"», и assert.noErrors счёл бы это отказом: объект открылся
    // нормально, а проверка падала. Тот же выбор сделан в 03-reports.
    const state = await getFormState();
    assert.ok(
      !state.errorModal && !state.errors?.modal && !state.errors?.balloon,
      `Открытие ${title} завершилось ошибкой: ${JSON.stringify(state.errors ?? {})}`,
    );
    assert.ok(state.formCount > 0, `После открытия ${title} форма не осталась открытой`);
  });
}
