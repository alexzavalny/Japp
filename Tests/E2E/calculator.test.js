// Drives Calculator through its own UI (keyboard events and button clicks) and
// probes the native bridge. Run by Scripts/e2e-test.sh via `japp snapshot --script`.
const display = () => document.getElementById("result").textContent;
const expression = () => document.getElementById("expression").textContent;
const key = (k) => document.dispatchEvent(new KeyboardEvent("keydown", { key: k, bubbles: true }));
const keys = (list) => list.forEach(key);
const click = (selector) => document.querySelector(selector).click();
const r = {};

keys(["Escape", "1", "2", "+", "7", "*", "3", "Enter"]); r.precedence = [expression(), display()];
keys(["Escape", "0", ".", "1", "+", "0", ".", "2", "="]); r.decimals = display();
keys(["Escape", "8", "/", "0", "Enter"]); r.divideByZero = display();
keys(["5"]); r.recoversFromError = display();
keys(["Escape", "1", "2", "3", "Backspace"]); r.backspace = display();
keys(["Escape", "9", "-", "4", "Enter"]); r.subtraction = display();
keys(["Escape", "1", "0", "0", "0", "0", "0", "0", "*", "3", "Enter"]); r.grouping = display();
keys(["Escape", "7", "+", "-", "2", "Enter"]); r.operatorReplaced = display();
click("[data-action=clear]"); click('[data-digit="6"]'); click('[data-operator="÷"]'); click('[data-digit="4"]'); click("[data-action=equals]");
r.buttons = display();

r.historyLength = (await japp.storage.get("history", [])).length;
await japp.storage.set("probe", { n: 1.5, ok: true, list: [1, "two", null] });
r.storageRoundTrip = await japp.storage.get("probe");
await japp.storage.remove("probe");
r.storageDefault = await japp.storage.get("probe", "fallback");

try { await japp.clipboard.readText(); r.undeclaredPermission = "allowed"; } catch (e) { r.undeclaredPermission = e.code; }
try { await fetch("https://example.com/"); r.remoteFetch = "allowed"; } catch (e) { r.remoteFetch = "blocked"; }
r.localFetch = (await (await fetch("manifest.json")).json()).id;
r.missingFile = (await fetch("does-not-exist.txt")).status;
await japp.window.setTitle("Calculator (tested)");
r.app = japp.app;
r.frozen = Object.isFrozen(window.japp);
r.secureContext = window.isSecureContext;
return r;
