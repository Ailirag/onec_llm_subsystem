// Библиотека этапа пользовательских инструкций.
//
// Текст этого файла подставляется ПЕРЕД текстом сценария, и вместе они
// исполняются как одно тело async-функции: импортов здесь быть не может, функции
// раннера web-test доступны глобально. Каталог вывода подставляет
// Build-UserGuide.ps1 вместо __GUIDE_OUTPUT__.
//
// Сценарию нужны две функции: step() снимает шаг, saveGuide() собирает файл.
// Помощники openLink(), openRow(), waitForForm(), plainText(), checkData()
// закрывают типовые причины нестабильных сценариев (см. «Помощники сценария»).
// Остальное — детали, которые сценарий знать не обязан; держать их здесь, а не
// в каждом сценарии, — весь смысл этого файла.
//
// Подсветка (target у step) находит поля, кнопки, команды и разделы, но не
// заголовки закладок формы: для такого шага target — null.

const guideOutput = '__GUIDE_OUTPUT__';
const guideSteps = [];
let guideStepNumber = 0;

// Снимки ужимаются на месте съёмки, а не после. Инструкция самодостаточна:
// картинки лежат в ней строкой data:, и каждый килобайт растёт ещё на треть от
// кодирования. Полноэкранный PNG веб-клиента — около мегабайта, десять шагов
// давали документ, который не пролезает почтой.
//
// Умолчание — png со снижением масштаба до css-пикселей: на экране с удвоенной
// плотностью это сразу вчетверо меньше пикселей без потери читаемости. JPEG
// мельче ещё в разы, но мылит текст, поэтому включается проектом осознанно.
const guideImageFormat = '__GUIDE_IMAGE_FORMAT__' === 'jpeg' ? 'jpeg' : 'png';
const guideImageQuality = Number('__GUIDE_IMAGE_QUALITY__') || 72;
const guideImageScale = '__GUIDE_IMAGE_SCALE__' === 'device' ? 'device' : 'css';
const guideMinWidth = Math.max(0, Number('__GUIDE_MIN_WIDTH__') || 0);
const guideKeepFiles = '__GUIDE_KEEP_FILES__' === 'true';

// Снимок берётся у страницы напрямую, а не общим помощником раннера: тот всегда
// отдаёт PNG в плотности устройства, а ужать его потом нечем — в теле сценария
// нет ни библиотек обработки картинок, ни права их ставить.
async function captureGuideShot() {
  const page = getPage();
  const width = await page.evaluate(() => window.innerWidth);
  if (guideMinWidth > 0 && width < guideMinWidth) {
    throw new Error(
      'Ширина кадра ' + width + ' px меньше userGuides.screenshot.minWidth=' +
      guideMinWidth + '. Разверните окно Chromium и закройте процессы от прежних прогонов.',
    );
  }
  const options = { type: guideImageFormat, scale: guideImageScale };
  if (guideImageFormat === 'jpeg') {
    options.quality = guideImageQuality;
  }
  return await page.screenshot(options);
}

// Ждёт, пока веб-клиент перестанет показывать собственные индикаторы ожидания:
// снимок, пойманный в середине перерисовки, читается как дефект интерфейса.
// Отказ ожидания инструкцию не валит — снимок будет, просто менее аккуратный.
async function waitForQuietUi(timeout = 60000) {
  try {
    const page = getPage();
    await page.waitForFunction(
      () => ![...document.querySelectorAll('.stateWindowSupportSurface')].some(element =>
        element.offsetWidth > 0 &&
        /^\s*(Поиск|Ожид|Searching|Please wait)/i.test(element.innerText || '')),
      null,
      { timeout },
    );
  }
  catch {
    return false;
  }
  return true;
}

// Исполняется в браузере: находит рамку подсветки, которую поставил раннер, и
// дорисовывает к ней стрелку и курсор мыши. Возвращает true либо причину отказа
// — сценарий не обязан падать из-за указателя, но молчать о нём тоже нельзя.
//
// Стрелка заходит с той стороны, где больше места, чтобы не перекрыть сам
// элемент.
function drawGuidePointer() {
  const previous = document.getElementById('__guide_pointer');
  if (previous) previous.remove();

  const frame = document.getElementById('__web_test_highlight');
  if (!frame) return 'рамка подсветки не найдена';
  const box = frame.getBoundingClientRect();
  if (!box.width || !box.height) return 'рамка подсветки нулевого размера';

  const target = { x: box.left + box.width / 2, y: box.top + box.height / 2 };
  const right = window.innerWidth - box.right;
  const below = window.innerHeight - box.bottom;
  const dx = right > 200 ? 1 : -1;
  const dy = below > 160 ? 1 : -1;

  const tip = {
    x: dx > 0 ? box.right + 6 : box.left - 6,
    y: dy > 0 ? box.bottom + 4 : box.top - 4,
  };
  const tail = { x: tip.x + dx * 130, y: tip.y + dy * 95 };

  // Размер SVG задаётся инлайновым стилем, в пикселях и с !important.
  // width/height — презентационные атрибуты, и ЛЮБОЕ правило «svg { ... }» из
  // стилей конфигурации их перебивает. Холст тогда молча остаётся 300x150, всё
  // за его границей обрезается, и на снимке нет указателя — без единой ошибки.
  const width = window.innerWidth;
  const height = window.innerHeight;

  const layer = document.createElement('div');
  layer.id = '__guide_pointer';
  layer.style.cssText = 'position:fixed;inset:0;z-index:2147483647;pointer-events:none';
  layer.innerHTML =
    '<svg viewBox="0 0 ' + width + ' ' + height + '" style="position:absolute;left:0;top:0' +
    ';width:' + width + 'px !important;height:' + height + 'px !important">' +
    '<defs><marker id="__guide_head" markerWidth="11" markerHeight="11" refX="9" refY="5.5"' +
    ' orient="auto"><path d="M0,0 L11,5.5 L0,11 z" fill="#d8341f"/></marker></defs>' +
    '<line x1="' + tail.x + '" y1="' + tail.y + '" x2="' + tip.x + '" y2="' + tip.y + '"' +
    ' stroke="#d8341f" stroke-width="3.5" stroke-linecap="round"' +
    ' marker-end="url(#__guide_head)"/>' +
    '<g transform="translate(' + (target.x - 5) + ',' + (target.y - 3) + ')">' +
    '<path d="M0,0 L0,18 L4.4,13.8 L7.2,20 L10,18.7 L7.2,12.7 L13,12.6 z"' +
    ' fill="#ffffff" stroke="#1d1d1f" stroke-width="1.4" stroke-linejoin="round"/>' +
    '</g></svg>';
  // Слой вешается на documentElement: так он рисуется поверх модальных окон 1С,
  // а pointer-events:none оставляет клики следующего шага настоящему элементу.
  document.documentElement.appendChild(layer);
  return true;
}

function removeGuidePointer() {
  const layer = document.getElementById('__guide_pointer');
  if (layer) layer.remove();
}

// ── Помощники сценария ───────────────────────────────────────────────────────
// То, что без них каждый сценарий пишет сам и одинаково ошибается: гонки веб-
// клиента после входа, строки по номерам нумератора, числа с неразрывным
// пробелом, снимок с неверными данными.

// Текст для сравнения: 1С разделяет разряды неразрывным пробелом (U+00A0), и
// «3 000,00» из таблицы не равно «3 000,00» из сценария. Все пробельные символы
// сводятся к одному обычному пробелу.
function plainText(value) {
  return String(value ?? '').replace(/\s+/g, ' ').trim();
}

// Ждёт форму, заголовок которой содержит titlePart. Нужна после входа: клиент
// открывает стартовые формы конфигурации не сразу, и переход, начатый раньше,
// они перекрывают. Возвращает false по истечении времени — сценарий решает сам.
async function waitForForm(titlePart, timeoutSeconds = 20) {
  for (let second = 0; second < timeoutSeconds; second++) {
    const state = await getFormState();
    if (String(state.title || '').includes(titlePart)) {
      return true;
    }
    await wait(1);
  }
  return false;
}

// Переход по навигационной ссылке с проверкой, что открылась нужная форма.
// Окно «Переход по ссылке» раннер не всегда распознаёт под всплывающими
// оповещениями — тогда «Перейти» нажимается здесь. Открылась не та форма (её
// перекрыла стартовая) — переход повторяется. Уже открытая форма при переходе
// только активируется и может показывать устаревшие данные: закрывайте формы
// после просмотра (closeForm), если вернётесь к ним после изменения данных.
async function openLink(link, titlePart, attempts = 4) {
  for (let attempt = 1; attempt <= attempts; attempt++) {
    let state = await navigateLink(link);
    if (String(state.title || '').includes('Переход по ссылке')) {
      try { state = await clickElement('Перейти'); } catch { state = await getFormState(); }
    }
    if (String(state.title || '').includes(titlePart)) {
      return state;
    }
    await wait(2);
  }
  throw new Error('Не открылась форма «' + titlePart + '» по ссылке ' + link);
}

// Открывает строку текущего списка, в которой есть текст. Номера документов на
// стенде раздаёт нумератор, и от прогона к прогону они разные, поэтому строка
// ищется по тому, что задал сид: дате, комментарию, наименованию. Открывается
// двойным щелчком по значению колонки keyColumn этой строки.
async function openRow(text, keyColumn = 'Номер') {
  const table = await readTable({ maxRows: 100 });
  const wanted = plainText(text);
  const row = table.rows.find(r => Object.values(r).some(v => plainText(v).includes(wanted)));
  if (!row) {
    throw new Error('В списке нет строки с «' + text + '». Колонки: ' + table.columns.join(', '));
  }
  const key = row[keyColumn] ?? Object.values(row).find(v => plainText(v).includes(wanted));
  await clickElement(String(key), { dblclick: true });
  return row;
}

// Проверка данных стенда перед снимком. Сценарий, который не проверяет
// результат, соберёт инструкцию и при неверных данных: снимки будут, а
// показывать они будут не то, что написано в шагах.
function checkData(condition, message) {
  if (!condition) {
    throw new Error('Данные стенда не те: ' + message);
  }
}

// Снимает шаг инструкции.
//
//   caption — что делает пользователь: заголовок шага;
//   target  — текст или имя элемента для подсветки (как в clickElement);
//             без него шаг снимается без указателя;
//   note    — зачем это нужно. Пишите сюда то, чего на снимке не видно:
//             «что» читатель и так увидит.
async function step(caption, target, note) {
  guideStepNumber += 1;
  if (target) {
    await highlight(target);
  }
  await waitForQuietUi();
  const page = getPage();
  await page.waitForTimeout(300);
  const drawn = await page.evaluate(drawGuidePointer);
  if (target && drawn !== true) {
    console.log('шаг ' + guideStepNumber + ': указатель не нарисован (' + drawn + ')');
  }
  const shot = await captureGuideShot();
  // Имя кадра латиницей и с ведущим нулём. Кириллица в имени вложения ломается
  // у части публикаторов, а сортировка по имени обязана совпадать с порядком
  // шагов — иначе оформитель соберёт инструкцию в случайном порядке.
  const fileName = 'step-' + String(guideStepNumber).padStart(2, '0') +
    (guideImageFormat === 'jpeg' ? '.jpg' : '.png');
  writeFileSync(guideOutput + '\\' + fileName, shot);
  await page.evaluate(removeGuidePointer);
  if (target) {
    await unhighlight();
  }
  guideSteps.push({
    number: guideStepNumber,
    caption: caption,
    note: note || '',
    image: fileName,
  });
}


// Записывает АРТЕФАКТ инструкции, а не документ. Оформление отделено нарочно:
// одному проекту нужен самодостаточный HTML, другому — страница в корпоративной
// вики, третьему — вложение к задаче. Пока съёмка и вёрстка были одним
// действием, каждый такой проект правил бы этот файл, то есть файл комплекта.
//
// Артефакт машиночитаем и самодостаточен: guide.json плюс кадры рядом. Дальше
// его берёт либо встроенный оформитель комплекта, либо адаптер проекта —
// договор описан в разделе «Пользовательские инструкции» договора процесса.
function saveGuide(title) {
  if (guideSteps.length === 0) {
    throw new Error('Инструкция пуста: сценарий не сделал ни одного step().');
  }

  const artifact = {
    schemaVersion: 1,
    title: title,
    // Время съёмки, а не оформления: инструкция устаревает вместе с системой,
    // с которой снята, а переоформить её можно когда угодно.
    capturedAt: new Date().toISOString(),
    imageFormat: guideImageFormat,
    steps: guideSteps,
  };

  const file = guideOutput + '\\guide.json';
  writeFileSync(file, JSON.stringify(artifact, null, 2), 'utf-8');
  console.log(JSON.stringify({ steps: guideSteps.length, file: file }));
}
