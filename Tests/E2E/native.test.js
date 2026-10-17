// Run by Scripts/e2e-test.sh inside the NativeFeel fixture (JAppAutomationScript).
const style = (selector, property) => getComputedStyle(document.querySelector(selector)).getPropertyValue(property).trim();
const contextMenuPrevented = (selector, init = {}) => {
  const event = new MouseEvent("contextmenu", { bubbles: true, cancelable: true, ...init });
  document.querySelector(selector).dispatchEvent(event);
  return event.defaultPrevented;
};
const out = {
  labelSelect: style("#para", "-webkit-user-select"),
  fieldSelect: style("#field", "-webkit-user-select"),
  selectableSelect: style("#selectable", "-webkit-user-select"),
  labelCursor: style("#para", "cursor"),
  imageDrag: style("#image", "-webkit-user-drag"),
  overscroll: style("html", "overscroll-behavior"),
  windowState: document.documentElement.getAttribute("data-japp-window"),
  titlebarHeight: parseFloat(style("html", "--japp-titlebar-height")),
  titlebarInset: parseFloat(style("html", "--japp-titlebar-inset")),
  labelMenuPrevented: contextMenuPrevented("#para"),
  buttonMenuPrevented: contextMenuPrevented("#button"),
  fieldMenuPrevented: contextMenuPrevented("#field"),
  optionMenuPrevented: contextMenuPrevented("#para", { altKey: true }),
};
out.menu = await japp.menu.popup([{ id: "first", label: "First" }, "-", { id: "second", label: "Second", symbol: "star" }]);
try { await japp.menu.popup("nope"); out.badMenu = "accepted"; } catch (error) { out.badMenu = error.code; }
return out;
