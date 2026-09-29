const standUrl = process.env.ONEC_WEB_UI_URL;
const llmUserStandUrl = process.env.ONEC_WEB_UI_URL_LLM_USER;

if (!standUrl || !llmUserStandUrl) {
  throw new Error(
    'URL публикаций Web UI не заданы. Запускайте suite через tools/Invoke-WebUiTests.ps1.',
  );
}

function contextUrl(baseUrl, user) {
  const localizedUrl = `${baseUrl.replace(/\/+$/, '')}/ru_RU/`;
  const separator = localizedUrl.includes('?') ? '&' : '?';
  return `${localizedUrl}${separator}N=${encodeURIComponent(user)}&P=`;
}

export default {
  contexts: {
    administrator: {
      url: contextUrl(standUrl, 'Администратор'),
      displayName: 'Администратор стенда',
    },
    llmUser: {
      url: contextUrl(llmUserStandUrl, 'Тест MCP Пользователь'),
      displayName: 'Пользователь LLM без прав администратора MCP',
    },
  },
  defaultContext: 'administrator',
  // Разные пользователи 1С не могут жить в соседних вкладках: tab делит cookie
  // веб-клиента, и второй URL с N/P продолжает административный сеанс.
  isolation: 'window',
  maxContexts: 1,
  // Ролевые проверки должны запускаться в независимых браузерных сеансах.
  // При reuse cookie уже открытого администратора может победить параметры
  // N/P в URL второго контекста, и ограниченный сценарий ложно исполнится под
  // Администратором. strict закрывает контекст после теста, а отсутствие
  // pinned-контекстов не удерживает административный сеанс между проверками.
  contextPolicy: 'strict',
  pinnedContexts: [],
  displayName: 'LLM-подсистема',
  timeout: Number(process.env.ONEC_UI_COMMAND_TIMEOUT_MS || 360000),
  retries: 0,
  screenshot: 'on-failure',
  record: false,
  preserveClipboard: true,
  severity: {
    critical: ['smoke', 'access'],
  },
  defaultSeverity: 'normal',
};
