import fs from 'node:fs';

export const name = 'Секреты MCP доступны только администратору MCP';
export const tags = ['access', 'mcp'];
export const severity = 'critical';
export const contexts = ['llmUser'];
export const timeout = Number(process.env.ONEC_UI_COMMAND_TIMEOUT_MS || 360000);

function objectRights(xml, objectName) {
  const escaped = objectName.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const match = xml.match(new RegExp(
    `<object>\\s*<name>${escaped}</name>([\\s\\S]*?)</object>`,
  ));
  if (!match) return new Set();

  return new Set(
    [...match[1].matchAll(
      /<right>\s*<name>([^<]+)<\/name>\s*<value>true<\/value>\s*<\/right>/g,
    )].map(item => item[1]),
  );
}

function rightsFor(role) {
  const rightsUrl = new URL(
    `../../../cfe llm/Roles/${role}/Ext/Rights.xml`,
    import.meta.url,
  );
  return objectRights(
    fs.readFileSync(rightsUrl, 'utf8'),
    'InformationRegister.AI_СекретыMCP',
  );
}

function hostLaunchRights() {
  const rightsUrl = new URL(
    '../../../cf/Roles/ЗапускКлиентовLLM/Ext/Rights.xml',
    import.meta.url,
  );
  return objectRights(
    fs.readFileSync(rightsUrl, 'utf8'),
    'Configuration.Конфигурация',
  );
}

export default async function(ctx) {
  const { llmUser, assert, step } = ctx;

  await step('Прикладные роли не читают регистр секретов', async () => {
    for (const role of ['AI_ПользовательLLM', 'AI_АнализДанныхАгентом']) {
      assert.equal(rightsFor(role).size, 0, `${role}: найден прямой доступ к секретам MCP`);
    }
  });

  await step('Роль запуска не расширяет прикладные права', async () => {
    const rights = hostLaunchRights();
    assert.deepEqual(
      [...rights].sort(),
      ['ThinClient', 'WebClient'],
      `ЗапускКлиентовLLM должна содержать только права запуска клиентов: ${[...rights].join(', ')}`,
    );
  });

  await step('Администратор MCP управляет секретами', async () => {
    const rights = rightsFor('AI_АдминистраторMCP');
    // У регистра сведений нет отдельных прав Insert/Delete:
    // запись и удаление его записей покрывает Update.
    for (const right of ['Read', 'Update', 'View', 'Edit']) {
      assert.ok(rights.has(right), `AI_АдминистраторMCP: отсутствует право ${right}`);
    }
  });

  await step('Пользователь LLM не открывает список MCP-серверов', async () => {
    // Навигация по прямой ссылке сама по себе не отклоняет Promise при отказе
    // платформы в доступе: веб-клиент остаётся без открытой формы. Проверяем
    // именно отрисованное состояние, а не форму ошибки конкретной версии 1С.
    await llmUser.navigateLink('Catalog.AI_MCPСерверы');
    const state = await llmUser.getFormState();
    assert.equal(
      state.formCount,
      0,
      `Пользователь без AI_АдминистраторMCP открыл MCP-серверы: ${JSON.stringify(state)}`,
    );
  });

  await step('Пользователь LLM не открывает регистр секретов по прямой ссылке', async () => {
    await llmUser.navigateLink('InformationRegister.AI_СекретыMCP');
    const state = await llmUser.getFormState();
    assert.equal(
      state.formCount,
      0,
      `Прямая ссылка открыла регистр секретов MCP: ${JSON.stringify(state)}`,
    );
  });
}
