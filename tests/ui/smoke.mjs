function assert(condition, message) {
  if (!condition) {
    throw new Error(message);
  }
}

async function openLlmSection() {
  let section;
  for (let attempt = 0; attempt < 4; attempt += 1) {
    section = await navigateSection('LLM');
    if ((section.commands || []).flat().length > 0) {
      return section;
    }
    await new Promise(resolve => setTimeout(resolve, 750));
  }
  throw new Error(`LLM section has no commands: ${JSON.stringify(section)}`);
}

async function openList(command) {
  await openLlmSection();
  const state = await openCommand(command);
  assert(!state.errorModal, `${command}: ${state.errorModal}`);
  assert(state.table?.present, `${command}: list table is missing`);
  const table = await readTable({ maxRows: 10 });
  await closeForm({ save: false });
  return table;
}

const providers = await openList('Провайдеры');
assert(
  providers.rows.some(row => row['Код'] === 'ATPROV001'
    && row['Наименование'] === 'Mock LLM Autotest'),
  'Mock provider is missing from the provider list'
);

const models = await openList('Модели');
const modelNames = new Set(models.rows.map(row => row['Наименование']));
for (const expected of ['mock-agent', 'mock-chat', 'mock-responses']) {
  assert(modelNames.has(expected), `Model ${expected} is missing from the model list`);
}

const agents = await openList('Агенты');
assert(
  agents.rows.some(row => row['Код'] === 'ATAGENT01'
    && row['Агентский режим'] === 'true'),
  'Autotest agent is missing or agent mode is disabled'
);

await openLlmSection();
const sandbox = await openCommand('Песочница');
assert(!sandbox.errorModal, `Sandbox form error: ${sandbox.errorModal}`);
assert(sandbox.title === 'Песочница', 'Unexpected sandbox form title');
assert(
  sandbox.buttons.some(button => button.name === 'Отправить'),
  'Sandbox send button is missing'
);
await closeForm({ save: false });

await openLlmSection();
const contextAssistant = await openCommand('AI-помощник');
assert(!contextAssistant.errorModal,
  `Context assistant form error: ${contextAssistant.errorModal}`);
assert(contextAssistant.title === 'AI-помощник',
  'Unexpected context assistant form title');
assert(contextAssistant.tables?.some(table => table.name === 'Сценарии'),
  'Context assistant scenarios table is missing');
assert(contextAssistant.buttons.some(button => button.name === 'Открыть диалог'),
  'Context assistant open-dialog button is missing');
await closeForm({ save: false });

await openLlmSection();
const chat = await openCommand('Чат по данным базы');
assert(!chat.errorModal, `Chat form error: ${chat.errorModal}`);
assert(chat.title === 'Диалог с агентом по данным базы', 'Unexpected chat form title');
assert(chat.iframes === 1, 'Chat HTML document was not rendered');
assert(
  chat.buttons.some(button => button.name === 'ПрикрепитьФайлы'),
  'Attachment button is missing'
);
assert(
  chat.buttons.some(button => button.name === 'Отправить'),
  'Send button is missing'
);
assert(
  chat.texts?.some(text => text.name === 'СтатусОперации'
    && text.value === 'Готов к диалогу'),
  'Chat form is not ready'
);
await closeForm({ save: false });

await openLlmSection();
const monitor = await openCommand('Монитор агентских операций');
assert(!monitor.errorModal, `Operations monitor error: ${monitor.errorModal}`);
assert(monitor.title === 'Монитор агентских операций', 'Unexpected operations monitor title');
assert(monitor.tables?.some(table => table.name === 'СписокОпераций'),
  'Operations monitor table is missing');
assert(monitor.buttons.some(button => button.name === 'Сохранить оценку'),
  'Operations feedback button is missing');
// Кликать по кнопке нельзя: на заполненном списке оценка упирается в правило
// "оценить можно только сохраненный успешный результат", и тест стал бы
// зависеть от порядка запуска. Проверяем, что форма оценки собрана целиком.
for (const field of ['Решение', 'Комментарий', 'ИсправленныйОтвет']) {
  assert(monitor.fields?.some(item => item.name === field),
    `Operations feedback field ${field} is missing`);
}
await closeForm({ save: false });

let hostSection;
for (let attempt = 0; attempt < 4; attempt += 1) {
  hostSection = await navigateSection('Основная');
  if ((hostSection.commands || []).flat().length > 0) {
    break;
  }
  await new Promise(resolve => setTimeout(resolve, 750));
}
assert((hostSection.commands || []).flat().length > 0, 'Host section has no commands');

const jobs = await openCommand('Консоль заданий');
assert(!jobs.errorModal, `Scheduled jobs console error: ${jobs.errorModal}`);
assert(jobs.title === 'Регламентные и фоновые задания', 'Unexpected jobs console title');
assert(jobs.tables?.some(table => table.name === 'СписокРегламентныхЗаданий'),
  'Scheduled jobs table is missing');
await clickElement('СписокРегламентныхЗаданийРасписание1');
const schedule = await getFormState();
assert(!schedule.errorModal, `Schedule form error: ${schedule.errorModal}`);
assert(schedule.title === 'Расписание', 'Schedule form did not open');
await closeForm({ save: false });
await closeForm({ save: false });

for (let attempt = 0; attempt < 4; attempt += 1) {
  hostSection = await navigateSection('Основная');
  if ((hostSection.commands || []).flat().length > 0) {
    break;
  }
  await new Promise(resolve => setTimeout(resolve, 750));
}
const universal = await openCommand('Универсальная обработка');
assert(!universal.errorModal, `Universal data processor error: ${universal.errorModal}`);
assert(universal.title, 'Universal data processor did not open');
await closeForm({ save: false });

console.log(JSON.stringify({
  providers: providers.total,
  models: models.total,
  agents: agents.total,
  sandbox: 'ready',
  contextAssistant: 'ready',
  chat: 'ready',
  monitor: 'ready',
  schedule: 'ready',
  universal: 'ready'
}));
