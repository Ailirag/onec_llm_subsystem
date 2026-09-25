// Обход всех форм подсистемы для ревью интерфейса: списки, карточки (первая
// строка списка или новый элемент), каждая вкладка; обработки, общая форма,
// карточка операции и консоль запросов. Снимки — в .build/ui-review, в лог —
// заголовок формы, вкладки и группы. Сценарий ничего не записывает: новые
// элементы закрываются без сохранения.
//
// Каталог .build/ui-review создайте заранее: песочница сценария умеет только
// писать файлы.
//
//   node run.mjs run http://localhost:8081/<публикация> tests/ui/forms-review.mjs
const КАТАЛОГ = 'H:/1C/xml/LLM_Subsystem_test/.build/ui-review/';
let номер = 0;

async function снимок(имя) {
	await wait(1);
	номер += 1;
	const файл = String(номер).padStart(2, '0') + '-' + имя + '.png';
	writeFileSync(КАТАЛОГ + файл, await screenshot());
	const с = await getFormState();
	const вкладки = (с.tabs || []).map(т => (typeof т === 'string' ? т : (т.name + (т.active ? '*' : ''))));
	const группы = (с.groups || []).map(г => г.title + (г.collapsed ? '(свернута)' : ''));
	console.log(файл + ' | ' + (с.title || '') + ' | вкладки: ' + вкладки.join(', ') + (группы.length ? ' | группы: ' + группы.join(', ') : ''));
}

async function закрытьВсе() {
	await getPage().keyboard.press('Escape').catch(() => {});
	for (let i = 0; i < 10; i++) {
		const открыто = await getFormState();
		if (!открыто.title || открыто.title === 'Начальная страница' || !открыто.formCount) return;
		try { await closeForm({ save: false }); } catch (e) { return; }
		await wait(1);
	}
}

async function вкладки() {
	const с = await getFormState();
	return (с.tabs || []).map(т => (typeof т === 'string' ? т : т.name));
}

async function всеВкладки(префикс) {
	const список = await вкладки();
	if (!список.length) { await снимок(префикс); return; }
	for (const вкладка of список) {
		try {
			await clickElement(вкладка);
			await wait(1);
			await снимок(префикс + '-' + вкладка.replace(/[^\wа-яА-ЯёЁ]+/g, '_'));
		} catch (e) {
			console.log('  вкладка не открылась: ' + вкладка + ': ' + e.message.split('\n')[0]);
		}
	}
}

async function открытьПервый() {
	const с = await getFormState();
	if (!с.tables || !с.tables.length || !с.tables[0].rowCount) return false;
	const т = await readTable({ maxRows: 1 });
	if (!т.rows || !т.rows.length) return false;
	const значение = Object.values(т.rows[0]).find(з => з && String(з).trim().length > 1);
	if (!значение) return false;
	await clickElement(String(значение), { dblclick: true });
	await wait(3);
	const после = await getFormState();
	return после.formCount > с.formCount || после.title !== с.title || (после.buttons || []).some(к => String(к.name || '').indexOf('Записать и закрыть') >= 0);
}

await getPage().setViewportSize({ width: 1366, height: 900 });
await wait(2);

const справочники = [
	['providers', 'Справочник.AI_Провайдеры'],
	['models', 'Справочник.AI_Модели'],
	['agents', 'Справочник.AI_Агенты'],
	['scenarios', 'Справочник.AI_Сценарии'],
	['places', 'Справочник.AI_МестаЗапускаСценариев'],
	['context', 'Справочник.AI_ДополнительныйКонтекст'],
	['maps', 'Справочник.AI_КартыИзвлечения'],
	['access', 'Справочник.AI_ПрофилиДоступаКДанным'],
	['groups', 'Справочник.AI_ГруппыПользователей'],
	['mcp-servers', 'Справочник.AI_MCPСерверы'],
	['mcp-tools', 'Справочник.AI_MCPИнструменты'],
	['mcp-profiles', 'Справочник.AI_ПрофилиMCP'],
	['rag-collections', 'Справочник.AI_RAGКоллекции'],
	['rag', 'Справочник.AI_RAG'],
	['rag-permissions', 'Справочник.AI_RAGВидыРазрешений'],
	['journal', 'РегистрСведений.AI_ЖурналЗапросов']
];

for (const [код, ссылка] of справочники) {
	try {
		await getPage().setViewportSize({ width: 1366, height: ['places', 'agents', 'providers'].includes(код) ? 1150 : 900 });
		await закрытьВсе();
		await navigateLink(ссылка);
		await wait(3);
		await снимок(код + '-list');
		if (await открытьПервый()) {
			await всеВкладки(код + '-item');
		} else {
			try {
				await clickElement('Создать');
				await wait(3);
				await всеВкладки(код + '-new');
			} catch (e) {
				console.log('  создать не удалось: ' + код + ': ' + e.message.split('\n')[0]);
			}
		}
	} catch (e) {
		console.log('ОШИБКА ' + код + ': ' + e.message.split('\n')[0]);
	}
}

// Профиль доступа: подбор метаданных.
try {
	await закрытьВсе();
	await navigateLink('Справочник.AI_ПрофилиДоступаКДанным');
	await wait(3);
	if (await открытьПервый()) {
		await clickElement('Подобрать объекты');
		await wait(4);
		await снимок('access-pick');
	}
} catch (e) { console.log('ОШИБКА подбор: ' + e.message.split('\n')[0]); }

// Обработки и общая форма.
const обработки = [
	['settings', 'e1cib/app/ОбщаяФорма.AI_НастройкиПодсистемы'],
	['monitor', 'Обработка.AI_МониторАгентскихОпераций'],
	['sandbox', 'Обработка.AI_Песочница'],
	['chat', 'Обработка.AI_ЧатПоДаннымБазы'],
	['wizard', 'Обработка.AI_НовоеДействие'],
	['assistant', 'Обработка.AI_ПомощникКонтекста']
];
for (const [код, ссылка] of обработки) {
	try {
		await закрытьВсе();
		await navigateLink(ссылка);
		await wait(4);
		await всеВкладки(код);
	} catch (e) {
		console.log('ОШИБКА ' + код + ': ' + e.message.split('\n')[0]);
	}
}

// Карточка операции из монитора.
try {
	await закрытьВсе();
	await navigateLink('Обработка.AI_МониторАгентскихОпераций');
	await wait(4);
	await clickElement('Открыть операцию');
	await wait(4);
	await всеВкладки('operation');
} catch (e) { console.log('ОШИБКА операция: ' + e.message.split('\n')[0]); }

// Консоль запросов из чата.
try {
	await закрытьВсе();
	await navigateLink('Обработка.AI_ЧатПоДаннымБазы');
	await wait(4);
	const р = await clickElement('Еще');
	if (р.submenu) console.log('  Еще чата: ' + р.submenu.join(', '));
	await clickElement('Консоль запросов');
	await wait(5);
	await всеВкладки('console');
} catch (e) { console.log('ОШИБКА консоль: ' + e.message.split('\n')[0]); }

await закрытьВсе();
