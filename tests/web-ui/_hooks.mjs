// Разработческая лицензия стенда допускает один веб-сеанс 1С одновременно.
// Раннер открывает defaultContext до выбора первого теста, поэтому освобождаем
// его и затем закрываем контекст после каждого сценария. Следующий тест входит
// уже через свою публикацию и не наследует ни лицензию, ни пользователя.
export async function beforeAll(ctx) {
  await ctx.abortContext('administrator');
}

export async function afterEach(ctx) {
  for (const name of Object.keys(ctx.testInfo.contexts ?? {})) {
    await ctx.abortContext(name);
  }
}
