// Drives Examples/Paint through synthetic pointer events and its window.paint hooks,
// then reads pixels back. Run by Scripts/e2e-test.sh with -JAppAutomationMenuChoice "Invert Colors".
const P = window.paint;
const stage = document.getElementById("stage");
const at = (x, y) => {
  const r = stage.getBoundingClientRect();
  return { clientX: r.left + (x + 0.5) * P.state.zoom, clientY: r.top + (y + 0.5) * P.state.zoom };
};
const fire = (type, [x, y], o = {}) => stage.dispatchEvent(new PointerEvent(type, {
  bubbles: true, pointerId: 1, button: o.button ?? 0, buttons: o.button === 2 ? 2 : 1,
  shiftKey: !!o.shift, altKey: !!o.alt, detail: o.detail ?? 1, ...at(x, y),
}));
const drag = (points, o) => {
  fire("pointerdown", points[0], o);
  for (const p of points.slice(1)) fire("pointermove", p, o);
  fire("pointerup", points[points.length - 1], o);
};
const color = (x, y) => {
  const c = P.raster.get(x, y);
  return "#" + [c & 255, (c >>> 8) & 255, (c >>> 16) & 255].map((v) => v.toString(16).padStart(2, "0")).join("");
};
const out = {};

P.selectTool("pencil");
drag([[10, 10], [20, 10]]);
out.pencil = [color(10, 10), color(15, 10), color(20, 10), color(15, 11)];
P.state.secondary = "#ff0000";
drag([[10, 20], [20, 20]], { button: 2 });
out.rightButton = color(15, 20);
P.state.secondary = "#ffffff";

P.selectTool("rect");
drag([[30, 30], [50, 45]]);
out.rect = [color(30, 30), color(50, 45), color(40, 30), color(40, 38)];
P.state.primary = "#0000ff";
P.selectTool("fill");
drag([[40, 38]]);
out.fill = [color(40, 38), color(31, 31), color(60, 60)];
P.undo();
out.undo = color(40, 38);
P.redo();
out.redo = color(40, 38);

P.state.primary = "#000000";
P.state.secondary = "#00ff00";
P.state.fillStyle = "both";
P.selectTool("ellipse");
drag([[100, 100], [140, 130]]);
out.ellipse = [color(120, 115), color(100, 115), color(98, 115)];
P.state.fillStyle = "outline";
P.state.secondary = "#ffffff";

P.selectTool("line");
drag([[200, 200], [260, 203]], { shift: true });
out.line = [color(200, 200), color(230, 200), color(260, 200)];

P.selectTool("select");
drag([[29, 29], [51, 46]]);
out.selection = P.selection && [P.selection.w, P.selection.h];
drag([[40, 40], [340, 40]]);
P.dropSelection();
out.moved = [color(330, 30), color(30, 30)];

P.selectTool("select");
drag([[329, 29], [351, 46]]);
P.copy();
P.pasteInternal();
out.pasted = Boolean(P.selection && P.selection.floating);
P.dropSelection();

P.invertColors();
out.invert = color(0, 0);
P.invertColors();
const before = color(10, 10);
P.transform((b) => P.flipBlock(b, true));
out.flip = color(P.raster.width - 1 - 10, 10) === before;
P.undo();
P.transform((b) => P.rotateBlock(b, 90));
out.rotate = [P.raster.width, P.raster.height];
P.undo();
out.sizeAfterUndo = [P.raster.width, P.raster.height];
P.resizePicture(300, 200);
out.resize = [P.raster.width, P.raster.height];
P.undo();

P.selectTool("text");
P.openTextBox({ x: 400, y: 300, w: 200, h: 40 });
document.querySelector(".textbox").value = "Hello 98";
P.commitText();
let ink = 0, gray = 0;
for (let y = 300; y < 340; y++) {
  for (let x = 400; x < 600; x++) {
    const c = color(x, y);
    if (c === "#000000") ink++;
    else if (c !== "#ffffff") gray++;
  }
}
out.text = { ink: ink > 40, antialiased: gray > 0 };

const bmp = atob(P.encodePicture("bmp").slice(0, 80));
out.bmp = [bmp.slice(0, 2), bmp.charCodeAt(28), bmp.charCodeAt(18) | (bmp.charCodeAt(19) << 8)];
out.png = P.encodePicture("png").startsWith("iVBOR");

P.setZoom(6);
out.zoom = document.getElementById("image").style.width;
P.setZoom(1);

// The Image menu is a real macOS menu (japp.menu.popup); the e2e run picks "Invert Colors".
const whiteBefore = color(5, 470);
document.querySelector('.tb[aria-label="Image"]').click();
await new Promise((resolve) => setTimeout(resolve, 800));
out.menuAction = [whiteBefore, color(5, 470)];
P.undo();
out.toolbar = [...document.querySelectorAll(".tb")].map((b) => b.getAttribute("aria-label") + (b.disabled ? " (off)" : ""));

out.tools = document.querySelectorAll(".tool").length;
out.palette = document.querySelectorAll("#palette .swatch").length;
out.title = [document.getElementById("doc-name").textContent, document.title];
out.windowZoom = typeof japp.window.zoom;
return out;
