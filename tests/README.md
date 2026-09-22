# Functional test environment

The local functional test environment is deliberately separate from production
metadata and from a developer's working infobase.

It contains:

- a persistent file infobase built from the minimal host configuration in `cf`
  and the embedded LLM subsystem;
- 37 deterministic counterparties with `AT*` codes;
- a mock OpenAI-compatible provider, three models, an agent, and a data-access
  profile;
- a local HTTP mock for Models, Responses, Chat Completions, Files API, tool
  calls, token usage, and HTTP error handling;
- a test-only common module in the minimal host configuration, invoked through
  `V83.COMConnector` without opening the 1C UI;
- checks for metadata discovery, safe queries, restricted fields, model loading,
  both API protocols, attachments, agent tool execution, conversation
  isolation, and token logging.

## Initialize or update

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File tools\Initialize-FunctionalTestEnvironment.ps1 `
  -BasePath H:\1C\Base1C\LLM_Subsystem_Autotest `
  -V8Path "C:\Program Files\1cv8\8.3.27.2130\bin"
```

The default base is stored under
`%LOCALAPPDATA%\Ailirag\onec_llm_subsystem\functional-test-base`. Use
`-BasePath` to keep it elsewhere. Re-running the command updates the
configuration and fixtures in place. `-Recreate` removes only the explicitly
resolved test base and creates it again.

## Run

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File tools\Invoke-FunctionalSmokeTests.ps1 `
  -BasePath H:\1C\Base1C\LLM_Subsystem_Autotest
```

The initialization script auto-detects the newest installed 1C platform. Use
`-V8Path` to pin a specific platform. The smoke runner uses the registered
`V83.COMConnector`. Generated merged XML, logs, and machine-readable test
results live in `.build\functional-tests` and are excluded from Git.

The smoke command exits with an error when a test fails. A successful run checks
that the mock model returns an answer and validates the token totals written to
`AI_ЖурналЗапросов`.

## UI smoke

Publish the test base as `llm-functional-test` on port `8081` with the
`cc-1c-skills` `web-publish` skill, then run:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass `
  -File tools\Invoke-FunctionalUiSmokeTests.ps1
```

This scenario opens the provider, model, and agent lists and verifies the
sandbox and chat forms. It also opens the scheduled-jobs console, its schedule
form, and the host universal data processor. The chat check includes its HTML
document, attachment button, send button, and ready state. The script locates
the newest installed `cc-1c-skills` web-test runner.

The local `.v8-project.json` entry is also generated and ignored by Git. Its
database id and alias are `llm-functional-test` and `llm-test`.
# Проверки публичного ядра

После подготовки тестовой базы:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools/Invoke-CoreFunctionalTest.ps1 -BasePath '<test-base>'
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tools/Invoke-CoreFunctionalTest.ps1 -BasePath '<test-base>' -Background
```

Первый режим проверяет API и переходы очереди с прямым вызовом рабочего метода
в COM-соединении. Второй открывает собственный тестовый клиент 1С и проверяет
настоящее фоновое выполнение через модуль тестовой конфигурации. Режимы нельзя
запускать одновременно на одной базе: тесты используют общие лимиты очереди.
Путь к платформе задается параметром `-V8Path`; таймаут задается
`-TimeoutSeconds`. Рабочие базы этими сценариями не проверяются.
