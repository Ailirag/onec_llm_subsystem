// Доступ теста к данным стенда: исполнитель кода стенда и стандартный OData.
//
// Тест Web UI проверяет то, что видно в интерфейсе. Подготовить данные под
// сценарий и проверить, что стало в базе после действия, быстрее и надёжнее
// не кликами, а напрямую — отсюда. Правило, когда что брать, —
// docs/rules/testing.md.
//
// Адрес стенда берётся из ONEC_WEB_UI_URL: его выставляет tools/Invoke-WebUiTests.ps1
// (имя переменной — webUiTests.urlEnvironmentVariable). Вход — под администратором
// стенда: он есть на любом стенде комплекта, без пароля
// (Get-WorkflowStandAdministrator в scripts/workflow/Workflow.Common.ps1 — источник
// этих значений; шаг gate комплекта сверяет их с этим файлом).

const STAND_USER = 'Администратор';
const STAND_PASSWORD = '';

function standUrl(options = {}) {
  const base = options.baseUrl ?? process.env.ONEC_WEB_UI_URL;
  if (!base) {
    throw new Error('Адрес стенда неизвестен: ONEC_WEB_UI_URL не задан. Тест запущен не через tools/Invoke-WebUiTests.ps1?');
  }
  return base.replace(/\/+$/, '');
}

function authorization(options = {}) {
  const user = options.user ?? STAND_USER;
  const password = options.password ?? STAND_PASSWORD;
  return 'Basic ' + Buffer.from(`${user}:${password}`, 'utf8').toString('base64');
}

// Причина, по которой исполнитель не ответил JSON: тест падает с ней в setup, и
// разбор начинается с настройки стенда, а не с кода приложения.
function unavailableReason(status) {
  switch (status) {
    case 404:
      return 'исполнитель не опубликован на стенде: standExec.enabled выключен или стенд собран до его включения (пересобрать: -RebuildStand).';
    case 401:
      return 'вход отклонён: на стенде нет администратора стенда или база без пользователей.';
    case 403:
      return 'нет права на HTTP-сервис расширения: нужна роль с «Устанавливать права для новых объектов» (в БСП — ПолныеПрава).';
    default:
      return 'стенд ответил не так, как отвечает исполнитель.';
  }
}

async function request(url, init, options) {
  const response = await fetch(url, {
    ...init,
    headers: { Authorization: authorization(options), ...(init.headers ?? {}) },
  });
  const text = await response.text();
  return { status: response.status, text };
}

// Выполняет код BSL на стенде. Код получает переменную Параметры и кладёт ответ в
// переменную Результат — любое значение: ссылки приходят объектами
// { _type, _ref, _presentation }, таблицы значений — массивами строк.
//
// Режимы: 'commit' — одна транзакция, при ошибке не записано ничего (по
// умолчанию); 'rollback' — выполнить и откатить: проверка, не оставляющая следов;
// 'none' — без транзакции исполнителя.
//
// Возвращает значение Результат. При ошибке кода бросает исключение с текстом
// ошибки, сообщениями пользователю и стеком — в отчёте теста видна причина.
export async function standExec(code, { params = {}, mode = 'commit', ...options } = {}) {
  const { status, text } = await request(`${standUrl(options)}/hs/stand-exec/run`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json; charset=utf-8' },
    body: JSON.stringify({ code, params, mode }),
  }, options);
  let answer;
  try {
    answer = JSON.parse(text);
  }
  catch {
    throw new Error(`Исполнитель кода стенда ответил ${status}: ${unavailableReason(status)} ${text.slice(0, 300)}`);
  }
  if (status !== 200 || !answer.ok) {
    const messages = (answer.messages ?? []).length > 0 ? `\nСообщения: ${answer.messages.join(' | ')}` : '';
    const details = answer.details ? `\n${answer.details}` : '';
    throw new Error(`Исполнитель кода стенда (${status}): ${answer.error ?? text}${messages}${details}`);
  }
  return answer.result;
}

// Запрос к стандартному OData стенда. path — после standard.odata/, например
// "Catalog_Номенклатура?$filter=Description eq 'Товар'". Возвращает разобранный
// JSON; для коллекции — массив из value. Бросает исключение на ответ не 2xx.
export async function odata(path, { method = 'GET', body, ...options } = {}) {
  const separator = path.includes('?') ? '&' : '?';
  const url = `${standUrl(options)}/odata/standard.odata/${encodeURI(path)}` +
    (method === 'GET' && !path.includes('$format') ? `${separator}$format=json` : '');
  const { status, text } = await request(url, {
    method,
    headers: { Accept: 'application/json', 'Content-Type': 'application/json; charset=utf-8' },
    body: body === undefined ? undefined : JSON.stringify(body),
  }, options);
  if (status < 200 || status >= 300) {
    throw new Error(`OData ${method} ${path} (${status}): ${text.slice(0, 500)}`);
  }
  if (!text) {
    return undefined;
  }
  const parsed = JSON.parse(text);
  return Array.isArray(parsed.value) ? parsed.value : parsed;
}

// Что доступно на стенде. Не бросает исключений. Для диагностики и инструментов:
// пропускать тест по недоступности НЕЛЬЗЯ — пропущенная проверка не выполняется
// никогда (docs/rules/testing.md). Тест, которому нужен исполнитель, падает с
// причиной из standExec.
export async function standCapabilities(options = {}) {
  const result = { exec: false, odata: false, reason: '' };
  let base;
  try {
    base = standUrl(options);
  }
  catch (error) {
    result.reason = error.message;
    return result;
  }
  try {
    const ping = await request(`${base}/hs/stand-exec/ping`, { method: 'GET' }, options);
    const state = ping.status === 200 ? JSON.parse(ping.text) : null;
    result.exec = Boolean(state && state.ok && state.armed && state.admin);
    if (!result.exec) {
      result.reason = ping.status === 200
        ? 'исполнитель отвечает, но метки стенда нет или вход не под администратором'
        : unavailableReason(ping.status);
    }
  }
  catch (error) {
    result.reason = `стенд не отвечает: ${error.message}`;
  }
  try {
    const metadata = await request(`${base}/odata/standard.odata/$metadata`, { method: 'GET' }, options);
    result.odata = metadata.status === 200 && metadata.text.includes('<EntitySet ');
  }
  catch {
    result.odata = false;
  }
  return result;
}
