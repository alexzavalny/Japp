// Connector arrows between elements of a figure, drawn once the page has laid out.
//   wire("#file", "#window", { color: "rt", from: "right", to: "left", label: "double-click", dash: true })
// Sides: left, right, top, bottom; `at`/`atTo` move the anchor along that side (0–1).
// `fromEdge: "#panel"` starts the wire at that element's right edge (at the height of `from`).
const NS = "http://www.w3.org/2000/svg";
const COLORS = { rt: "--runtime", app: "--app", web: "--web", ok: "--ok", deny: "--deny", ink: "--ink-2", muted: "--muted" };
const wires = [];

function wire(from, to, options = {}) { wires.push({ from, to, ...options }); }

function anchor(rect, box, side, at = 0.5, gap = 0) {
  const x = rect.left - box.left, y = rect.top - box.top;
  switch (side) {
    case "left": return [x - gap, y + rect.height * at, -1, 0];
    case "top": return [x + rect.width * at, y - gap, 0, -1];
    case "bottom": return [x + rect.width * at, y + rect.height + gap, 0, 1];
    default: return [x + rect.width + gap, y + rect.height * at, 1, 0];
  }
}

function element(name, attributes = {}, parent) {
  const node = document.createElementNS(NS, name);
  for (const [key, value] of Object.entries(attributes)) node.setAttribute(key, value);
  parent?.appendChild(node);
  return node;
}

function drawWires() {
  const fig = document.querySelector(".fig");
  const box = fig.getBoundingClientRect();
  const svg = element("svg", { class: "wires" }, fig);
  const defs = element("defs", {}, svg);
  for (const [name, variable] of Object.entries(COLORS)) {
    const marker = element("marker", { id: `arrow-${name}`, viewBox: "0 0 10 10", refX: 8, refY: 5, markerWidth: 7, markerHeight: 7, orient: "auto-start-reverse" }, defs);
    element("path", { d: "M0 0 L10 5 L0 10 z", style: `fill: var(${variable})` }, marker);
  }
  for (const w of wires) {
    const a = document.querySelector(w.from), b = document.querySelector(w.to);
    if (!a || !b) { console.error(`wire: missing ${a ? w.to : w.from}`); continue; }
    let [x1, y1, dx1, dy1] = anchor(a.getBoundingClientRect(), box, w.side ?? w.fromSide ?? "right", w.at, w.gap ?? 6);
    if (w.fromEdge) x1 = document.querySelector(w.fromEdge).getBoundingClientRect().right - box.left + 4;
    const [x2, y2, dx2, dy2] = anchor(b.getBoundingClientRect(), box, w.toSide ?? "left", w.atTo, w.gap ?? 8);
    const bend = w.bend ?? Math.max(28, Math.hypot(x2 - x1, y2 - y1) * 0.42);
    const color = `var(${COLORS[w.color ?? "ink"]})`;
    const d = w.straight
      ? `M${x1} ${y1} L${x2} ${y2}`
      : `M${x1} ${y1} C${x1 + dx1 * bend} ${y1 + dy1 * bend} ${x2 + dx2 * bend} ${y2 + dy2 * bend} ${x2} ${y2}`;
    element("path", {
      d, class: w.dash ? "dash" : "", style: `stroke: ${color}; stroke-width: ${w.width ?? 2}`,
      ...(w.arrow === false ? {} : { "marker-end": `url(#arrow-${w.color ?? "ink"})` }),
      ...(w.both ? { "marker-start": `url(#arrow-${w.color ?? "ink"})` } : {}),
    }, svg);
    if (w.label) {
      const [lx, ly] = w.labelAt ?? [(x1 + x2) / 2 + (w.labelDx ?? 0), (y1 + y2) / 2 + (w.labelDy ?? -10)];
      const text = element("text", { x: lx, y: ly, "text-anchor": w.labelAnchor ?? "middle", style: `fill: ${color}` }, svg);
      text.textContent = w.label;
    }
  }
}

addEventListener("load", () => requestAnimationFrame(drawWires));
