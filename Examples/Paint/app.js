// Paint: the sixteen tools and 28-colour box of Windows 98 Paint in a present-day Mac
// window. Pixels are still drawn without anti-aliasing (js/raster.js); menus are real
// macOS menus (japp.menu.popup) and dialogs are sheets.
import { Raster, flipBlock, rotateBlock, stretchBlock, skewBlock, invertBlock, encodeBMP } from "./js/raster.js";
import { svg, icon, toolCursor, squareCursor } from "./js/icons.js";

const japp = window.japp ?? null;
const $ = (selector) => document.querySelector(selector);

function h(tag, attributes = {}, ...children) {
  const node = document.createElement(tag);
  for (const [key, value] of Object.entries(attributes)) {
    if (value === undefined || value === null || value === false) continue;
    if (key === "class") node.className = value;
    else if (key === "text") node.textContent = value;
    else if (key === "html") node.innerHTML = value;
    else if (key.startsWith("on")) node.addEventListener(key.slice(2), value);
    else node.setAttribute(key, value === true ? "" : value);
  }
  node.append(...children.flat().filter((child) => child !== null && child !== undefined && child !== false));
  return node;
}

// MARK: Constants

const PALETTE = [
  "#000000", "#808080", "#800000", "#808000", "#008000", "#008080", "#000080", "#800080", "#808040", "#004040", "#0080ff", "#004080", "#8000ff", "#804000",
  "#ffffff", "#c0c0c0", "#ff0000", "#ffff00", "#00ff00", "#00ffff", "#0000ff", "#ff00ff", "#ffff80", "#00ff80", "#80ffff", "#8080ff", "#ff0080", "#ff8040",
];
const TOOLS = [
  ["freeselect", "Free-Form Select", "Q"], ["select", "Select", "M"],
  ["eraser", "Eraser", "E"], ["fill", "Fill", "G"],
  ["pick", "Pick Color", "I"], ["magnifier", "Magnifier", "Z"],
  ["pencil", "Pencil", "P"], ["brush", "Brush", "B"],
  ["airbrush", "Airbrush", "A"], ["text", "Text", "T"],
  ["line", "Line", "L"], ["curve", "Curve", "C"],
  ["rect", "Rectangle", "R"], ["polygon", "Polygon", "Y"],
  ["ellipse", "Ellipse", "O"], ["roundrect", "Rounded Rectangle", "U"],
].map(([id, name, key]) => ({ id, name, key }));
const ZOOMS = [0.25, 0.5, 1, 2, 3, 4, 6, 8, 12, 16];
const BRUSHES = [
  ["circle", 8], ["circle", 5], ["circle", 2], ["square", 8], ["square", 5], ["square", 2],
  ["slash", 8], ["slash", 5], ["slash", 3], ["backslash", 8], ["backslash", 5], ["backslash", 3],
].map(([shape, size]) => ({ shape, size }));
const DEFAULT_SIZE = { width: 640, height: 480 };
const FORMATS = {
  png: ["PNG", "Lossless"],
  bmp: ["BMP", "24-bit, like 1998"],
  jpg: ["JPEG", "Small, lossy"],
};

const state = {
  tool: "pencil",
  previousTool: "pencil",
  primary: "#000000",
  secondary: "#ffffff",
  palette: PALETTE.slice(),
  paletteIndex: 0,
  zoom: 1,
  magnifier: 6,
  brush: 1,
  eraser: 8,
  airbrush: 16,
  lineWidth: 1,
  fillStyle: "outline",
  transparent: false,
  view: { toolbox: true, colorbox: true, statusbar: true, grid: false },
  defaultSize: { ...DEFAULT_SIZE },
  fileName: "untitled",
  format: "png",
  saved: false,
  dirty: false,
  font: { family: "Helvetica Neue", size: 24, bold: false, italic: false, underline: false },
};

// MARK: Picture

const raster = new Raster(DEFAULT_SIZE.width, DEFAULT_SIZE.height);
const imageCanvas = $("#image");
const overlay = $("#overlay");
const ctx = imageCanvas.getContext("2d", { willReadFrequently: true });
const octx = overlay.getContext("2d");
const stage = $("#stage");
const workspace = $("#workspace");
const marquee = $("#marquee");

const pack = Raster.pack;
const primaryColor = () => pack(state.primary);
const secondaryColor = () => pack(state.secondary);

function applySize() {
  imageCanvas.width = overlay.width = raster.width;
  imageCanvas.height = overlay.height = raster.height;
  applyZoom();
  present();
}

function applyZoom() {
  const w = raster.width * state.zoom, h = raster.height * state.zoom;
  for (const element of [stage, imageCanvas, overlay]) {
    element.style.width = `${w}px`;
    element.style.height = `${h}px`;
  }
  const grid = $("#grid");
  grid.hidden = !(state.view.grid && state.zoom >= 4);
  grid.style.backgroundSize = `${state.zoom}px ${state.zoom}px`;
  placeMarquee();
  placeTextBox();
  updateCursor();
  updateZoomControls();
  updateTitle();
}

/** Copies the pixels to the screen (only the given box when there is one). */
function present(x0, y0, x1, y1) {
  if (x0 === undefined) return ctx.putImageData(raster.image, 0, 0);
  const ax = Math.max(0, Math.min(x0, x1)), ay = Math.max(0, Math.min(y0, y1));
  const bx = Math.min(raster.width - 1, Math.max(x0, x1)), by = Math.min(raster.height - 1, Math.max(y0, y1));
  if (bx >= ax && by >= ay) ctx.putImageData(raster.image, 0, 0, ax, ay, bx - ax + 1, by - ay + 1);
}

function presentAround(a, b, pad) { present(Math.min(a.x, b.x) - pad, Math.min(a.y, b.y) - pad, Math.max(a.x, b.x) + pad, Math.max(a.y, b.y) + pad); }

/** Reads the canvas back into the raster (after text or an imported image was drawn with Canvas 2D). */
function syncFromCanvas() {
  raster.px.set(new Uint32Array(ctx.getImageData(0, 0, raster.width, raster.height).data.buffer));
}

function blockCanvas(block) {
  const canvas = document.createElement("canvas");
  canvas.width = block.width;
  canvas.height = block.height;
  canvas.getContext("2d").putImageData(block, 0, 0);
  return canvas;
}

// MARK: History (Undo / Repeat)

const history = { undo: [], redo: [] };

function checkpoint() {
  history.undo.push(raster.snapshot());
  if (history.undo.length > 30) history.undo.shift();
  history.redo.length = 0;
  setDirty(true);
  refreshToolbar();
}

function forgetCheckpoint() {
  const snap = history.undo.pop();
  if (snap) raster.restore(snap);
}

function undo() {
  cancelTransient();
  if (!history.undo.length) return;
  history.redo.push(raster.snapshot());
  raster.restore(history.undo.pop());
  applySize();
  setDirty(true);
  refreshToolbar();
}

function redo() {
  cancelTransient();
  if (!history.redo.length) return;
  history.undo.push(raster.snapshot());
  raster.restore(history.redo.pop());
  applySize();
  setDirty(true);
  refreshToolbar();
}

function setDirty(dirty) {
  if (state.dirty === dirty) return;
  state.dirty = dirty;
  updateTitle();
}

function setFileName(name) {
  const base = name.replace(/\.[^.]+$/, "");
  const ext = (name.match(/\.([^.]+)$/)?.[1] ?? "").toLowerCase();
  state.fileName = base || "untitled";
  if (ext === "bmp" || ext === "dib") state.format = "bmp";
  else if (ext === "jpg" || ext === "jpeg") state.format = "jpg";
  else if (ext === "png") state.format = "png";
  updateTitle();
}

let shownTitle = "";
function updateTitle() {
  $("#doc-name").textContent = state.fileName;
  $("#doc-meta").textContent = `${raster.width} × ${raster.height}${state.dirty ? " — Edited" : ""}`;
  $("#status-canvas").textContent = `${raster.width} × ${raster.height}`;
  const title = `${state.fileName} — Paint`;
  if (title === shownTitle) return;
  shownTitle = title;
  document.title = title;
  japp?.window.setTitle(title).catch(() => {});
}

// MARK: Selection

/** The selected area. `block` holds its pixels once it has been lifted off the picture (floating). */
let sel = null;
let floatCanvas = null;

const insideRect = (p, r) => r && p.x >= r.x && p.y >= r.y && p.x < r.x + r.w && p.y < r.y + r.h;

/** Marching ants around a selection (or the box being dragged). */
function placeMarquee(rect = sel) {
  // An <svg> has no .hidden property; the attribute works for every element.
  if (!rect || !rect.w || !rect.h) { marquee.toggleAttribute("hidden", true); return; }
  const z = state.zoom, w = Math.round(rect.w * z) + 1, h = Math.round(rect.h * z) + 1;
  marquee.toggleAttribute("hidden", false);
  Object.assign(marquee.style, { left: `${Math.round(rect.x * z) - 0.5}px`, top: `${Math.round(rect.y * z) - 0.5}px` });
  marquee.setAttribute("width", w + 1);
  marquee.setAttribute("height", h + 1);
  for (const r of marquee.querySelectorAll("rect")) {
    r.setAttribute("x", "0.5"); r.setAttribute("y", "0.5"); r.setAttribute("width", w); r.setAttribute("height", h);
  }
}

/** The floating block as it will land: with "Draw Opaque" off, the background colour is see-through. */
function renderFloat() {
  if (!sel?.floating) { floatCanvas = null; return; }
  let block = sel.block;
  if (state.transparent) {
    block = new ImageData(new Uint8ClampedArray(sel.block.data), sel.block.width, sel.block.height);
    const px = new Uint32Array(block.data.buffer), bg = secondaryColor();
    for (let i = 0; i < px.length; i++) if (px[i] === bg) px[i] = 0;
  }
  floatCanvas = blockCanvas(block);
}

function drawOverlay() {
  octx.clearRect(0, 0, overlay.width, overlay.height);
  if (sel?.floating && floatCanvas) octx.drawImage(floatCanvas, sel.x, sel.y);
  placeMarquee();
  refreshToolbar();
}

function liftSelection(copy = false) {
  if (!sel || sel.floating) return;
  checkpoint();
  sel.block = raster.extract(sel.x, sel.y, sel.w, sel.h, sel.mask);
  if (!copy) raster.clearArea(sel.x, sel.y, sel.w, sel.h, secondaryColor(), sel.mask);
  sel.floating = true;
  present();
  renderFloat();
  drawOverlay();
}

/** Puts a floating selection down where it is and deselects. */
function dropSelection() {
  if (sel?.floating) {
    raster.stamp(sel.block, sel.x, sel.y, state.transparent ? secondaryColor() : null);
    present();
  }
  sel = null;
  floatCanvas = null;
  drawOverlay();
  updateSizeStatus();
}

function setSelection(rect) {
  sel = rect ? { mask: null, block: null, floating: false, ...rect } : null;
  drawOverlay();
  updateSizeStatus();
}

/** A floating selection made from pixels (paste, Paste From). */
function floatBlock(block, x = 0, y = 0) {
  dropSelection();
  if (block.width > raster.width || block.height > raster.height) {
    resizePicture(Math.max(raster.width, block.width), Math.max(raster.height, block.height));
  } else {
    checkpoint();
  }
  sel = { x, y, w: block.width, h: block.height, mask: null, block, floating: true };
  if (state.tool !== "select" && state.tool !== "freeselect") selectTool("select");
  renderFloat();
  drawOverlay();
  updateSizeStatus();
}

// MARK: Text

let textBox = null;

function fontCSS(scale = 1) {
  const f = state.font;
  return `${f.italic ? "italic " : ""}${f.bold ? "bold " : ""}${f.size * scale}px "${f.family}"`;
}
const lineHeight = () => Math.round(state.font.size * 1.2);

function openTextBox(rect) {
  const area = h("textarea", { class: "textbox", spellcheck: "false", "aria-label": "Text" });
  textBox = { ...rect, element: area };
  stage.append(area);
  styleTextBox();
  $("#fonts").hidden = false;
  area.focus();
}

function styleTextBox() {
  if (!textBox) return;
  const z = state.zoom, area = textBox.element;
  Object.assign(area.style, {
    left: `${textBox.x * z}px`, top: `${textBox.y * z}px`, width: `${textBox.w * z}px`, height: `${textBox.h * z}px`,
    font: fontCSS(z), lineHeight: `${lineHeight() * z}px`, color: state.primary,
    textDecoration: state.font.underline ? "underline" : "none",
    background: state.transparent ? "transparent" : state.secondary,
  });
}
const placeTextBox = styleTextBox;

/** Lines of text broken to fit the box, measured with the font the picture will use. */
function wrapText(text, width) {
  const measure = Raster.scratch(1, 1).getContext("2d");
  measure.font = fontCSS();
  const lines = [];
  for (const paragraph of text.split("\n")) {
    let line = "";
    for (const word of paragraph.split(/(\s+)/)) {
      const candidate = line + word;
      if (line && measure.measureText(candidate.trimEnd()).width > width) {
        lines.push(line.trimEnd());
        line = word.trimStart();
      } else {
        line = candidate;
      }
    }
    lines.push(line);
  }
  return { lines, measure };
}

function commitText() {
  if (!textBox) return;
  const { x, y, w, h: height, element } = textBox;
  const text = element.value;
  element.remove();
  textBox = null;
  $("#fonts").hidden = true;
  if (!text.trim()) return;
  checkpoint();
  if (!state.transparent) raster.fillRect(x, y, x + w - 1, y + height - 1, secondaryColor());
  const { lines, measure } = wrapText(text, w);
  const lh = lineHeight();
  // Text is drawn without anti-aliasing, like Paint did: a coverage mask in the foreground colour.
  const mask = Raster.mask(raster.width, raster.height, (c) => {
    c.beginPath();
    c.rect(x, y, w, height);
    c.clip();
    c.font = fontCSS();
    c.textBaseline = "top";
    c.fillStyle = "#000";
    lines.forEach((line, i) => {
      const top = y + i * lh + Math.round((lh - state.font.size) / 2);
      c.fillText(line, x, top);
      if (state.font.underline && line) {
        c.fillRect(x, top + state.font.size, measure.measureText(line).width, Math.max(1, Math.round(state.font.size / 14)));
      }
    });
  });
  raster.fillMask(mask, primaryColor());
  present();
}

// MARK: Tools

let gesture = null;    // the drag in progress
let polygon = null;    // a polygon being built click by click
let curve = null;      // a curve being bent (Paint's three-step curve)

const snap45 = (a, b) => {
  const dx = b.x - a.x, dy = b.y - a.y, angle = Math.round(Math.atan2(dy, dx) / (Math.PI / 4)) * (Math.PI / 4);
  const length = Math.max(Math.abs(dx), Math.abs(dy));
  const diagonal = Math.abs(Math.cos(angle)) > 0.1 && Math.abs(Math.sin(angle)) > 0.1;
  const d = diagonal ? length : Math.hypot(dx, dy);
  return { x: a.x + Math.round(Math.cos(angle) * d), y: a.y + Math.round(Math.sin(angle) * d) };
};
const square = (a, b) => {
  const size = Math.max(Math.abs(b.x - a.x), Math.abs(b.y - a.y));
  return { x: a.x + Math.sign(b.x - a.x || 1) * size, y: a.y + Math.sign(b.y - a.y || 1) * size };
};

/** Outline and fill colours for a shape, from the fill style and the mouse button. */
function shapeColors(g) {
  if (state.fillStyle === "outline") return { stroke: g.fg, fill: null };
  if (state.fillStyle === "both") return { stroke: g.fg, fill: g.bg };
  return { stroke: null, fill: g.fg };
}

function drawShape(kind, a, b, g) {
  const { stroke, fill } = shapeColors(g);
  if (kind === "rect") raster.rect(a.x, a.y, b.x, b.y, stroke, fill, state.lineWidth);
  else if (kind === "ellipse") raster.ellipse(a.x, a.y, b.x, b.y, stroke, fill, state.lineWidth);
  else raster.roundRect(a.x, a.y, b.x, b.y, stroke, fill, state.lineWidth);
}

function bezierPoints(p0, p1, p2, p3) {
  const steps = Math.max(16, Math.ceil((Math.hypot(p1.x - p0.x, p1.y - p0.y) + Math.hypot(p2.x - p1.x, p2.y - p1.y) + Math.hypot(p3.x - p2.x, p3.y - p2.y)) / 2));
  const points = [];
  for (let i = 0; i <= steps; i++) {
    const t = i / steps, u = 1 - t;
    points.push([
      Math.round(u * u * u * p0.x + 3 * u * u * t * p1.x + 3 * u * t * t * p2.x + t * t * t * p3.x),
      Math.round(u * u * u * p0.y + 3 * u * u * t * p1.y + 3 * u * t * t * p2.y + t * t * t * p3.y),
    ]);
  }
  return points;
}

function eraseAt(p, g) {
  const size = state.eraser, half = Math.floor(size / 2);
  if (!g.colorErase) return raster.fillRect(p.x - half, p.y - half, p.x - half + size - 1, p.y - half + size - 1, g.eraseWith);
  for (let y = p.y - half; y < p.y - half + size; y++) {
    for (let x = p.x - half; x < p.x - half + size; x++) if (raster.get(x, y) === g.replace) raster.set(x, y, g.eraseWith);
  }
}

function sizeText(a, b) { return `${Math.abs(b.x - a.x) + 1} × ${Math.abs(b.y - a.y) + 1}`; }

const tools = {
  pencil: {
    down(p, g) { checkpoint(); raster.set(p.x, p.y, g.fg); presentAround(p, p, 1); },
    move(p, g) { raster.line(g.last.x, g.last.y, p.x, p.y, g.fg); presentAround(g.last, p, 1); },
  },
  brush: {
    down(p, g) { checkpoint(); this.move(p, g); },
    move(p, g) {
      const { shape, size } = BRUSHES[state.brush];
      Raster.walk(g.last.x, g.last.y, p.x, p.y, (x, y) => raster.brush(x, y, shape, size, g.fg));
      presentAround(g.last, p, size);
    },
  },
  eraser: {
    down(p, g) {
      checkpoint();
      // Right button: the colour eraser turns the foreground colour into the background colour.
      g.colorErase = g.button === 2;
      g.eraseWith = secondaryColor();
      g.replace = primaryColor();
      eraseAt(p, g);
      presentAround(p, p, state.eraser);
    },
    move(p, g) {
      Raster.walk(g.last.x, g.last.y, p.x, p.y, (x, y) => eraseAt({ x, y }, g));
      presentAround(g.last, p, state.eraser);
    },
  },
  airbrush: {
    down(p, g) {
      checkpoint();
      g.position = p;
      const burst = () => { raster.spray(g.position.x, g.position.y, state.airbrush, g.fg); presentAround(g.position, g.position, state.airbrush); };
      burst();
      g.timer = setInterval(burst, 35);
    },
    move(p, g) { g.position = p; raster.spray(p.x, p.y, state.airbrush, g.fg); presentAround(p, p, state.airbrush); },
    up(p, g) { clearInterval(g.timer); },
  },
  fill: {
    down(p, g) {
      checkpoint();
      if (raster.floodFill(p.x, p.y, g.fg)) present(); else forgetCheckpoint();
    },
  },
  pick: {
    down(p, g) {
      if (!raster.inside(p.x, p.y)) return;
      const color = Raster.hex(raster.get(p.x, p.y));
      if (g.button === 2) state.secondary = color; else state.primary = color;
      renderCurrentColors();
      selectTool(state.previousTool === "pick" ? "pencil" : state.previousTool);
    },
  },
  magnifier: {
    down(p) { setZoom(state.zoom === 1 ? state.magnifier : 1, p); },
  },
  line: {
    down(p, g) { checkpoint(); g.base = raster.px.slice(); this.move(p, g); },
    move(p, g) {
      raster.px.set(g.base);
      const q = g.shift ? snap45(g.start, p) : p;
      raster.line(g.start.x, g.start.y, q.x, q.y, g.fg, state.lineWidth);
      present();
      setStatus("size", sizeText(g.start, q));
    },
  },
  rect: shapeTool("rect"),
  ellipse: shapeTool("ellipse"),
  roundrect: shapeTool("roundrect"),
  curve: {
    down(p, g) {
      if (!curve) {
        checkpoint();
        curve = { step: 0, p0: p, p3: p, c1: p, c2: p, base: raster.px.slice(), fg: g.fg };
      } else if (curve.step === 1) {
        curve.c1 = curve.c2 = p;
      } else {
        curve.c2 = p;
      }
      this.move(p, g);
    },
    move(p) {
      if (!curve) return;
      if (curve.step === 0) curve.p3 = p;
      else if (curve.step === 1) curve.c1 = curve.c2 = p;
      else curve.c2 = p;
      raster.px.set(curve.base);
      raster.polyline(bezierPoints(curve.p0, curve.c1, curve.c2, curve.p3), curve.fg, state.lineWidth);
      present();
    },
    up() {
      if (!curve) return;
      curve.step += 1;
      if (curve.step > 2) curve = null;
    },
  },
  polygon: {
    down(p, g) {
      if (!polygon) {
        checkpoint();
        polygon = { points: [[p.x, p.y]], cursor: p, base: raster.px.slice(), g, dragged: true };
        return this.render();
      }
      const [fx, fy] = polygon.points[0];
      if (g.event.detail >= 2 || (polygon.points.length > 2 && Math.abs(p.x - fx) <= 3 && Math.abs(p.y - fy) <= 3)) return finishPolygon();
      polygon.cursor = p;
      this.render();
    },
    move(p) { if (polygon) { polygon.cursor = p; this.render(); } },
    hover(p) { if (polygon) { polygon.cursor = p; this.render(); } },
    up(p) {
      if (!polygon) return;
      const last = polygon.points[polygon.points.length - 1];
      if (last[0] !== p.x || last[1] !== p.y) polygon.points.push([p.x, p.y]);
      this.render();
    },
    render() {
      raster.px.set(polygon.base);
      raster.polyline([...polygon.points, [polygon.cursor.x, polygon.cursor.y]], polygon.g.fg, state.lineWidth);
      present();
    },
  },
  select: selectTool_("rect"),
  freeselect: selectTool_("free"),
  text: {
    down(p, g) {
      if (textBox) {
        if (insideRect(p, textBox)) { g.ignore = true; return; }
        commitText();
        g.ignore = true;
        return;
      }
    },
    move(p, g) {
      if (g.ignore) return;
      const r = rectFrom(g.start, p);
      placeMarquee(r);
      setStatus("size", `${r.w} × ${r.h}`);
    },
    up(p, g) {
      if (g.ignore) return;
      placeMarquee(null);
      let r = rectFrom(g.start, p);
      if (r.w < 8 || r.h < 8) r = { x: g.start.x, y: g.start.y, w: Math.max(120, state.font.size * 8), h: lineHeight() + 4 };
      openTextBox(r);
    },
  },
};

function shapeTool(kind) {
  return {
    down(p, g) { checkpoint(); g.base = raster.px.slice(); this.move(p, g); },
    move(p, g) {
      raster.px.set(g.base);
      const q = g.shift ? square(g.start, p) : p;
      drawShape(kind, g.start, q, g);
      present();
      setStatus("size", sizeText(g.start, q));
    },
  };
}

function rectFrom(a, b) {
  const x0 = Math.max(0, Math.min(a.x, b.x)), y0 = Math.max(0, Math.min(a.y, b.y));
  const x1 = Math.min(raster.width - 1, Math.max(a.x, b.x)), y1 = Math.min(raster.height - 1, Math.max(a.y, b.y));
  return { x: x0, y: y0, w: Math.max(0, x1 - x0 + 1), h: Math.max(0, y1 - y0 + 1) };
}

function selectTool_(kind) {
  return {
    down(p, g) {
      if (insideRect(p, sel)) {
        // Drag the selection; with ⌥ (or Ctrl) a copy stays behind.
        g.mode = "move";
        const copy = g.event.altKey || g.event.ctrlKey;
        if (sel.floating && copy) {
          raster.stamp(sel.block, sel.x, sel.y, state.transparent ? secondaryColor() : null);
          present();
        }
        liftSelection(copy);
        g.offset = { x: p.x - sel.x, y: p.y - sel.y };
        return;
      }
      dropSelection();
      g.mode = "new";
      g.path = [[p.x, p.y]];
    },
    move(p, g) {
      if (g.mode === "move") {
        sel.x = p.x - g.offset.x;
        sel.y = p.y - g.offset.y;
        drawOverlay();
        return;
      }
      if (kind === "rect") {
        const r = rectFrom(g.start, p);
        placeMarquee(r);
        setStatus("size", `${r.w} × ${r.h}`);
      } else {
        g.path.push([p.x, p.y]);
        octx.clearRect(0, 0, overlay.width, overlay.height);
        octx.fillStyle = "#000";
        for (let i = 1; i < g.path.length; i++) {
          Raster.walk(g.path[i - 1][0], g.path[i - 1][1], g.path[i][0], g.path[i][1], (x, y) => octx.fillRect(x, y, 1, 1));
        }
      }
    },
    up(p, g) {
      if (g.mode === "move") return;
      if (kind === "rect") {
        const r = rectFrom(g.start, p);
        setSelection(r.w > 0 && r.h > 0 && (g.start.x !== p.x || g.start.y !== p.y) ? r : null);
        return;
      }
      octx.clearRect(0, 0, overlay.width, overlay.height);
      setSelection(freeformSelection(g.path));
    },
  };
}

function freeformSelection(path) {
  if (path.length < 3) return null;
  const xs = path.map((q) => q[0]), ys = path.map((q) => q[1]);
  const r = rectFrom({ x: Math.min(...xs), y: Math.min(...ys) }, { x: Math.max(...xs), y: Math.max(...ys) });
  if (r.w < 1 || r.h < 1) return null;
  const mask = Raster.coverage(r.w, r.h, (c) => {
    c.moveTo(path[0][0] - r.x + 0.5, path[0][1] - r.y + 0.5);
    for (const [x, y] of path.slice(1)) c.lineTo(x - r.x + 0.5, y - r.y + 0.5);
    c.closePath();
  });
  return mask.some(Boolean) ? { ...r, mask } : null;
}

function finishPolygon(cancel = false) {
  if (!polygon) return;
  raster.px.set(polygon.base);
  if (cancel) {
    forgetCheckpoint();
  } else {
    const points = polygon.points;
    const { stroke, fill } = shapeColors(polygon.g);
    if (points.length > 1) raster.polygon(points, stroke, fill, state.lineWidth);
  }
  polygon = null;
  present();
}

/** Ends whatever is half done: commits text, curves and polygons, or (cancel) drops them. */
function finishTransient() {
  commitText();
  finishPolygon();
  curve = null;
}

function cancelTransient() {
  if (textBox) { textBox.element.remove(); textBox = null; $("#fonts").hidden = true; }
  if (polygon) finishPolygon(true);
  if (curve) { raster.px.set(curve.base); forgetCheckpoint(); curve = null; present(); }
  if (sel) { sel = null; floatCanvas = null; drawOverlay(); }
}

// MARK: Pointer input

/** Keeps pointer events coming while dragging outside (synthetic events have no pointer to capture). */
function capture(element, event) {
  try { element.setPointerCapture(event.pointerId); } catch { /* not a real pointer */ }
}

function pointFrom(event) {
  const rect = stage.getBoundingClientRect();
  return { x: Math.floor((event.clientX - rect.left) / state.zoom), y: Math.floor((event.clientY - rect.top) / state.zoom) };
}

stage.addEventListener("pointerdown", (event) => {
  if (event.button !== 0 && event.button !== 2) return;
  if (event.target.classList.contains("handle") || event.target === textBox?.element) return;
  event.preventDefault();
  closeMenus();
  const p = pointFrom(event);
  // A right click (or ⌃-click) draws in the background colour.
  const secondary = event.button === 2 || (event.ctrlKey && !insideRect(p, sel));
  const g = {
    button: secondary ? 2 : 0, event, start: p, last: p, shift: event.shiftKey,
    fg: secondary ? secondaryColor() : primaryColor(), bg: secondary ? primaryColor() : secondaryColor(),
  };
  if (!["select", "freeselect"].includes(state.tool) && sel) dropSelection();
  capture(stage, event);
  // The gesture stays with the tool that started it (Pick Color switches tools on the spot).
  g.tool = tools[state.tool];
  gesture = g;
  g.tool.down?.(p, g);
});

stage.addEventListener("pointermove", (event) => {
  const p = pointFrom(event);
  setStatus("xy", raster.inside(p.x, p.y) ? `${p.x}, ${p.y}` : "");
  if (gesture) {
    gesture.shift = event.shiftKey;
    gesture.event = event;
    gesture.tool.move?.(p, gesture);
    gesture.last = p;
  } else {
    tools[state.tool].hover?.(p);
  }
});

function endGesture(event) {
  if (!gesture) return;
  const p = pointFrom(event), g = gesture;
  gesture = null;
  g.event = event;
  g.tool.up?.(p, g);
  if (!sel) setStatus("size", "");
  refreshToolbar();
}
stage.addEventListener("pointerup", endGesture);
stage.addEventListener("pointercancel", endGesture);
stage.addEventListener("pointerleave", () => { if (!gesture) setStatus("xy", ""); });
stage.addEventListener("contextmenu", (event) => event.preventDefault());

// Canvas size handles (right, bottom, corner), as in Paint.
for (const handle of document.querySelectorAll(".handle")) {
  handle.addEventListener("pointerdown", (event) => {
    event.preventDefault();
    event.stopPropagation();
    finishTransient();
    dropSelection();
    capture(handle, event);
    const kind = handle.dataset.handle, outline = $("#resize-outline");
    let size = { w: raster.width, h: raster.height };
    const move = (e) => {
      const rect = stage.getBoundingClientRect();
      size = {
        w: kind === "b" ? raster.width : Math.max(1, Math.round((e.clientX - rect.left) / state.zoom)),
        h: kind === "r" ? raster.height : Math.max(1, Math.round((e.clientY - rect.top) / state.zoom)),
      };
      outline.hidden = false;
      Object.assign(outline.style, { width: `${size.w * state.zoom}px`, height: `${size.h * state.zoom}px` });
      setStatus("size", `${size.w} × ${size.h}`);
    };
    const up = () => {
      handle.removeEventListener("pointermove", move);
      outline.hidden = true;
      setStatus("size", "");
      if (size.w !== raster.width || size.h !== raster.height) resizePicture(size.w, size.h);
    };
    handle.addEventListener("pointermove", move);
    handle.addEventListener("pointerup", up, { once: true });
  });
}

// MARK: Picture operations

function resizePicture(width, height) {
  width = Math.max(1, Math.min(8000, width));
  height = Math.max(1, Math.min(8000, height));
  checkpoint();
  const old = raster.snapshot();
  raster.resize(width, height, secondaryColor());
  for (let y = 0; y < Math.min(height, old.height); y++) {
    raster.px.set(old.px.subarray(y * old.width, y * old.width + Math.min(width, old.width)), y * width);
  }
  applySize();
}

/** Applies a block transform to the selection, or to the whole picture. */
function transform(fn, { background = secondaryColor() } = {}) {
  finishTransient();
  if (sel) {
    liftSelection(false);
    sel.block = fn(sel.block, 0);
    sel.w = sel.block.width;
    sel.h = sel.block.height;
    renderFloat();
    drawOverlay();
    updateSizeStatus();
    return;
  }
  checkpoint();
  const result = fn(new ImageData(new Uint8ClampedArray(raster.image.data), raster.width, raster.height), background);
  if (result.width !== raster.width || result.height !== raster.height) raster.resize(result.width, result.height, 0);
  raster.px.set(new Uint32Array(result.data.buffer));
  applySize();
}

function invertColors() { transform((block) => invertBlock(block)); }

function clearImage() {
  finishTransient();
  if (sel) return clearSelection();
  checkpoint();
  raster.px.fill(secondaryColor());
  present();
}

function clearSelection() {
  if (!sel) return;
  if (!sel.floating) {
    checkpoint();
    raster.clearArea(sel.x, sel.y, sel.w, sel.h, secondaryColor(), sel.mask);
    present();
  }
  sel = null;
  floatCanvas = null;
  drawOverlay();
  updateSizeStatus();
}

function selectAll() {
  finishTransient();
  dropSelection();
  selectTool("select");
  setSelection({ x: 0, y: 0, w: raster.width, h: raster.height });
}

// MARK: Clipboard

let clipboard = null;
let pendingPaste = null;

function selectionBlock() {
  if (!sel) return null;
  return sel.floating ? sel.block : raster.extract(sel.x, sel.y, sel.w, sel.h, sel.mask);
}

function copy() {
  const block = selectionBlock();
  if (!block) return false;
  clipboard = new ImageData(new Uint8ClampedArray(block.data), block.width, block.height);
  refreshToolbar();
  // Also put it on the Mac clipboard, so other apps can paste it.
  try {
    const blob = new Promise((resolve) => blockCanvas(block).toBlob(resolve, "image/png"));
    navigator.clipboard?.write([new ClipboardItem({ "image/png": blob })]).catch(() => {});
  } catch { /* the internal clipboard still works */ }
  return true;
}

function cut() {
  if (!copy()) return false;
  clearSelection();
  return true;
}

function pasteInternal() {
  if (!clipboard) return;
  finishTransient();
  floatBlock(new ImageData(new Uint8ClampedArray(clipboard.data), clipboard.width, clipboard.height), visibleOrigin().x, visibleOrigin().y);
}

/** Paint pastes at the top-left corner of what you can see. */
function visibleOrigin() {
  const view = workspace.getBoundingClientRect(), picture = stage.getBoundingClientRect();
  return {
    x: Math.max(0, Math.floor((view.left - picture.left) / state.zoom)),
    y: Math.max(0, Math.floor((view.top - picture.top) / state.zoom)),
  };
}

async function pasteImageFile(file) {
  const url = await new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => resolve(reader.result);
    reader.onerror = reject;
    reader.readAsDataURL(file);
  });
  const block = await blockFromDataURL(url);
  finishTransient();
  floatBlock(block, visibleOrigin().x, visibleOrigin().y);
}

document.addEventListener("paste", (event) => {
  if (isTyping(event.target)) return;
  event.preventDefault();
  clearTimeout(pendingPaste);
  pendingPaste = null;
  const file = [...(event.clipboardData?.files ?? [])].find((f) => f.type.startsWith("image/"));
  if (file) pasteImageFile(file).catch(() => pasteInternal());
  else pasteInternal();
});
document.addEventListener("copy", (event) => { if (!isTyping(event.target) && sel) { event.preventDefault(); copy(); } });
document.addEventListener("cut", (event) => { if (!isTyping(event.target) && sel) { event.preventDefault(); cut(); } });

// MARK: Files

async function blockFromDataURL(url) {
  const image = new Image();
  image.src = url;
  await image.decode();
  const canvas = document.createElement("canvas");
  canvas.width = image.naturalWidth;
  canvas.height = image.naturalHeight;
  const c = canvas.getContext("2d");
  c.fillStyle = "#fff";   // Paint has no transparency: see-through pixels become white
  c.fillRect(0, 0, canvas.width, canvas.height);
  c.drawImage(image, 0, 0);
  return c.getImageData(0, 0, canvas.width, canvas.height);
}

function base64(bytes) {
  let binary = "";
  for (let i = 0; i < bytes.length; i += 0x8000) binary += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  return btoa(binary);
}

function encodePicture(format) {
  present();
  if (format === "bmp") return base64(encodeBMP(raster));
  const url = imageCanvas.toDataURL(format === "jpg" ? "image/jpeg" : "image/png", 0.92);
  return url.slice(url.indexOf(",") + 1);
}

async function pickFile() {
  if (japp) return japp.dialog.openFile({ accept: ["png", "bmp", "dib", "jpg", "jpeg", "gif"], encoding: "dataURL", title: "Open a picture" });
  return new Promise((resolve) => {
    const input = h("input", { type: "file", accept: "image/*" });
    input.addEventListener("change", async () => {
      const file = input.files[0];
      if (!file) return resolve(null);
      const reader = new FileReader();
      reader.onload = () => resolve({ name: file.name, dataURL: reader.result });
      reader.readAsDataURL(file);
    });
    input.click();
  });
}

async function writeFile(name, content, ext) {
  if (japp) return japp.dialog.saveFile({ suggestedName: name, content, encoding: "base64", accept: [ext], title: "Save the picture" });
  const link = h("a", { href: `data:application/octet-stream;base64,${content}`, download: name });
  link.click();
  return { name };
}

async function openPicture() {
  if (!(await confirmDiscard())) return;
  const file = await pickFile();
  if (!file) return;
  await loadPicture(file.dataURL, file.name);
}

async function loadPicture(url, name) {
  let block;
  try {
    block = await blockFromDataURL(url);
  } catch {
    return messageBox("This picture can’t be opened.", "Paint can open PNG, BMP, JPEG and GIF files.", ["OK"], "warning");
  }
  finishTransient();
  sel = null;
  history.undo.length = history.redo.length = 0;
  raster.resize(block.width, block.height, 0);
  raster.px.set(new Uint32Array(block.data.buffer));
  applySize();
  drawOverlay();
  setFileName(name);
  state.saved = true;
  setDirty(false);
}

async function save(saveAs) {
  finishTransient();
  dropSelection();
  let format = state.format;
  if (saveAs || !state.saved) {
    format = await saveAsDialog();
    if (!format) return false;
  }
  const ext = format;
  const result = await writeFile(`${state.fileName}.${ext}`, encodePicture(format), ext);
  if (!result) return false;
  setFileName(result.name);
  state.format = format;
  state.saved = true;
  setDirty(false);
  saveSettings();
  return true;
}

/** "Save changes to untitled?" — true when it is fine to throw the picture away. */
async function confirmDiscard() {
  finishTransient();
  if (!state.dirty) return true;
  const choice = await messageBox(`Do you want to save the changes made to “${state.fileName}”?`,
    "Your changes will be lost if you don’t save them.", ["Save", "Don’t Save", "Cancel"], "warning");
  if (choice === 0) return save(false);
  return choice === 1;
}

async function newPicture() {
  if (!(await confirmDiscard())) return;
  sel = null;
  history.undo.length = history.redo.length = 0;
  raster.resize(state.defaultSize.width, state.defaultSize.height, Raster.WHITE);
  applySize();
  drawOverlay();
  state.fileName = "untitled";
  state.saved = false;
  setDirty(false);
  updateTitle();
}

async function exitPaint() {
  if (!(await confirmDiscard())) return;
  if (japp) japp.window.close(); else window.close();
}

async function copyTo() {
  const block = selectionBlock();
  if (!block) return;
  const url = blockCanvas(block).toDataURL("image/png");
  await writeFile("selection.png", url.slice(url.indexOf(",") + 1), "png");
}

async function pasteFrom() {
  const file = await pickFile();
  if (!file) return;
  try {
    const block = await blockFromDataURL(file.dataURL);
    finishTransient();
    floatBlock(block, visibleOrigin().x, visibleOrigin().y);
  } catch {
    messageBox("This picture can’t be opened.", "Paint can open PNG, BMP, JPEG and GIF files.", ["OK"], "warning");
  }
}

// Drop an image file on the window to open it.
workspace.addEventListener("dragover", (event) => { event.preventDefault(); });
workspace.addEventListener("drop", async (event) => {
  event.preventDefault();
  const file = [...(event.dataTransfer?.files ?? [])].find((f) => f.type.startsWith("image/"));
  if (!file || !(await confirmDiscard())) return;
  const reader = new FileReader();
  reader.onload = () => loadPicture(reader.result, file.name);
  reader.readAsDataURL(file);
});

// MARK: Zoom

function setZoom(zoom, focus) {
  finishTransient();
  const view = workspace.getBoundingClientRect(), picture = stage.getBoundingClientRect();
  // Keep the given picture point (or the centre of the view) where it is on screen.
  const anchor = focus ?? {
    x: (view.left + view.width / 2 - picture.left) / state.zoom,
    y: (view.top + view.height / 2 - picture.top) / state.zoom,
  };
  state.zoom = zoom;
  applyZoom();
  workspace.scrollLeft = stage.offsetLeft + anchor.x * zoom - workspace.clientWidth / 2;
  workspace.scrollTop = stage.offsetTop + anchor.y * zoom - workspace.clientHeight / 2;
  renderOptions();
}

function zoomStep(direction) {
  const index = ZOOMS.indexOf(state.zoom);
  const next = ZOOMS[Math.max(0, Math.min(ZOOMS.length - 1, (index < 0 ? 2 : index) + direction))];
  if (next !== state.zoom) setZoom(next);
}

function zoomToFit() {
  const width = workspace.clientWidth - 56, height = workspace.clientHeight - 56;
  const fit = ZOOMS.filter((z) => raster.width * z <= width && raster.height * z <= height).pop() ?? ZOOMS[0];
  setZoom(fit);
}

function updateZoomControls() {
  const percent = `${Math.round(state.zoom * 100)}%`;
  $("#zoom-value").textContent = percent;
  const index = ZOOMS.indexOf(state.zoom);
  if (index >= 0) $("#zoom-slider").value = String(index);
}

// MARK: Tool panel

function selectTool(id) {
  if (id === state.tool) return;
  finishTransient();
  if (!["select", "freeselect"].includes(id)) dropSelection();
  if (id === "pick" || state.tool !== "pick") state.previousTool = state.tool;
  state.tool = id;
  for (const button of document.querySelectorAll(".tool")) button.setAttribute("aria-checked", String(button.dataset.tool === id));
  $("#fonts").hidden = !(id === "text" && textBox);
  renderOptions();
  updateCursor();
}

function renderTools() {
  const box = $("#tools");
  for (const tool of TOOLS) {
    box.append(h("button", {
      type: "button", class: "tool", role: "radio", "aria-checked": String(tool.id === state.tool),
      "aria-label": tool.name, title: `${tool.name} (${tool.key})`, "data-tool": tool.id,
      onclick: () => selectTool(tool.id),
    }, icon(tool.id, 20)));
  }
}

const glyph = (width, height, body) => {
  const holder = document.createElement("span");
  holder.innerHTML = `<svg width="${width}" height="${height}" viewBox="0 0 ${width} ${height}" fill="currentColor" stroke="currentColor" stroke-width="0">${body}</svg>`;
  return holder.firstChild;
};

function option(pressed, content, label, onclick) {
  return h("button", {
    type: "button", class: "opt", "aria-pressed": String(pressed), title: label, "aria-label": label,
    onclick: () => { onclick(); renderOptions(); updateCursor(); saveSettings(); },
  }, content);
}

function renderOptions() {
  const box = $("#options"), title = $("#options-title");
  box.replaceChildren();
  box.className = "options";
  title.textContent = "";
  const t = state.tool;
  if (t === "select" || t === "freeselect" || t === "text") {
    title.textContent = "Background";
    box.append(
      option(!state.transparent, "Opaque", "Opaque background", () => setTransparent(false)),
      option(state.transparent, "Transparent", "Transparent background", () => setTransparent(true)));
  } else if (t === "eraser") {
    title.textContent = "Size";
    box.className = "options cols-2";
    for (const size of [4, 6, 8, 10]) {
      box.append(option(state.eraser === size, glyph(14, 14, `<rect x="${(14 - size) / 2}" y="${(14 - size) / 2}" width="${size}" height="${size}" rx="1.5"/>`), `${size} px`, () => { state.eraser = size; }));
    }
  } else if (t === "magnifier") {
    title.textContent = "Zoom";
    box.className = "options cols-2";
    for (const level of [1, 2, 6, 8]) box.append(option(state.zoom === level, `${level}×`, `${level * 100}%`, () => { state.magnifier = level; setZoom(level); }));
  } else if (t === "brush") {
    title.textContent = "Brush";
    box.className = "options cols-3";
    BRUSHES.forEach((b, i) => {
      const c = 7, r = Math.max(1, b.size / 2 + 0.5);
      const body = b.shape === "circle" ? `<circle cx="${c}" cy="${c}" r="${r}"/>`
        : b.shape === "square" ? `<rect x="${c - r}" y="${c - r}" width="${2 * r}" height="${2 * r}"/>`
        : b.shape === "slash" ? `<path d="M${c - r} ${c + r}L${c + r} ${c - r}" stroke-width="1.6" stroke-linecap="round"/>`
        : `<path d="M${c - r} ${c - r}L${c + r} ${c + r}" stroke-width="1.6" stroke-linecap="round"/>`;
      box.append(option(state.brush === i, glyph(14, 14, body), `${b.shape} ${b.size}`, () => { state.brush = i; }));
    });
  } else if (t === "airbrush") {
    title.textContent = "Spray";
    const dots = (d) => Array.from({ length: d + 6 }, (_, i) => {
      const a = i * 2.39996, rr = Math.sqrt(i / (d + 6)) * (d / 2.4);
      return `<circle cx="${(26 + Math.cos(a) * rr).toFixed(1)}" cy="${(11 + Math.sin(a) * rr).toFixed(1)}" r=".9"/>`;
    }).join("");
    for (const size of [9, 16, 24]) box.append(option(state.airbrush === size, glyph(52, 22, dots(size)), `${size} px`, () => { state.airbrush = size; }));
  } else if (t === "line" || t === "curve") {
    title.textContent = "Width";
    for (const width of [1, 2, 3, 4, 5]) box.append(option(state.lineWidth === width, glyph(48, 8, `<rect x="2" y="${(8 - width) / 2}" width="44" height="${width}" rx="${width / 2}"/>`), `${width} px`, () => { state.lineWidth = width; }));
  } else if (["rect", "ellipse", "roundrect", "polygon"].includes(t)) {
    title.textContent = "Style";
    const styles = [
      ["outline", "Outline", `<rect x="5.5" y="3.5" width="37" height="15" rx="3" fill="none" stroke-width="1.6"/>`],
      ["both", "Outline and fill", `<rect x="5.5" y="3.5" width="37" height="15" rx="3" fill-opacity=".35" stroke-width="1.6"/>`],
      ["fill", "Fill", `<rect x="5" y="3" width="38" height="16" rx="3"/>`],
    ];
    for (const [style, label, body] of styles) box.append(option(state.fillStyle === style, glyph(48, 22, body), label, () => { state.fillStyle = style; }));
  }
}

function setTransparent(transparent) {
  state.transparent = transparent;
  renderFloat();
  drawOverlay();
  styleTextBox();
}

// MARK: Colors

const colorInput = $("#color-input");
let colorTarget = null;

/** Opens the macOS color picker next to `anchor`; `onPick` gets every colour chosen. */
function pickColor(anchor, initial, onPick) {
  const rect = anchor.getBoundingClientRect();
  Object.assign(colorInput.style, { position: "fixed", left: `${rect.left}px`, top: `${rect.top}px`, width: `${rect.width}px`, height: `${rect.height}px` });
  colorInput.value = initial;
  colorTarget = onPick;
  colorInput.click();
}
colorInput.addEventListener("input", () => colorTarget?.(colorInput.value));
colorInput.addEventListener("change", () => { colorTarget?.(colorInput.value); saveSettings(); });

function renderPalette() {
  const box = $("#palette");
  box.replaceChildren();
  state.palette.forEach((color, index) => {
    const swatch = h("button", { type: "button", class: "swatch", style: `background:${color}`, title: `${color} — double-click to change`, "aria-label": color });
    swatch.addEventListener("pointerdown", (event) => {
      event.preventDefault();
      state.paletteIndex = index;
      if (event.button === 2 || event.ctrlKey) state.secondary = color; else state.primary = color;
      renderCurrentColors();
    });
    swatch.addEventListener("dblclick", () => editColor(index, swatch));
    swatch.addEventListener("contextmenu", (event) => event.preventDefault());
    box.append(swatch);
  });
}

function editColor(index = state.paletteIndex, anchor = $("#custom-color")) {
  pickColor(anchor, state.palette[index], (color) => {
    state.palette[index] = color;
    state.primary = color;
    renderPalette();
    renderCurrentColors();
  });
}

function renderCurrentColors() {
  $("#current-primary").style.background = state.primary;
  $("#current-secondary").style.background = state.secondary;
  renderFloat();
  drawOverlay();
  styleTextBox();
}

function swapColors() {
  [state.primary, state.secondary] = [state.secondary, state.primary];
  renderCurrentColors();
}

function setupColors() {
  $("#swap-colors").append(icon("swap", 14, 1.8));
  $("#swap-colors").addEventListener("click", swapColors);
  $("#current-primary").addEventListener("click", (e) => pickColor(e.currentTarget, state.primary, (c) => { state.primary = c; renderCurrentColors(); }));
  $("#current-secondary").addEventListener("click", (e) => pickColor(e.currentTarget, state.secondary, (c) => { state.secondary = c; renderCurrentColors(); }));
  $("#custom-color").addEventListener("click", (e) => pickColor(e.currentTarget, state.primary, (c) => { state.primary = c; renderCurrentColors(); }));
}

// MARK: Cursors

const cursors = {};
async function prepareCursors() {
  const spots = { pencil: [3, 21], fill: [20, 20], pick: [3, 21], magnifier: [10, 10], airbrush: [4, 8] };
  for (const [name, [x, y]] of Object.entries(spots)) {
    try { cursors[name] = await toolCursor(name, x, y); } catch { /* the crosshair will do */ }
  }
  updateCursor();
}

function updateCursor() {
  const t = state.tool;
  const cursor = t === "eraser" ? squareCursor(state.eraser * state.zoom) : cursors[t];
  stage.style.cursor = "crosshair";
  if (!cursor) return;
  // WebKit takes the 1×/2× image-set; the plain url() is the fallback if it does not.
  stage.style.cursor = cursor.fallback;
  stage.style.cursor = cursor.set;
}

// MARK: Status bar

function setStatus(pane, text) {
  const element = $(`#status-${pane}`);
  if (element) element.textContent = text || (pane === "help" ? "" : "—");
}
function updateSizeStatus() { setStatus("size", sel ? `${sel.w} × ${sel.h}` : ""); }

function setupStatus() {
  for (const holder of document.querySelectorAll("[data-icon]")) holder.append(icon(holder.dataset.icon, 13, 1.7));
  $("#zoom-out").append(icon("minus", 14, 1.8));
  $("#zoom-in").append(icon("plus", 14, 1.8));
  $("#zoom-out").addEventListener("click", () => zoomStep(-1));
  $("#zoom-in").addEventListener("click", () => zoomStep(1));
  $("#zoom-slider").addEventListener("input", (e) => setZoom(ZOOMS[Number(e.target.value)]));
  $("#zoom-value").addEventListener("click", (e) => popup(zoomMenu(), e.currentTarget));
}

// MARK: Views

function toggleView(name) {
  state.view[name] = !state.view[name];
  applyViews();
  saveSettings();
}

function applyViews() {
  $("#toolbox").hidden = !state.view.toolbox;
  $("#colorbox").hidden = !state.view.colorbox;
  $("#statusbar").hidden = !state.view.statusbar;
  applyZoom();
}

function toggleGrid() {
  if (state.zoom < 4) return;
  state.view.grid = !state.view.grid;
  applyZoom();
}

// MARK: Menus (real macOS menus via japp.menu.popup)

const hasSelection = () => Boolean(sel);
const MENUS = {
  file: () => [
    { id: "new", label: "New", symbol: "doc.badge.plus", shortcut: "cmd+n", action: newPicture },
    { id: "open", label: "Open…", symbol: "folder", shortcut: "cmd+o", action: openPicture },
    "-",
    { id: "save", label: "Save…", symbol: "square.and.arrow.down", shortcut: "cmd+s", action: () => save(false) },
    { id: "saveas", label: "Save As…", shortcut: "cmd+shift+s", action: () => save(true) },
    "-",
    { id: "export", label: "Export Selection…", symbol: "square.and.arrow.up", enabled: hasSelection(), action: copyTo },
    { id: "place", label: "Place Picture…", symbol: "photo", action: pasteFrom },
    "-",
    { id: "close", label: "Close", symbol: "xmark", action: exitPaint },
  ],
  select: () => [
    { id: "all", label: "Select All", symbol: "selection.pin.in.out", shortcut: "cmd+a", action: selectAll },
    { id: "deselect", label: "Deselect", shortcut: "cmd+d", enabled: hasSelection(), action: () => { finishTransient(); dropSelection(); } },
    { id: "delete", label: "Delete", symbol: "trash", shortcut: "delete", enabled: hasSelection(), action: clearSelection },
    "-",
    { id: "transparent", label: "Transparent Background", checked: state.transparent, action: () => { setTransparent(!state.transparent); renderOptions(); } },
  ],
  image: () => [
    { id: "fliph", label: "Flip Horizontal", symbol: "arrow.left.and.right", action: () => transform((b) => flipBlock(b, true)) },
    { id: "flipv", label: "Flip Vertical", symbol: "arrow.up.and.down", action: () => transform((b) => flipBlock(b, false)) },
    { id: "rotr", label: "Rotate Right", symbol: "rotate.right", shortcut: "cmd+r", action: () => transform((b) => rotateBlock(b, 90)) },
    { id: "rotl", label: "Rotate Left", symbol: "rotate.left", shortcut: "cmd+shift+r", action: () => transform((b) => rotateBlock(b, 270)) },
    { id: "rot180", label: "Rotate 180°", action: () => transform((b) => rotateBlock(b, 180)) },
    "-",
    { id: "stretch", label: "Stretch and Skew…", symbol: "skew", shortcut: "ctrl+w", action: stretchSkewDialog },
    { id: "size", label: "Canvas Size…", symbol: "aspectratio", shortcut: "cmd+e", action: attributesDialog },
    { id: "invert", label: "Invert Colors", symbol: "circle.lefthalf.filled", shortcut: "cmd+i", action: invertColors },
    "-",
    { id: "clear", label: sel ? "Clear Selection" : "Clear Image", symbol: "eraser", shortcut: "cmd+shift+n", action: clearImage },
  ],
  view: () => [
    { id: "tools", label: "Tools", symbol: "sidebar.left", shortcut: "cmd+t", checked: state.view.toolbox, action: () => toggleView("toolbox") },
    { id: "colors", label: "Colors", symbol: "paintpalette", shortcut: "cmd+l", checked: state.view.colorbox, action: () => toggleView("colorbox") },
    { id: "status", label: "Status Bar", checked: state.view.statusbar, action: () => toggleView("statusbar") },
    "-",
    { id: "zoomin", label: "Zoom In", symbol: "plus.magnifyingglass", shortcut: "cmd+=", action: () => zoomStep(1) },
    { id: "zoomout", label: "Zoom Out", symbol: "minus.magnifyingglass", shortcut: "cmd+-", action: () => zoomStep(-1) },
    { id: "actual", label: "Actual Size", symbol: "1.magnifyingglass", shortcut: "cmd+0", action: () => setZoom(1) },
    { id: "fit", label: "Zoom to Fit", shortcut: "cmd+9", action: zoomToFit },
    { label: "Zoom", submenu: zoomMenu() },
    "-",
    { id: "grid", label: "Show Pixel Grid", symbol: "grid", shortcut: "cmd+g", checked: state.view.grid, enabled: state.zoom >= 4, action: toggleGrid },
  ],
  help: () => [
    { id: "help", label: "Paint Help", symbol: "questionmark.circle", action: helpTopics },
    { id: "about", label: "About Paint", symbol: "info.circle", action: aboutPaint },
  ],
};

function zoomMenu() {
  return ZOOMS.map((z) => ({ id: `zoom-${z}`, label: `${z * 100}%`, checked: state.zoom === z, action: () => setZoom(z) }));
}

/** Shows a menu under `anchor` and runs the chosen item. */
async function popup(items, anchor) {
  finishTransient();
  const rect = anchor.getBoundingClientRect();
  const actions = new Map();
  const toSpec = (list) => list.map((item) => {
    if (item === "-") return "-";
    const spec = { label: item.label };
    if (item.id) { spec.id = item.id; actions.set(item.id, item.action); }
    for (const key of ["symbol", "shortcut", "checked", "enabled"]) if (item[key] !== undefined) spec[key] = item[key];
    if (item.submenu) spec.submenu = toSpec(item.submenu);
    return spec;
  });
  const specs = toSpec(items);
  anchor.classList.add("open");
  try {
    const chosen = japp ? await japp.menu.popup(specs, { x: rect.left, y: rect.bottom + 4 }) : await htmlMenu(specs, rect);
    actions.get(chosen)?.();
  } finally {
    anchor.classList.remove("open");
    refreshToolbar();
  }
}

/** A stand-in menu for running in a browser; JApp shows the real thing. */
let closeHtmlMenu = null;
function htmlMenu(specs, rect) {
  return new Promise((resolve) => {
    const flat = specs.flatMap((s) => (s !== "-" && s.submenu ? ["-", ...s.submenu] : [s]));
    const menu = h("div", { class: "menu", role: "menu" }, ...flat.map((s) => {
      if (s === "-") return h("div", { class: "sep" });
      const enabled = s.enabled !== false;
      return h("div", {
        class: `item${enabled ? "" : " disabled"}`, role: "menuitem",
        onpointerup: () => { if (enabled) finish(s.id ?? s.label); },
      }, h("span", { text: `${s.checked ? "✓ " : ""}${s.label}` }), h("span", { class: "short", text: s.shortcut ?? "" }));
    }));
    const host = $("#app").getBoundingClientRect();
    Object.assign(menu.style, { left: `${rect.left - host.left}px`, top: `${rect.bottom - host.top + 4}px` });
    $("#menu-layer").append(menu);
    const outside = (event) => { if (!menu.contains(event.target)) finish(null); };
    function finish(value) {
      menu.remove();
      document.removeEventListener("pointerdown", outside, true);
      closeHtmlMenu = null;
      resolve(value);
    }
    closeHtmlMenu = () => finish(null);
    setTimeout(() => document.addEventListener("pointerdown", outside, true));
  });
}

function closeMenus() { closeHtmlMenu?.(); }

const toolbarButtons = {};
function renderToolbar() {
  const bar = $("#toolbar");
  const button = (id, iconName, label, onclick, menu = false) => {
    const b = h("button", { type: "button", class: "tb", title: label, "aria-label": label, onclick }, icon(iconName, 19));
    if (menu) b.append(h("span", { class: "chev" }, icon("chevron", 10, 2)));
    toolbarButtons[id] = b;
    return b;
  };
  const menuButton = (id, iconName, label) => button(id, iconName, label, (e) => popup(MENUS[id](), e.currentTarget), true);
  bar.append(
    h("div", { class: "tgroup" }, menuButton("file", "file", "File")),
    h("div", { class: "tgroup" },
      button("undo", "undo", "Undo (⌘Z)", undo),
      button("redo", "redo", "Redo (⇧⌘Z)", redo)),
    h("div", { class: "tgroup" },
      button("cut", "cut", "Cut (⌘X)", cut),
      button("copy", "copy", "Copy (⌘C)", copy),
      button("paste", "paste", "Paste (⌘V)", pasteInternal)),
    h("div", { class: "tgroup" },
      menuButton("select", "select", "Selection"),
      menuButton("image", "image", "Image"),
      menuButton("view", "view", "View")),
    h("div", { class: "tgroup" }, menuButton("help", "help", "Help")));
  refreshToolbar();
}

function refreshToolbar() {
  if (!toolbarButtons.undo) return;
  toolbarButtons.undo.disabled = !(history.undo.length || textBox || polygon || curve);
  toolbarButtons.redo.disabled = !history.redo.length;
  toolbarButtons.cut.disabled = toolbarButtons.copy.disabled = !sel;
  toolbarButtons.paste.disabled = !clipboard;
}

// MARK: Sheets

let modal = null;

/** A sheet under the toolbar. Resolves to the clicked button's value, or null (Cancel, Esc). */
function dialog(title, body, buttons = [{ label: "Cancel", value: null }, { label: "OK", value: true, default: true }]) {
  closeMenus();
  return new Promise((resolve) => {
    const layer = $("#modal-layer");
    const finish = (value) => {
      layer.hidden = true;
      layer.replaceChildren();
      modal = null;
      resolve(value);
    };
    const valueOf = (b) => (typeof b.value === "function" ? b.value() : b.value);
    const sheet = h("div", { class: "sheet", role: "dialog", "aria-label": title },
      h("h2", { text: title }),
      h("div", { class: "sheet-body" }, body),
      h("div", { class: "buttons" }, ...buttons.map((b) => h("button", {
        type: "button", class: `button${b.default ? " default" : ""}`, onclick: () => finish(valueOf(b)),
      }, b.label))));
    layer.replaceChildren(sheet);
    layer.hidden = false;
    modal = { finish, defaultValue: () => { const d = buttons.find((b) => b.default); return d ? valueOf(d) : null; } };
    (sheet.querySelector("input, select") ?? sheet.querySelector(".default"))?.focus();
  });
}

/** A native alert (japp.dialog.message); resolves to the button index, the last one for Esc. */
async function messageBox(title, text, buttons = ["OK"], kind = "informational") {
  if (japp) {
    try { return await japp.dialog.message({ title, message: text, buttons, style: kind }); } catch { /* fall back to a sheet */ }
  }
  const value = await dialog(title, h("p", { text, style: "margin:0;color:var(--secondary)" }),
    buttons.map((label, index) => ({ label, value: index, default: index === 0 })).reverse());
  return value === null ? buttons.length - 1 : value;
}

function field(label, id, value, unit) {
  return [h("label", { for: id, text: label }), h("div", {}, h("input", { type: "number", id, value: String(value) }), h("span", { class: "unit", text: unit }))];
}
const numberValue = (id) => Number($(`#${id}`).value);

async function attributesDialog() {
  finishTransient();
  const body = h("div", { class: "form" }, ...field("Width", "attr-width", raster.width, "px"), ...field("Height", "attr-height", raster.height, "px"));
  const result = await dialog("Canvas Size", body, [
    { label: "Default", value: () => ({ w: DEFAULT_SIZE.width, h: DEFAULT_SIZE.height }) },
    { label: "Cancel", value: null },
    { label: "Resize", default: true, value: () => ({ w: numberValue("attr-width"), h: numberValue("attr-height") }) },
  ]);
  if (!result || !(result.w > 0) || !(result.h > 0)) return;
  state.defaultSize = { width: Math.round(result.w), height: Math.round(result.h) };
  dropSelection();
  if (result.w !== raster.width || result.h !== raster.height) resizePicture(Math.round(result.w), Math.round(result.h));
  saveSettings();
}

async function stretchSkewDialog() {
  const body = h("div", { class: "form" },
    ...field("Stretch horizontally", "stretch-h", 100, "%"), ...field("Stretch vertically", "stretch-v", 100, "%"),
    ...field("Skew horizontally", "skew-h", 0, "°"), ...field("Skew vertically", "skew-v", 0, "°"));
  const v = await dialog(sel ? "Stretch and Skew Selection" : "Stretch and Skew", body, [
    { label: "Cancel", value: null },
    { label: "Apply", default: true, value: () => ({ sh: numberValue("stretch-h"), sv: numberValue("stretch-v"), kh: numberValue("skew-h"), kv: numberValue("skew-v") }) },
  ]);
  if (!v) return;
  if (!(v.sh >= 1 && v.sh <= 500 && v.sv >= 1 && v.sv <= 500)) return messageBox("Stretch must be between 1% and 500%.", "", ["OK"], "warning");
  if (!(Math.abs(v.kh) <= 89 && Math.abs(v.kv) <= 89)) return messageBox("Skew must be between −89° and 89°.", "", ["OK"], "warning");
  const floating = Boolean(sel);
  transform((block, background) => {
    const bg = floating ? 0 : background;
    return skewBlock(skewBlock(stretchBlock(block, v.sh, v.sv), v.kh, true, bg), v.kv, false, bg);
  });
}

async function saveAsDialog() {
  let format = state.format;
  const choices = h("div", { class: "formats", role: "radiogroup" }, ...Object.entries(FORMATS).map(([value, [name, detail]]) =>
    h("button", { type: "button", "aria-pressed": String(value === format), "data-format": value, onclick: (e) => {
      format = value;
      for (const b of choices.children) b.setAttribute("aria-pressed", String(b.dataset.format === value));
      void e;
    } }, h("b", { text: name }), h("span", { text: detail }))));
  return dialog("Save As", choices, [{ label: "Cancel", value: null }, { label: "Save…", default: true, value: () => format }]);
}

function helpTopics() {
  const topics = [
    ["Drawing", "Pick a tool on the left and drag on the picture. The left button paints in the foreground color, the right button (or ⌃-click) in the background color."],
    ["Colors", "Click a swatch for the foreground, right-click for the background, double-click to change the swatch. X swaps the two colors, D resets them to black and white."],
    ["Shapes", "Hold Shift for squares, circles and lines at 45°. The panel under the tools sets the style (outline, fill) and the line width."],
    ["Curves and polygons", "Curve: drag a line, then click twice to bend it. Polygon: drag the first side, click each corner, double-click to close it."],
    ["Selections", "Drag a selection to move it; hold ⌥ to leave a copy. With a transparent background the background color becomes see-through."],
    ["Keys", "Tools: Q lasso, M select, E eraser, G fill, I pick color, Z zoom, P pencil, B brush, A airbrush, T text, L line, C curve, R rectangle, Y polygon, O ellipse, U rounded rectangle."],
  ];
  const body = h("div", { class: "help-text" }, ...topics.map(([title, text]) => h("div", {}, h("h3", { text: title }), h("p", { text }))));
  return dialog("Paint Help", body, [{ label: "Done", value: true, default: true }]);
}

function aboutPaint() {
  const runtime = japp?.runtimeVersion ? `JApp Runtime ${japp.runtimeVersion}` : "a web browser";
  const body = h("div", { class: "about" },
    h("img", { src: "assets/icon.png", alt: "" }),
    h("div", {},
      h("div", { class: "name", text: "Paint" }),
      h("p", { text: "Version 2.0 · the Windows 98 tool set, at home on a Mac" }),
      h("p", { text: `Picture ${raster.width} × ${raster.height} · runs on ${runtime}` })));
  return dialog("About Paint", body, [{ label: "OK", value: true, default: true }]);
}

// MARK: Keyboard

const isTyping = (target) => target instanceof HTMLTextAreaElement || target instanceof HTMLSelectElement
  || (target instanceof HTMLInputElement && !["radio", "checkbox", "color", "range"].includes(target.type));

function toggleFont(key) {
  state.font[key] = !state.font[key];
  syncFonts();
}

document.addEventListener("keydown", (event) => {
  if (modal) {
    if (event.key === "Escape") { event.preventDefault(); modal.finish(null); }
    else if (event.key === "Enter" && !(event.target instanceof HTMLButtonElement)) { event.preventDefault(); modal.finish(modal.defaultValue()); }
    return;
  }
  const mod = event.metaKey || event.ctrlKey;
  const key = event.key.toLowerCase();
  if (event.target === textBox?.element) {
    if (event.key === "Escape") { event.preventDefault(); commitText(); }
    else if (mod && ["b", "i", "u"].includes(key)) { event.preventDefault(); toggleFont({ b: "bold", i: "italic", u: "underline" }[key]); }
    return;
  }
  if (isTyping(event.target)) return;
  if (event.key === "Escape") {
    closeMenus();
    if (polygon) finishPolygon(); else cancelTransient();
    return;
  }
  if ((event.key === "Delete" || event.key === "Backspace") && sel) { event.preventDefault(); clearSelection(); return; }
  if (event.key.startsWith("Arrow") && sel && !mod) {
    event.preventDefault();
    liftSelection(false);
    const step = event.shiftKey ? 10 : 1;
    sel.x += event.key === "ArrowLeft" ? -step : event.key === "ArrowRight" ? step : 0;
    sel.y += event.key === "ArrowUp" ? -step : event.key === "ArrowDown" ? step : 0;
    drawOverlay();
    return;
  }
  if (!mod && !event.altKey) {
    const tool = TOOLS.find((t) => t.key.toLowerCase() === key);
    if (tool) { event.preventDefault(); selectTool(tool.id); return; }
    if (key === "x") { swapColors(); return; }
    if (key === "d") { state.primary = "#000000"; state.secondary = "#ffffff"; renderCurrentColors(); return; }
    return;
  }
  if (!mod) return;
  // ⌘W, ⌘Q, ⌘H and ⌘M stay with macOS; Paint's Ctrl+W (Stretch and Skew) still works.
  if (event.metaKey && ["w", "q", "h", "m"].includes(key)) return;
  if (key === "v") {
    // Let WebKit fire "paste" (it carries images from other apps); fall back to Paint's own clipboard.
    clearTimeout(pendingPaste);
    pendingPaste = setTimeout(() => { pendingPaste = null; pasteInternal(); }, 120);
    return;
  }
  if ((key === "c" || key === "x") && !sel) return;
  const actions = {
    n: event.shiftKey ? clearImage : newPicture, o: openPicture, s: () => save(event.shiftKey),
    z: event.shiftKey ? redo : undo, y: redo, x: cut, c: copy, a: selectAll,
    d: () => { finishTransient(); dropSelection(); },
    r: () => transform((b) => rotateBlock(b, event.shiftKey ? 270 : 90)),
    w: stretchSkewDialog, i: invertColors, e: attributesDialog,
    t: () => toggleView("toolbox"), l: () => toggleView("colorbox"), g: toggleGrid,
    "=": () => zoomStep(1), "+": () => zoomStep(1), "-": () => zoomStep(-1), "0": () => setZoom(1), "9": zoomToFit,
    pageup: () => setZoom(1), pagedown: () => setZoom(4),
  };
  const action = actions[key];
  if (!action) return;
  event.preventDefault();
  action();
  refreshToolbar();
});

// MARK: Settings

let saveTimer = null;
function saveSettings() {
  clearTimeout(saveTimer);
  saveTimer = setTimeout(() => {
    const settings = {
      palette: state.palette, view: state.view, brush: state.brush, eraser: state.eraser, airbrush: state.airbrush,
      lineWidth: state.lineWidth, fillStyle: state.fillStyle, format: state.format, defaultSize: state.defaultSize,
      font: state.font, magnifier: state.magnifier,
    };
    if (japp) japp.storage.set("settings", settings).catch(() => {});
    else try { localStorage.setItem("paint.settings", JSON.stringify(settings)); } catch { /* not kept */ }
  }, 300);
}

async function loadSettings() {
  let settings = null;
  try {
    settings = japp ? await japp.storage.get("settings", null) : JSON.parse(localStorage.getItem("paint.settings") ?? "null");
  } catch { settings = null; }
  if (!settings) return;
  if (Array.isArray(settings.palette) && settings.palette.length === 28 && settings.palette.every((c) => /^#[0-9a-f]{6}$/i.test(c))) state.palette = settings.palette;
  if (settings.view) Object.assign(state.view, settings.view);
  for (const key of ["brush", "eraser", "airbrush", "lineWidth", "fillStyle", "format", "magnifier"]) if (settings[key] !== undefined) state[key] = settings[key];
  if (settings.defaultSize?.width > 0 && settings.defaultSize?.height > 0) state.defaultSize = settings.defaultSize;
  if (settings.font) Object.assign(state.font, settings.font);
}

// MARK: Font controls

function syncFonts() {
  $("#font-family").value = state.font.family;
  $("#font-size").value = String(state.font.size);
  for (const [id, key] of [["font-bold", "bold"], ["font-italic", "italic"], ["font-underline", "underline"]]) $(`#${id}`).setAttribute("aria-pressed", String(state.font[key]));
  styleTextBox();
  saveSettings();
}

function setupFonts() {
  const family = $("#font-family"), size = $("#font-size");
  if (![...family.options].some((o) => o.value === state.font.family)) family.append(h("option", { text: state.font.family }));
  family.addEventListener("change", () => { state.font.family = family.value; syncFonts(); textBox?.element.focus(); });
  size.addEventListener("change", () => { state.font.size = Number(size.value); syncFonts(); textBox?.element.focus(); });
  for (const [id, key] of [["font-bold", "bold"], ["font-italic", "italic"], ["font-underline", "underline"]]) {
    $(`#${id}`).addEventListener("pointerdown", (event) => { event.preventDefault(); toggleFont(key); });
  }
  syncFonts();
}

// MARK: Start

async function start() {
  await loadSettings();
  renderToolbar();
  renderTools();
  renderOptions();
  renderPalette();
  setupColors();
  renderCurrentColors();
  setupStatus();
  setupFonts();
  raster.resize(state.defaultSize.width, state.defaultSize.height, Raster.WHITE);
  applySize();
  applyViews();
  updateTitle();
  prepareCursors();
}

// Hooks for the end-to-end test (Tests/E2E/paint.test.js).
window.paint = { state, raster, tools, selectTool, setZoom, undo, redo, copy, cut, pasteInternal, selectAll, clearSelection, invertColors, transform, flipBlock, rotateBlock, resizePicture, encodePicture, commitText, openTextBox, dropSelection, get selection() { return sel; }, history };

start();
