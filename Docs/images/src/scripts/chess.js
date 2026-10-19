// Searches Dutch open tournaments, then opens the Hoogeveen Open standings.
// Needs network access to the Easy Chess Results API (set in the app's Settings).
const sleep = ms => new Promise(r => setTimeout(r, ms));
const until = async (test, tries = 60) => { for (let i = 0; i < tries && !test(); i++) await sleep(250); };
const set = (el, v) => { el.value = v; el.dispatchEvent(new Event("input", { bubbles: true })); };

location.hash = "#/tournaments";
await until(() => document.querySelector(".filter-bar input[type=search]"));
const [country, from, to] = document.querySelectorAll(".filter-bar .field");
set(country, "NED"); set(from, "2026-08-20"); set(to, "2026-10-18");
set(document.querySelector(".filter-bar input[type=search]"), "Open");
[...document.querySelectorAll("button")].find(b => b.textContent.trim() === "Search").click();

const row = () => [...document.querySelectorAll("a, li, [role=button]")]
  .find(e => /Hoogeveen Open/.test(e.textContent) && e.textContent.length < 300);
await until(row);
if (row()?.getAttribute("href")) location.hash = row().getAttribute("href"); else row()?.click();
await until(() => document.querySelector("table tbody tr"));
await sleep(800);
document.activeElement?.blur();
return document.querySelectorAll("table tbody tr").length;
