export const uiCommandTimeout = Number(process.env.ONEC_UI_COMMAND_TIMEOUT_MS ?? 360000);

export async function waitForUiReady(getPage, timeout = Math.max(60000, uiCommandTimeout - 90000)) {
  const page = await getPage();
  await page.waitForFunction(
    () => ![...document.querySelectorAll('.stateWindowSupportSurface')].some(element =>
      element.offsetWidth > 0 &&
      /^\s*(Поиск|Ожид|Searching|Please wait)/i.test(element.innerText || '')),
    null,
    { timeout },
  );
}
