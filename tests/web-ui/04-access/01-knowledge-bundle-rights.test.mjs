import fs from 'node:fs';

const roles = [
  'AI_ПользовательLLM',
  'AI_АнализДанныхАгентом',
];

export const name = 'Роль {role} читает наборы знаний без права их изменять';
export const params = roles.map(role => ({ role }));
export const tags = ['access', 'knowledge'];
export const severity = 'critical';

function objectRights(xml, objectName) {
  const escaped = objectName.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const match = xml.match(new RegExp(
    `<object>\\s*<name>${escaped}</name>([\\s\\S]*?)</object>`,
  ));
  if (!match) return new Map();

  return new Map(
    [...match[1].matchAll(
      /<right>\s*<name>([^<]+)<\/name>\s*<value>(true|false)<\/value>\s*<\/right>/g,
    )].map(item => [item[1], item[2] === 'true']),
  );
}

export default async function(ctx) {
  const { role } = ctx.testInfo.param;
  const { assert, step } = ctx;
  const rightsUrl = new URL(
    `../../../cfe llm/Roles/${role}/Ext/Rights.xml`,
    import.meta.url,
  );

  await step(`Проверить права роли ${role}`, async () => {
    const rights = objectRights(
      fs.readFileSync(rightsUrl, 'utf8'),
      'Catalog.AI_НаборыЗнаний',
    );

    assert.ok(rights.get('Read') === true, `${role}: отсутствует право Read`);
    for (const forbidden of ['Insert', 'Update', 'Delete']) {
      assert.ok(
        rights.get(forbidden) !== true,
        `${role}: неожиданно выдано право ${forbidden}`,
      );
    }
  });
}
