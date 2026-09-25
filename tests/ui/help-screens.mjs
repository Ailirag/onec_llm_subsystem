// Снимки экранов для встроенной справки подсистемы (F1).
//
// Сценарий ходит в стенд Документооборота и снимает формы в том виде, в каком
// их видит администратор. Снимки кладутся в .build/help, а в страницы справки
// их встраивает tools/Update-HelpPages.ps1: картинки из папки _files справки
// расширения веб-клиент не отдает, поэтому они встраиваются в саму страницу.
//
// Ссылки на элементы — стенда; для другой базы поменяйте их ниже. Прежде чем
// встраивать снимок, посмотрите его: в кадр не должны попасть адреса моделей с
// идентификатором каталога, ключи и данные компаний.
//
//   node run.mjs run http://localhost:8081/do21 tests/ui/help-screens.mjs

const КАТАЛОГ = 'H:/1C/xml/LLM_Subsystem_test/.build/help/';
const МЕСТО_МАРШРУТА = 'e1cib/data/Справочник.AI_МестаЗапускаСценариев?ref=88608c688ba1745611f1b809a0ebe8e6';
const МЕСТО_С_ОБРАБОТКОЙ = 'e1cib/data/Справочник.AI_МестаЗапускаСценариев?ref=88608c688ba1745611f1b82d79a69f3a';
const КАРТА_МАРШРУТА = 'e1cib/data/Справочник.AI_КартыИзвлечения?ref=88608c688ba1745611f1b809a0ebe8e4';

// Каталог .build/help создайте заранее: песочница сценария умеет только писать файлы.

async function снимок(имя) {
	// Курсор — на пустое место заголовка: иначе в кадр попадет всплывающая подсказка.
	await getPage().mouse.move(1300, 60);
	await wait(1);
	writeFileSync(КАТАЛОГ + имя + '.png', await screenshot());
	console.log('снято: ' + имя);
}

async function закрытьВсе() {
	for (let i = 0; i < 8; i++) {
		const открыто = await getFormState();
		if (!открыто.title || открыто.title === 'Начальная страница') {
			return;
		}
		try { await closeForm({ save: false }); } catch (e) { return; }
		await wait(1);
	}
}

await getPage().setViewportSize({ width: 1366, height: 900 });
await wait(2);
await закрытьВсе();

// Раздел LLM: из чего состоит подсистема. Через главное меню, а не через
// панель разделов: в Документообороте она бывает в режиме «только картинки».
// Координаты — стенда: кнопка меню слева вверху, «LLM» — последний раздел.
await getPage().mouse.click(60, 15);
await wait(2);
await getPage().mouse.click(1070, 75);
await wait(3);
await снимок('llm-section');
await getPage().keyboard.press('Escape');
await wait(1);

// AI-помощник раздела: действия без объекта. Окно выше обычного, чтобы в кадр
// вошла нижняя строка со ссылкой на справку.
await getPage().setViewportSize({ width: 1366, height: 980 });
await navigateLink('Обработка.AI_ПомощникКонтекста');
await wait(3);
await снимок('assistant-actions');
await закрытьВсе();
await getPage().setViewportSize({ width: 1366, height: 900 });
await wait(2);

// Место запуска: основные настройки и «Кому показывать».
await navigateLink(МЕСТО_МАРШРУТА);
await wait(3);
await снимок('place-main');
await clickElement('Кому показывать');
await wait(1);
await снимок('place-visibility');
await закрытьВсе();

// Место, где файл подает обработка: поля обработки и этапов.
await navigateLink(МЕСТО_С_ОБРАБОТКОЙ);
await wait(3);
await снимок('place-stages');
await закрытьВсе();

// Карта извлечения: поля и подсказки модели.
await navigateLink(КАРТА_МАРШРУТА);
await wait(3);
await снимок('map-main');
await закрытьВсе();

// Настройки подсистемы: адаптер конфигурации.
await navigateLink('e1cib/app/ОбщаяФорма.AI_НастройкиПодсистемы');
await wait(3);
await getPage().mouse.move(600, 500);
await getPage().mouse.wheel(0, 2000);
await wait(1);
await снимок('settings-adapter');
await закрытьВсе();

// Монитор операций: список операций.
await navigateLink('Обработка.AI_МониторАгентскихОпераций');
await wait(4);
await снимок('monitor-list');
await закрытьВсе();

// MCP-сервер: новая карточка с кнопками проверки и загрузки инструментов.
// Новая, а не существующая: в кадр не попадет адрес чужого сервера.
await navigateLink('Справочник.AI_MCPСерверы');
await wait(3);
await clickElement('Создать');
await wait(3);
await снимок('mcp-server');
await закрытьВсе();

// Мастер «Новое AI-действие»: первый шаг и выбор полей. Действие не создается.
// Объект подбирается вводом: подбор веб-клиент запускает по нажатию клавиши,
// поэтому вставляется все, кроме последнего символа, а он допечатывается.
const ОБЪЕКТ_МАСТЕРА = 'Шаблоны согласования (справочник)';
await navigateLink('Обработка.AI_НовоеДействие');
await wait(3);
await clickElement('Объект');
await wait(1);
await getPage().locator('input:focus, textarea:focus').first().fill(ОБЪЕКТ_МАСТЕРА.slice(0, -1));
await getPage().keyboard.type(ОБЪЕКТ_МАСТЕРА.slice(-1));
try {
	const пункт = getPage().locator('.eddText:visible', { hasText: ОБЪЕКТ_МАСТЕРА }).first();
	await пункт.waitFor({ state: 'visible', timeout: 8000 });
	await пункт.click();
} catch (e) {
	await getPage().keyboard.press('Tab');
}
await wait(3);
await fillFields({ 'Где показывать': 'В AI-помощнике раздела LLM' });
await wait(2);
await fillFields({ 'Название действия': 'Собрать маршрут согласования' });
await wait(1);
await снимок('wizard-object');
await clickElement('Далее >');
await wait(2);
await fillFields({ 'Сначала поговорить': 'true' });
await wait(2);
await clickElement('Далее >');
await wait(3);
for (const реквизит of ['Наименование', 'Вариант согласования', 'Лист согласования: Исполнитель',
	'Лист согласования: Порядок согласования', 'Лист согласования: Срок исполнения дни']) {
	await fillTableRow({ 'Извлекать': 'true' }, { table: 'Реквизиты', row: { 'Реквизит': реквизит }, scroll: true });
}
await снимок('wizard-result');
await закрытьВсе();

// Снимки assistant-dialog и assistant-result (разговор с моделью и его итог)
// сценарий не снимает: для них нужен настоящий ответ модели. Их снимают
// вручную в действии «Собрать маршрут согласования» AI-помощника.
