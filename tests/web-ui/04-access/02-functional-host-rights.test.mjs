import fs from 'node:fs';

export const name = 'Администратор функционального стенда имеет права на объекты тестового хоста';
export const tags = ['access', 'functional'];
export const severity = 'critical';

function allowedRights(xml, objectName) {
  const escaped = objectName.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  const object = xml.match(new RegExp(
    `<object>\\s*<name>${escaped}</name>([\\s\\S]*?)</object>`,
  ));
  if (!object) return new Set();

  return new Set(
    [...object[1].matchAll(
      /<right>\s*<name>([^<]+)<\/name>\s*<value>true<\/value>\s*<\/right>/g,
    )].map(item => item[1]),
  );
}

export default async function(ctx) {
  const { assert, step } = ctx;
  const rightsUrl = new URL(
    '../../../cf/Roles/ПолныеПрава/Ext/Rights.xml',
    import.meta.url,
  );
  const xml = fs.readFileSync(rightsUrl, 'utf8');
  const required = new Map([
    ['Catalog.ТестовыеМаршруты', ['Read', 'Insert', 'Update', 'Delete']],
    ['Catalog.ТестовыеРоли', ['Read', 'Insert', 'Update', 'Delete']],
    ['InformationRegister.LLMTestDeliveries', ['Read', 'Update']],
    ['InformationRegister.ТестовыеЦены', ['Read', 'Update']],
    ['DataProcessor.ТестовыйОбработчикLLM', ['Use']],
  ]);

  await step('Проверить права на все данные функционального теста', async () => {
    for (const [objectName, rights] of required) {
      const actual = allowedRights(xml, objectName);
      for (const right of rights) {
        assert.ok(actual.has(right), `${objectName}: отсутствует право ${right}`);
      }
    }
  });
}
