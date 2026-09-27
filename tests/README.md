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
- in the same mock, an OpenAI-compatible embeddings endpoint (`/v1/embeddings`)
  and a Qdrant REST subset under `/qdrant` (collections, upsert, filtered
  search, point delete and lookup). Keys are checked strictly
  (`mock-emb-key`, `mock-qdrant-key`); vectors are built from the marker words
  ALPHA, BETA and GAMMA, so similarity is predictable; `RAG_SLOW` in the text
  delays the embedding response by six seconds;
- a test-only common module in the minimal host configuration, invoked through
  `V83.COMConnector` without opening the 1C UI;
- a periodic `ТестовыеЦены` register for virtual-table query checks;
- checks for metadata discovery, safe queries, restricted fields (including
  `*`, fields without a table name, table aliases, references, conditions,
  nested queries and virtual tables), model loading,
  both API protocols, attachments, agent tool execution, conversation
  isolation, and token logging;
- RAG checks (`rag_*`): a collection is created in Qdrant and filled through
  the vectorization queue; an agent's question finds the allowed fragment and
  the model request carries it in both API protocols, while a fragment closed
  by an access label and an unchecked collection stay out; sandbox collection
  settings, service errors, the embedding timeout, and removal of stale
  fragments. The RAG checks run after the token journal check because their
  model calls are journaled too.

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

## Сценарии инструкций

`ui/guides` — сценарии для сборки пользовательских инструкций. Это не тесты:
они запускаются вручную этапом `tools\Build-UserGuide.ps1`, ходят в живую базу
и обращаются к модели. Раннер тот же, что у UI-смоука. Подробности — в
[Инструкции для пользователей](../docs/user-guides.md).

## Сценарии интерфейса вне смоука

`ui/wait-for-write.mjs`, `ui/batch-queue.mjs` и `ui/action-chain.mjs` проверяют
ожидание записи объекта, массовый режим и цепочку действий. Они ходят в живую
базу и обращаются к модели, поэтому в обычный прогон UI-смоука не входят и
запускаются руками:

```powershell
node <раннер cc-1c-skills>\run.mjs run http://localhost:8081/<база> tests\ui\<сценарий>.mjs
```

Ход прогона пишется в `.build\<сценарий>.log`: вывод раннера возвращается одним
куском в самом конце, и при зависании по нему ничего не видно.

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

# Снимки для встроенной справки

`tests/ui/help-screens.mjs` снимает формы подсистемы для справки (F1) в
`.build/help`; `tools/Update-HelpPages.ps1` встраивает их в страницы справки
расширения. Сценарий идет в базу с настроенными действиями — ссылки на места
запуска и карту в его начале указывают на стенд Документооборота, для другой
базы их нужно поменять. Каталог `.build/help` создайте заранее. Перед
встраиванием просмотрите снимки: в кадр не должны попасть адреса моделей с
идентификатором каталога, ключи и данные компаний.

`tests/ui/help-check.mjs` проверяет справку в любой базе с расширением: F1 в
каждой форме открывает нужную страницу, картинки загружены, все ссылки между
страницами открываются, включая обзор подсистемы. При ошибках сценарий
завершается с ошибкой.

`tests/ui/forms-review.mjs` обходит все формы подсистемы и снимает каждую
вкладку в `.build/ui-review` (каталог создайте заранее) — для ревью
интерфейса после правки форм. Как писать справку и подсказки —
[docs/help-authoring.md](../docs/help-authoring.md).
