// Механика сборки инструкций: снимок шага с указателем и сборка HTML.
//
// Этот файл подставляется перед текстом сценария скриптом tools\Build-UserGuide.ps1,
// поэтому сценарий содержит только шаги. Имя начинается с подчеркивания — по
// нему скрипт отличает библиотеку от сценариев.
//
// Исполняется как часть тела async-функции: импортов здесь быть не может,
// функции раннера доступны глобально, каталог вывода лежит в ВЫХОД.

const шаги = [];
let номерШага = 0;

// Снимает шаг инструкции.
//
//   подпись     — что делает человек: заголовок шага;
//   цель        — текст или имя элемента для подсветки (как в clickElement);
//                 без нее шаг снимается без указателя;
//   комментарий — зачем это нужно. Пишите сюда то, чего на снимке не видно.
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

// Выполняется в браузере: ищет рамку подсветки и дорисовывает к ней стрелку и
// курсор. Стрелка заходит с той стороны, где больше места, чтобы не перекрывать
// сам элемент.
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
	// Слой висит на documentElement: так он рисуется поверх модальных окон 1С,
	// а pointer-events:none оставляет клик следующего шага настоящему элементу.
	document.documentElement.appendChild(слой);
	return true;
}

function убратьУказатель() {
	const слой = document.getElementById('__guide_pointer');
	if (слой) слой.remove();
}

// Необязательный клик: всплывающие подсказки конфигурации появляются не всегда,
// и сценарий не должен из-за них падать.
async function попробоватьКлик(текст) {
	try {
		await clickElement(текст);
		return true;
	} catch (e) {
		return false;
	}
}

// Кнопка действия называется по виду действия: «Заполнить форму», «Записать в
// объект», «Выполнить действие». Ищем ее среди кнопок мастера.
async function кнопкаДействияМастера() {
	const служебные = ['Еще', '< Назад', 'Далее >', 'Далее', 'Открыть диалог', 'Закрыть',
		'Выгрузить пакет', 'Загрузить пакет', 'Открыть результат', 'Записать объект'];
	const состояние = await getFormState();
	return (состояние.buttons || [])
		.map(к => (typeof к === 'string' ? к : к.name))
		.filter(и => и && служебные.indexOf(и) < 0 && и.indexOf('Подменю') < 0)
		.find(и => /Заполнить|Записать|Выполнить/i.test(и));
}

function экранировать(строка) {
	return String(строка)
		.replace(/&/g, '&amp;')
		.replace(/</g, '&lt;')
		.replace(/>/g, '&gt;')
		.replace(/"/g, '&quot;');
}

// Собирает index.html. Файл самодостаточный: стили внутри, картинки вставлены
// как data:-URI. Инструкцию пересылают почтой и кладут на портал, и внешняя
// ссылка на картинку превратила бы ее в набор битых рамок на второй неделе.
function сохранитьИнструкцию(заголовок) {
	if (шаги.length === 0) {
		throw new Error('Инструкция пуста: сценарий не сделал ни одного снимка.');
	}
	const части = [];
	части.push('<!DOCTYPE html><html lang="ru"><head><meta charset="utf-8">');
	части.push('<title>' + экранировать(заголовок) + '</title>');
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
		'@media (prefers-color-scheme:dark){body{background:#1d1d1f;color:#f5f5f7}' +
		'.step{border-color:#3a3a3c}.note{color:#d1d1d6}.meta{color:#98989d}' +
		'img{border-color:#3a3a3c}}' +
		'</style></head><body>');
	части.push('<h1>' + экранировать(заголовок) + '</h1>');
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
}
