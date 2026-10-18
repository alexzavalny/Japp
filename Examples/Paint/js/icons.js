// Line icons in the spirit of SF Symbols (24×24, round strokes), and the cursors made from them.

const icons = {
  // Tools
  freeselect: `<path d="M12 4.5c4.7 0 8.5 2.2 8.5 5.2s-3.8 5.2-8.5 5.2-8.5-2.3-8.5-5.2 3.8-5.2 8.5-5.2z" stroke-dasharray="2.6 2.4"/><path d="M6.6 13.6c-1.3 1-1.6 2.8-.4 3.6 1.1.8 2.6.2 2.9-1 .3-1.3-1-2.1-2-1.5"/><path d="M8.2 17.4 7.2 21"/>`,
  select: `<rect x="3.5" y="5" width="17" height="14" rx="1.5" stroke-dasharray="2.8 2.4"/>`,
  eraser: `<path d="M8 20h12"/><path d="M4.4 14.4 13.6 5.2a2 2 0 0 1 2.8 0l3.4 3.4a2 2 0 0 1 0 2.8L11.2 20H8.4l-4-4a1.1 1.1 0 0 1 0-1.6z"/><path d="m9 9.6 5.4 5.4"/>`,
  fill: `<path d="m18 11.5-7.5-7.5-7 7a2 2 0 0 0 0 2.8l4.7 4.7a2 2 0 0 0 2.8 0z"/><path d="M5.5 2.5 9 6"/><path d="M3 12.5h14.5"/><path d="M21.5 18.6a1.8 1.8 0 1 1-3.6 0c0-1.4 1.8-2.6 1.8-3.8 0 1.2 1.8 2.4 1.8 3.8z"/>`,
  pick: `<path d="m3 21 1.2-1.2h2.6L15 11.6"/><path d="M4.2 19.8v-2.6l8.2-8.2"/><path d="m14.6 6.2 3-3a2 2 0 0 1 2.9 2.9l-3 3 .5.5a1.6 1.6 0 0 1-2.3 2.3l-4.4-4.4a1.6 1.6 0 0 1 2.3-2.3z"/>`,
  magnifier: `<circle cx="10.5" cy="10.5" r="6.5"/><path d="m20 20-4.9-4.9"/><path d="M10.5 7.8v5.4M7.8 10.5h5.4"/>`,
  pencil: `<path d="M17.2 3.4a2.5 2.5 0 0 1 3.5 3.5L8 19.6l-4.6 1.2 1.2-4.6z"/><path d="m15 5.6 3.5 3.5"/>`,
  brush: `<path d="m9.6 12.3 8.2-8.2a2.6 2.6 0 0 1 3.7 3.7l-8.2 8.2"/><path d="M7.2 14.6c-1.7 0-3 1.4-3 3.1 0 1.3-1.9 1.7-1.6 2.2 1 1.1 2.7 1.8 4.2 1.8 2.3 0 4-1.8 4-4.1a3.1 3.1 0 0 0-3.6-3z"/>`,
  airbrush: `<rect x="9.5" y="9.5" width="8" height="11.5" rx="2"/><path d="M11.5 9.5V7h4v2.5"/><path d="M15.5 7H18"/><path d="M3.5 5h.01M6.2 7.6h.01M3.5 10.2h.01M6.4 3h.01M3.4 14h.01M6.7 12.4h.01" stroke-width="2.2"/>`,
  text: `<path d="M5.5 19.5 12 4.5l6.5 15"/><path d="M8.2 13.5h7.6"/>`,
  line: `<path d="M5.5 18.5 18.5 5.5"/><circle cx="5" cy="19" r="1.6" fill="currentColor" stroke="none"/><circle cx="19" cy="5" r="1.6" fill="currentColor" stroke="none"/>`,
  curve: `<path d="M3.5 19.5C6 6 10.5 21 14 11.5S18.5 4.5 20.5 4.5"/>`,
  rect: `<rect x="3.5" y="6" width="17" height="12" rx="1"/>`,
  polygon: `<path d="m12 3.6 8.6 6.2-3.3 10H6.7L3.4 9.8z"/>`,
  ellipse: `<ellipse cx="12" cy="12" rx="9" ry="6.5"/>`,
  roundrect: `<rect x="3.5" y="6" width="17" height="12" rx="4.5"/>`,
  // Toolbar and bars
  file: `<path d="M14 3H7a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V8z"/><path d="M14 3v5h5"/>`,
  undo: `<path d="M9 14 4 9l5-5"/><path d="M4 9h10.5a5.5 5.5 0 0 1 0 11H11"/>`,
  redo: `<path d="m15 14 5-5-5-5"/><path d="M20 9H9.5a5.5 5.5 0 0 0 0 11H13"/>`,
  cut: `<circle cx="6" cy="6.5" r="2.6"/><circle cx="6" cy="17.5" r="2.6"/><path d="M19.5 4.5 8.2 15.8M14.4 14.4 19.5 19.5M8.2 8.2l3.4 3.4"/>`,
  copy: `<rect x="8.5" y="8.5" width="12" height="12" rx="2"/><path d="M5.5 15.5h-.5a1.5 1.5 0 0 1-1.5-1.5V5a1.5 1.5 0 0 1 1.5-1.5h9A1.5 1.5 0 0 1 15.5 5v.5"/>`,
  paste: `<rect x="8.5" y="2.5" width="7" height="4" rx="1"/><path d="M15.5 4.5h2a2 2 0 0 1 2 2V19a2 2 0 0 1-2 2h-11a2 2 0 0 1-2-2V6.5a2 2 0 0 1 2-2h2"/>`,
  image: `<rect x="3.5" y="4.5" width="17" height="15" rx="2.5"/><circle cx="9" cy="9.5" r="1.8"/><path d="m20.5 15.5-4-4-9.5 8"/>`,
  view: `<rect x="3.5" y="4.5" width="17" height="15" rx="2.5"/><path d="M9 4.5v15"/><path d="M5.6 8h1.4M5.6 10.5h1.4M5.6 13h1.4"/>`,
  help: `<circle cx="12" cy="12" r="9"/><path d="M9.4 9.2a2.7 2.7 0 0 1 5.2.9c0 1.8-2.6 2.4-2.6 4"/><path d="M12 17.2h.01" stroke-width="2.2"/>`,
  swap: `<path d="M5 8.5h13.5l-3.5-3.5"/><path d="M19 15.5H5.5l3.5 3.5"/>`,
  minus: `<path d="M6 12h12"/>`,
  plus: `<path d="M12 6v12M6 12h12"/>`,
  pointer: `<path d="m5 4 5.2 15 2.1-6.2L18.5 10.7z"/>`,
  size: `<rect x="4" y="4" width="16" height="16" rx="2" stroke-dasharray="2.6 2.2"/>`,
  canvas: `<rect x="4.5" y="5.5" width="15" height="13" rx="1.5"/><path d="M4.5 9h15"/>`,
  chevron: `<path d="m7 10 5 5 5-5"/>`,
};

/** The icon as an inline SVG string (it inherits the text colour). */
export function svg(name, size = 20, strokeWidth = 1.6) {
  return `<svg xmlns="http://www.w3.org/2000/svg" width="${size}" height="${size}" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="${strokeWidth}" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${icons[name]}</svg>`;
}

/** The icon as a DOM node. */
export function icon(name, size = 20, strokeWidth = 1.6) {
  const holder = document.createElement("span");
  holder.className = "icon";
  holder.innerHTML = svg(name, size, strokeWidth);
  return holder;
}

function cursorSVG(name) {
  const body = icons[name];
  return `<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" stroke-linecap="round" stroke-linejoin="round">`
    + `<g stroke="#fff" stroke-width="4.2">${body}</g><g stroke="#000" stroke-width="1.7">${body}</g></svg>`;
}

/** A cursor made from a tool icon (black with a white halo): { fallback, set } CSS values. */
export async function toolCursor(name, hotX, hotY) {
  const image = new Image();
  image.src = "data:image/svg+xml;charset=utf-8," + encodeURIComponent(cursorSVG(name));
  await image.decode();
  const make = (scale) => {
    const canvas = document.createElement("canvas");
    canvas.width = canvas.height = 24 * scale;
    canvas.getContext("2d").drawImage(image, 0, 0, 24 * scale, 24 * scale);
    return canvas.toDataURL("image/png");
  };
  const x1 = make(1);
  return {
    fallback: `url("${x1}") ${hotX} ${hotY}, crosshair`,
    set: `-webkit-image-set(url("${x1}") 1x, url("${make(2)}") 2x) ${hotX} ${hotY}, crosshair`,
  };
}

/** A circle (or square) outline as large as the eraser on screen: { fallback, set } CSS values. */
export function squareCursor(size) {
  const s = Math.max(6, Math.min(64, Math.round(size)));
  const make = (scale) => {
    const canvas = document.createElement("canvas");
    canvas.width = canvas.height = (s + 2) * scale;
    const ctx = canvas.getContext("2d");
    ctx.lineWidth = scale;
    ctx.strokeStyle = "#fff";
    ctx.strokeRect(scale / 2, scale / 2, (s + 1) * scale, (s + 1) * scale);
    ctx.strokeStyle = "#000";
    ctx.strokeRect(scale * 1.5, scale * 1.5, (s - 1) * scale, (s - 1) * scale);
    return canvas.toDataURL("image/png");
  };
  const hot = Math.floor((s + 2) / 2), x1 = make(1);
  return {
    fallback: `url("${x1}") ${hot} ${hot}, crosshair`,
    set: `-webkit-image-set(url("${x1}") 1x, url("${make(2)}") 2x) ${hot} ${hot}, crosshair`,
  };
}
