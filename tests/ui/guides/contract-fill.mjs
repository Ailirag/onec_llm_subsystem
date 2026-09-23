// Сценарий инструкции: заполнение реквизитов договора помощником.
//
// Запускается вручную этапом tools\Build-UserGuide.ps1, а не вместе с тестами:
// он ходит в реальную базу, обращается к модели и занимает минуты.
//
// Скрипт исполняется как тело async-функции: импортов нет, все функции
// раннера доступны глобально, писать на диск можно через writeFileSync.
// Каталог вывода подставляет обертка переменной ВЫХОД.

const ЗАГОЛОВОК = 'Заполнение реквизитов договора AI-помощником';
const шаги = [];
let номерШага = 0;

// Рисует указатель на подсвеченный элемент и снимает экран.
//
// Подсветку и поиск элемента делает сам раннер (нечеткое совпадение по тексту),
// нам остается стрелка и курсор: на статичной картинке синей рамки мало —
// читатель должен видеть, куда именно ведут мышь.
async function снимок(подпись, цель, комментарий) {
	номерШага += 1;
	if (цель) {
		await highlight(цель);
	}
	const страница = getPage();
	// Полсекунды на то, чтобы интерфейс устоялся: снимок не должен поймать
	// середину перерисовки.
	await страница.waitForTimeout(500);
	const нарисовано = await страница.evaluate(нарисоватьУказатель);
	if (цель && нарисовано !== true) {
		console.log('шаг ' + номерШага + ': указатель не нарисован (' + нарисовано + ')');
	}
	const png = await screenshot();
	const файл = 'шаг-' + String(номерШага).padStart(2, '0') + '.png';
	writeFileSync(ВЫХОД + '\\' + файл, png);
	await страница.evaluate(убратьУказатель);
	if (цель) {
		await unhighlight();
	}
	шаги.push({
		номер: номерШага,
		подпись: подпись,
		комментарий: комментарий || '',
		данные: Buffer.from(png).toString('base64'),
	});
}

// Выполняется в браузере: ищет рамку подсветки и дорисовывает к ней
// стрелку и курсор. Стрелка заходит с той стороны, где больше места,
// чтобы не перекрывать сам элемент.
function нарисоватьУказатель() {
	const старый = document.getElementById('__guide_pointer');
	if (старый) старый.remove();

	const рамка = document.getElementById('__web_test_highlight');
	if (!рамка) return 'рамка подсветки не найдена';
	const r = рамка.getBoundingClientRect();
	if (!r.width || !r.height) return 'рамка подсветки нулевого размера';

	const цель = { x: r.left + r.width / 2, y: r.top + r.height / 2 };
	const справа = window.innerWidth - r.right;
	const снизу = window.innerHeight - r.bottom;
	const дх = справа > 200 ? 1 : -1;
	const ду = снизу > 160 ? 1 : -1;

	const кончик = {
		x: дх > 0 ? r.right + 6 : r.left - 6,
		y: ду > 0 ? r.bottom + 4 : r.top - 4,
	};
	const начало = { x: кончик.x + дх * 130, y: кончик.y + ду * 95 };

	// Размер SVG задаем инлайновым стилем с !important и в пикселях: атрибуты
	// width/height — презентационные, и правило «svg { ... }» из стилей 1С их
	// перебивает. Тогда холст остается 300x150, а все нарисованное за его
	// границей молча обрезается.
	const ш = window.innerWidth;
	const в = window.innerHeight;

	const слой = document.createElement('div');
	слой.id = '__guide_pointer';
	слой.style.cssText = 'position:fixed;inset:0;z-index:2147483647;pointer-events:none';
	слой.innerHTML =
		'<svg viewBox="0 0 ' + ш + ' ' + в + '" style="position:absolute;left:0;top:0' +
		';width:' + ш + 'px !important;height:' + в + 'px !important">' +
		'<defs><marker id="__guide_head" markerWidth="11" markerHeight="11" refX="9" refY="5.5"' +
		' orient="auto"><path d="M0,0 L11,5.5 L0,11 z" fill="#d8341f"/></marker></defs>' +
		'<line x1="' + начало.x + '" y1="' + начало.y + '" x2="' + кончик.x + '" y2="' + кончик.y + '"' +
		' stroke="#d8341f" stroke-width="3.5" stroke-linecap="round"' +
		' marker-end="url(#__guide_head)"/>' +
		'<g transform="translate(' + (цель.x - 5) + ',' + (цель.y - 3) + ')">' +
		'<path d="M0,0 L0,18 L4.4,13.8 L7.2,20 L10,18.7 L7.2,12.7 L13,12.6 z"' +
		' fill="#ffffff" stroke="#1d1d1f" stroke-width="1.4" stroke-linejoin="round"/>' +
		'</g></svg>';
	document.documentElement.appendChild(слой);
	return true;
}

function убратьУказатель() {
	const слой = document.getElementById('__guide_pointer');
	if (слой) слой.remove();
}

// Необязательный клик: всплывающие подсказки конфигурации появляются
// не всегда, и сценарий не должен из-за них падать.
async function попробоватьКлик(текст) {
	try {
		await clickElement(текст);
		return true;
	} catch (e) {
		return false;
	}
}

// --- сценарий -----------------------------------------------------------

await navigateLink('Справочник.ВнутренниеДокументы');
await снимок(
	'Откройте список документов и найдите нужный договор',
	null,
	'Помощник вызывается из карточки объекта, поэтому начинаем со списка.');

await clickElement('Договор поставки', { dblclick: true });
await попробоватьКлик('Напомнить позже');
await снимок(
	'Откройте карточку договора',
	null,
	'В карточке видны присоединенные файлы — именно из них помощник возьмет данные.');

// Команда помощника живет в подменю «Заполнить» механизма дополнительных
// обработок. Имя подменю конфигурация генерирует с хешем, поэтому ищем
// его по устойчивому началу, а не по полному имени.
const состояниеКарточки = await getFormState();
const подменюЗаполнить = (состояниеКарточки.buttons || [])
	.map(кнопка => (typeof кнопка === 'string' ? кнопка : кнопка.name))
	.find(имя => имя && имя.indexOf('ПодменюЗаполнить') === 0);
if (!подменюЗаполнить) {
	throw new Error('В карточке нет подменю «Заполнить» — обработка помощника не зарегистрирована.');
}

await снимок(
	'Нажмите кнопку вызова помощника',
	подменюЗаполнить,
	'Помощник подключается механизмом дополнительных обработок и появляется в подменю «Заполнить».');
await clickElement(подменюЗаполнить);

await снимок(
	'Выберите действие',
	'Заполнить реквизиты по файлу',
	'Список показывает только действия, настроенные для этого вида документа.'
	+ ' Выбор строки сразу ведет к уточняющим вопросам.');
await clickElement('Заполнить реквизиты по файлу');
await wait(1);

await снимок(
	'Выберите файл и нажмите «Далее»',
	'Далее',
	'Помощник показывает только файлы, подходящие по настроенному отбору.'
	+ ' На последнем уточнении кнопка называется «Запустить анализ».');
await clickElement('Далее');

await wait(6);
await снимок(
	'Дождитесь ответа модели',
	null,
	'Интерфейс не блокируется: рядом с состоянием крутится индикатор и идет счетчик времени.'
	+ ' Обращение к модели выполняется фоновым заданием.');

for (let попытка = 0; попытка < 12; попытка += 1) {
	const состояние = await getFormState();
	const готово = (состояние.fields || []).some(
		f => String(f.value || '').indexOf('Анализ завершен') >= 0);
	if (готово) break;
	await wait(5);
}

await снимок(
	'Проверьте предложенные значения',
	null,
	'Снимите отметку с тех строк, которые применять не нужно. Модель ничего не решает: решение за вами.');

await снимок('Нажмите кнопку действия', 'Выполнить действие');
await clickElement('Выполнить действие');

await снимок(
	'Подтвердите действие',
	'Да',
	'Текст вопроса прямо говорит, будет объект записан или нет.');
await clickElement('Да');

await wait(3);
const послеПодтверждения = await getFormState();
if (послеПодтверждения.confirmation) {
	await снимок(
		'Ответьте на уточняющий вопрос',
		'Да',
		'Действие может быть многошаговым: обработчик вправе спросить и продолжить после ответа.');
	await clickElement('Да');
	await wait(3);
}

await снимок(
	'Готово',
	null,
	'В строке состояния виден итог, а сообщения внизу показывают, что именно сделано.');

// --- сборка HTML --------------------------------------------------------

function экранировать(строка) {
	return String(строка)
		.replace(/&/g, '&amp;')
		.replace(/</g, '&lt;')
		.replace(/>/g, '&gt;')
		.replace(/"/g, '&quot;');
}

const части = [];
части.push('<!DOCTYPE html><html lang="ru"><head><meta charset="utf-8">');
части.push('<title>' + экранировать(ЗАГОЛОВОК) + '</title>');
части.push('<style>' +
	"body{font:15px/1.55 -apple-system,'Segoe UI',Roboto,sans-serif;color:#1d1d1f;" +
	'max-width:1000px;margin:32px auto;padding:0 20px}' +
	'h1{font-size:26px;margin:0 0 4px}' +
	'.meta{color:#6e6e73;font-size:13px;margin:0 0 26px}' +
	'.step{margin:0 0 30px;padding-top:18px;border-top:1px solid #e3e3e6}' +
	'.step h2{font-size:17px;margin:0 0 6px}' +
	'.step h2 span{display:inline-block;min-width:26px;color:#6e6e73;font-weight:400}' +
	'.note{color:#3c3c43;margin:0 0 10px}' +
	'img{width:100%;border:1px solid #d8d8dc;border-radius:6px;display:block}' +
	'</style></head><body>');
части.push('<h1>' + экранировать(ЗАГОЛОВОК) + '</h1>');
части.push('<p class="meta">Снято автоматически из рабочей базы ' +
	экранировать(new Date().toLocaleString('ru-RU')) +
	'. Шагов: ' + шаги.length + '.</p>');

for (const шаг of шаги) {
	части.push('<div class="step">');
	части.push('<h2><span>' + шаг.номер + '.</span> ' + экранировать(шаг.подпись) + '</h2>');
	if (шаг.комментарий) {
		части.push('<p class="note">' + экранировать(шаг.комментарий) + '</p>');
	}
	части.push('<img alt="' + экранировать(шаг.подпись) +
		'" src="data:image/png;base64,' + шаг.данные + '">');
	части.push('</div>');
}
части.push('</body></html>');

writeFileSync(ВЫХОД + '\\index.html', части.join('\n'), 'utf-8');
console.log(JSON.stringify({ шагов: шаги.length, файл: ВЫХОД + '\\index.html' }));
