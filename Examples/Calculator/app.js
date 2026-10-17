// Calculator — the reference JApp.
//
// Plain JavaScript, no dependencies. Uses window.japp.storage (provided by
// JApp Runtime) to remember the calculation history between launches, and
// falls back to localStorage when the page is opened in a normal browser.

"use strict";

// ---------------------------------------------------------------------------
// Storage: japp.storage inside JApp Runtime, localStorage elsewhere.

const storage = window.japp
  ? window.japp.storage
  : {
      async get(key, fallback = null) {
        const json = localStorage.getItem("calculator." + key);
        return json === null ? fallback : JSON.parse(json);
      },
      async set(key, value) {
        localStorage.setItem("calculator." + key, JSON.stringify(value));
      },
    };

// ---------------------------------------------------------------------------
// Arithmetic

const MAX_DIGITS = 15;
const HISTORY_LIMIT = 50;

class CalculatorError extends Error {}

/** Rounds away binary floating-point noise (0.1 + 0.2 → 0.3). */
function clean(value) {
  return Number.parseFloat(value.toPrecision(12));
}

/**
 * Evaluates [number, operator, number, …] with the usual precedence:
 * × and ÷ before + and −.
 */
function evaluate(sequence) {
  const terms = [sequence[0]];
  for (let i = 1; i < sequence.length; i += 2) {
    const operator = sequence[i];
    const operand = sequence[i + 1];
    if (operator === "×") {
      terms.push(terms.pop() * operand);
    } else if (operator === "÷") {
      if (operand === 0) throw new CalculatorError("Cannot divide by zero");
      terms.push(terms.pop() / operand);
    } else {
      terms.push(operator, operand);
    }
  }
  let result = terms[0];
  for (let i = 1; i < terms.length; i += 2) {
    result = terms[i] === "+" ? result + terms[i + 1] : result - terms[i + 1];
  }
  if (!Number.isFinite(result)) throw new CalculatorError("Result is too large");
  return clean(result);
}

/** Formats a number for the display. */
function formatNumber(value) {
  if (Object.is(value, -0)) value = 0;
  const magnitude = Math.abs(value);
  if (magnitude !== 0 && (magnitude >= 1e15 || magnitude < 1e-9)) {
    return value.toExponential(8).replace(/\.?0+e/, "e");
  }
  return String(clean(value));
}

/** Adds thousands separators to a number string, keeping what the user typed after the point. */
function group(text) {
  if (text.includes("e")) return text;
  const negative = text.startsWith("-");
  const [integer, fraction] = (negative ? text.slice(1) : text).split(".");
  const grouped = integer.replace(/\B(?=(\d{3})+(?!\d))/g, ",");
  return (negative ? "-" : "") + grouped + (fraction !== undefined ? "." + fraction : "");
}

// ---------------------------------------------------------------------------
// State

const state = {
  tokens: [],            // committed [number, operator, number, operator, …]
  input: "0",            // number being typed, or null right after an operator
  justEvaluated: false,  // the display shows a result
  error: null,           // message shown instead of a number
  lastExpression: "",    // shown above the result after "="
  history: [],           // [{ expression, result }], newest first
};

function reset() {
  state.tokens = [];
  state.input = "0";
  state.justEvaluated = false;
  state.error = null;
  state.lastExpression = "";
}

function startFresh() {
  if (state.error || state.justEvaluated) reset();
}

function inputDigit(digit) {
  startFresh();
  if (state.input === null || state.input === "0") {
    state.input = digit;
  } else if (state.input === "-0") {
    state.input = "-" + digit;
  } else if (state.input.replace(/[-.]/g, "").length < MAX_DIGITS) {
    state.input += digit;
  }
}

function inputDecimal() {
  startFresh();
  if (state.input === null) state.input = "0";
  if (!state.input.includes(".")) state.input += ".";
}

function inputOperator(operator) {
  if (state.error) return;
  state.justEvaluated = false;
  state.lastExpression = "";
  if (state.input === null) {
    // Two operators in a row: the second replaces the first.
    if (state.tokens.length) state.tokens[state.tokens.length - 1] = operator;
    return;
  }
  state.tokens.push(Number.parseFloat(state.input), operator);
  state.input = null;
}

function equals() {
  if (state.error || state.justEvaluated || state.tokens.length === 0) return;
  const sequence = [...state.tokens];
  if (state.input === null) {
    sequence.pop(); // ignore a trailing operator
  } else {
    sequence.push(Number.parseFloat(state.input));
  }
  const expression = sequence.map((part) => (typeof part === "number" ? group(formatNumber(part)) : part)).join(" ");
  try {
    const result = formatNumber(evaluate(sequence));
    state.input = result;
    state.lastExpression = expression + " =";
    addToHistory(expression, result);
  } catch (error) {
    if (!(error instanceof CalculatorError)) throw error;
    state.error = error.message;
    state.lastExpression = expression + " =";
  }
  state.tokens = [];
  state.justEvaluated = true;
}

function clear() {
  // "C" clears the current entry; "AC" clears everything.
  if (!state.error && !state.justEvaluated && state.input !== null && state.input !== "0" && state.tokens.length) {
    state.input = "0";
  } else {
    reset();
  }
}

function backspace() {
  if (state.error) return reset();
  if (state.justEvaluated) return;
  if (state.input === null) {
    // Remove the operator and continue editing the previous number.
    if (state.tokens.length) {
      state.tokens.pop();
      state.input = String(state.tokens.pop());
    }
    return;
  }
  state.input = state.input.slice(0, -1);
  if (state.input === "" || state.input === "-") state.input = "0";
}

function negate() {
  if (state.error) return;
  if (state.justEvaluated) {
    state.justEvaluated = false;
    state.lastExpression = "";
  }
  if (state.input === null) {
    state.input = "-0";
  } else {
    state.input = state.input.startsWith("-") ? state.input.slice(1) : "-" + state.input;
  }
}

function percent() {
  if (state.error || state.input === null) return;
  state.input = formatNumber(Number.parseFloat(state.input) / 100);
}

// ---------------------------------------------------------------------------
// History (persisted with japp.storage)

function addToHistory(expression, result) {
  state.history.unshift({ expression, result });
  state.history.length = Math.min(state.history.length, HISTORY_LIMIT);
  renderHistory();
  storage.set("history", state.history).catch((error) => console.error("Could not save history:", error));
}

async function loadHistory() {
  try {
    const saved = await storage.get("history", []);
    state.history = Array.isArray(saved) ? saved.slice(0, HISTORY_LIMIT) : [];
  } catch (error) {
    console.error("Could not load history:", error);
  }
  renderHistory();
}

// ---------------------------------------------------------------------------
// Rendering

const elements = {
  result: document.getElementById("result"),
  expression: document.getElementById("expression"),
  clear: document.getElementById("clear"),
  keypad: document.getElementById("keypad"),
  history: document.getElementById("history"),
  historyList: document.getElementById("history-list"),
  historyEmpty: document.getElementById("history-empty"),
  historyToggle: document.getElementById("history-toggle"),
};

function render() {
  const { result, expression, clear } = elements;
  if (state.error) {
    result.textContent = state.error;
    result.classList.add("error");
  } else {
    const shown = state.input ?? formatNumber(state.tokens[state.tokens.length - 2]);
    result.textContent = group(shown);
    result.classList.remove("error");
  }
  expression.textContent = state.justEvaluated
    ? state.lastExpression
    : state.tokens.map((part) => (typeof part === "number" ? group(formatNumber(part)) : part)).join(" ");
  expression.scrollLeft = expression.scrollWidth;

  const pendingOperator = state.input === null ? state.tokens[state.tokens.length - 1] : null;
  for (const key of elements.keypad.querySelectorAll("[data-operator]")) {
    key.classList.toggle("selected", key.dataset.operator === pendingOperator);
  }
  const clearsEntry = !state.error && !state.justEvaluated && state.input !== null && state.input !== "0" && state.tokens.length > 0;
  clear.textContent = clearsEntry ? "C" : "AC";
  fitResult();
}

/** Shrinks the result text until it fits the display. */
function fitResult() {
  const { result } = elements;
  result.style.fontSize = "";
  let size = Number.parseFloat(getComputedStyle(result).fontSize);
  while (result.scrollWidth > result.clientWidth && size > 14) {
    size -= 2;
    result.style.fontSize = size + "px";
  }
}

function renderHistory() {
  const { historyList, historyEmpty } = elements;
  historyList.replaceChildren(
    ...state.history.map((entry) => {
      const item = document.createElement("li");
      item.title = "Use this result";
      const expression = document.createElement("div");
      expression.className = "history-expression";
      expression.textContent = entry.expression + " =";
      const result = document.createElement("div");
      result.className = "history-result";
      result.textContent = group(entry.result);
      item.append(expression, result);
      item.addEventListener("click", () => {
        reset();
        state.input = entry.result;
        state.justEvaluated = true;
        state.lastExpression = entry.expression + " =";
        toggleHistory(false);
        render();
      });
      return item;
    })
  );
  historyEmpty.hidden = state.history.length > 0;
}

function toggleHistory(open = !elements.history.classList.contains("open")) {
  elements.history.classList.toggle("open", open);
  elements.historyToggle.setAttribute("aria-expanded", String(open));
  elements.historyToggle.setAttribute("aria-label", open ? "Hide history" : "Show history");
}

// ---------------------------------------------------------------------------
// Input

function press(key) {
  if (key.dataset.digit !== undefined) inputDigit(key.dataset.digit);
  else if (key.dataset.operator) inputOperator(key.dataset.operator);
  else {
    const actions = { clear, negate, percent, backspace, decimal: inputDecimal, equals };
    actions[key.dataset.action]?.();
  }
  render();
}

elements.keypad.addEventListener("click", (event) => {
  const key = event.target.closest(".key");
  if (key) press(key);
});

const keyboardMap = {
  "+": '[data-operator="+"]',
  "-": '[data-operator="−"]',
  "*": '[data-operator="×"]',
  x: '[data-operator="×"]',
  X: '[data-operator="×"]',
  "/": '[data-operator="÷"]',
  ".": '[data-action="decimal"]',
  ",": '[data-action="decimal"]',
  "%": '[data-action="percent"]',
  Enter: '[data-action="equals"]',
  "=": '[data-action="equals"]',
  Backspace: '[data-action="backspace"]',
  Delete: '[data-action="backspace"]',
  Escape: '[data-action="clear"]',
  c: '[data-action="clear"]',
  C: '[data-action="clear"]',
};

document.addEventListener("keydown", (event) => {
  if (event.metaKey || event.ctrlKey || event.altKey) return;
  if (event.key === "h" || event.key === "H") {
    toggleHistory();
    return;
  }
  const selector = /^[0-9]$/.test(event.key) ? `[data-digit="${event.key}"]` : keyboardMap[event.key];
  if (!selector) return;
  event.preventDefault();
  if (event.key === "Escape") reset();
  const key = elements.keypad.querySelector(selector);
  if (event.key !== "Escape") press(key);
  else render();
  key.classList.add("pressed");
  setTimeout(() => key.classList.remove("pressed"), 120);
});

// ⌘C copies the displayed number; ⌘V pastes a number.
document.addEventListener("copy", (event) => {
  if (String(window.getSelection())) return;
  event.clipboardData.setData("text/plain", state.error ? "" : (state.input ?? "0"));
  event.preventDefault();
});

document.addEventListener("paste", (event) => {
  const text = event.clipboardData.getData("text/plain").replace(/[,\s]/g, "");
  if (!/^-?\d*\.?\d+(e[-+]?\d+)?$/i.test(text)) return;
  event.preventDefault();
  startFresh();
  state.input = formatNumber(Number.parseFloat(text));
  render();
});

elements.historyToggle.addEventListener("click", () => toggleHistory());
document.getElementById("history-clear").addEventListener("click", () => {
  state.history = [];
  renderHistory();
  storage.set("history", []).catch((error) => console.error("Could not clear history:", error));
});

new ResizeObserver(fitResult).observe(elements.result.parentElement);

render();
loadHistory();
