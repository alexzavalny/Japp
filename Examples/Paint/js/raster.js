// Pixel drawing on an ImageData without anti-aliasing, the way Paint drew in 1998.
//
// Colours are packed 32-bit values in the byte order of ImageData on little-endian
// machines (0xAABBGGRR). Every pixel of the picture stays fully opaque; alpha 0 is
// only used for the parts of a floating selection that are not selected.

export class Raster {
  constructor(width, height, fill = Raster.WHITE) {
    this.resize(width, height, fill);
  }

  static WHITE = 0xffffffff;

  resize(width, height, fill) {
    this.width = width;
    this.height = height;
    this.image = new ImageData(width, height);
    this.px = new Uint32Array(this.image.data.buffer);
    this.px.fill(fill);
  }

  /** "#rrggbb" → packed colour. */
  static pack(hex) {
    const n = parseInt(hex.slice(1), 16);
    return (0xff000000 | ((n & 0xff) << 16) | (n & 0xff00) | ((n >> 16) & 0xff)) >>> 0;
  }

  /** Packed colour → "#rrggbb". */
  static hex(c) {
    return "#" + [c & 0xff, (c >>> 8) & 0xff, (c >>> 16) & 0xff].map((v) => v.toString(16).padStart(2, "0")).join("");
  }

  inside(x, y) { return x >= 0 && y >= 0 && x < this.width && y < this.height; }
  get(x, y) { return this.inside(x, y) ? this.px[y * this.width + x] : 0; }
  set(x, y, c) { if (this.inside(x, y)) this.px[y * this.width + x] = c; }

  snapshot() { return { width: this.width, height: this.height, px: this.px.slice() }; }
  restore(snap) {
    if (snap.width !== this.width || snap.height !== this.height) this.resize(snap.width, snap.height, 0);
    this.px.set(snap.px);
  }

  fillRect(x0, y0, x1, y1, c) {
    const ax = Math.max(0, Math.min(x0, x1)), bx = Math.min(this.width - 1, Math.max(x0, x1));
    const ay = Math.max(0, Math.min(y0, y1)), by = Math.min(this.height - 1, Math.max(y0, y1));
    for (let y = ay; y <= by; y++) this.px.fill(c, y * this.width + ax, y * this.width + bx + 1);
  }

  /** A pen dot: a disk (round) or a square of `size` pixels centred on x, y. */
  dot(x, y, size, c, round = true) {
    if (size <= 1) return this.set(x, y, c);
    const half = (size - 1) / 2, limit = (size / 2) ** 2 + 0.3;
    for (let j = 0; j < size; j++) {
      for (let i = 0; i < size; i++) {
        const ox = i - half, oy = j - half;
        if (round && ox * ox + oy * oy > limit) continue;
        this.set(Math.round(x + ox), Math.round(y + oy), c);
      }
    }
  }

  /** Paint's brush shapes: circle, square, slash, backslash in three sizes. */
  brush(x, y, shape, size, c) {
    if (shape === "circle") return this.dot(x, y, size, c, true);
    if (shape === "square") return this.dot(x, y, size, c, false);
    const h = Math.floor(size / 2);
    for (let i = 0; i < size; i++) {
      if (shape === "slash") this.set(x - h + i, y + h - i, c);
      else this.set(x - h + i, y - h + i, c);
    }
  }

  /** Bresenham: calls plot(x, y) for every pixel from (x0, y0) to (x1, y1). */
  static walk(x0, y0, x1, y1, plot) {
    const dx = Math.abs(x1 - x0), dy = -Math.abs(y1 - y0);
    const sx = x0 < x1 ? 1 : -1, sy = y0 < y1 ? 1 : -1;
    let err = dx + dy;
    for (;;) {
      plot(x0, y0);
      if (x0 === x1 && y0 === y1) break;
      const e2 = 2 * err;
      if (e2 >= dy) { err += dy; x0 += sx; }
      if (e2 <= dx) { err += dx; y0 += sy; }
    }
  }

  line(x0, y0, x1, y1, c, width = 1) {
    Raster.walk(x0, y0, x1, y1, (x, y) => this.dot(x, y, width, c, true));
  }

  /** Connects integer points with pen dots; `closed` joins the last to the first. */
  polyline(points, c, width = 1, closed = false) {
    if (points.length === 1) return this.dot(points[0][0], points[0][1], width, c);
    for (let i = 1; i < points.length; i++) this.line(points[i - 1][0], points[i - 1][1], points[i][0], points[i][1], c, width);
    if (closed && points.length > 2) {
      const a = points[points.length - 1], b = points[0];
      this.line(a[0], a[1], b[0], b[1], c, width);
    }
  }

  /** Rectangle inside the box x0..x1, y0..y1 (inclusive); the border grows inward. */
  rect(x0, y0, x1, y1, stroke, fill, width = 1) {
    const ax = Math.min(x0, x1), bx = Math.max(x0, x1), ay = Math.min(y0, y1), by = Math.max(y0, y1);
    if (fill !== null) this.fillRect(ax, ay, bx, by, fill);
    if (stroke === null) return;
    for (let i = 0; i < width; i++) {
      if (ax + i > bx - i || ay + i > by - i) break;
      this.fillRect(ax + i, ay + i, bx - i, ay + i, stroke);
      this.fillRect(ax + i, by - i, bx - i, by - i, stroke);
      this.fillRect(ax + i, ay + i, ax + i, by - i, stroke);
      this.fillRect(bx - i, ay + i, bx - i, by - i, stroke);
    }
  }

  /** Points on an ellipse filling the box, `inset` pixels in (for thick borders). */
  static ellipsePoints(x0, y0, x1, y1, inset = 0) {
    const ax = Math.min(x0, x1), bx = Math.max(x0, x1), ay = Math.min(y0, y1), by = Math.max(y0, y1);
    const cx = (ax + bx) / 2, cy = (ay + by) / 2;
    const rx = Math.max(0, (bx - ax) / 2 - inset), ry = Math.max(0, (by - ay) / 2 - inset);
    const steps = Math.max(12, Math.ceil(Math.PI * (rx + ry) * 1.5));
    const points = [];
    for (let i = 0; i < steps; i++) {
      const t = (i / steps) * Math.PI * 2;
      const p = [Math.round(cx + rx * Math.cos(t)), Math.round(cy + ry * Math.sin(t))];
      const last = points[points.length - 1];
      if (!last || last[0] !== p[0] || last[1] !== p[1]) points.push(p);
    }
    return points;
  }

  ellipse(x0, y0, x1, y1, stroke, fill, width = 1) {
    if (fill !== null) {
      const ax = Math.min(x0, x1), bx = Math.max(x0, x1), ay = Math.min(y0, y1), by = Math.max(y0, y1);
      const cx = (ax + bx + 1) / 2, cy = (ay + by + 1) / 2, rx = (bx - ax + 1) / 2, ry = (by - ay + 1) / 2;
      this.fillPath((ctx) => ctx.ellipse(cx, cy, rx, ry, 0, 0, Math.PI * 2), fill);
    }
    if (stroke !== null) this.polyline(Raster.ellipsePoints(x0, y0, x1, y1, (width - 1) / 2), stroke, width, true);
  }

  static roundRectPoints(x0, y0, x1, y1, inset = 0) {
    const ax = Math.min(x0, x1) + inset, bx = Math.max(x0, x1) - inset;
    const ay = Math.min(y0, y1) + inset, by = Math.max(y0, y1) - inset;
    const r = Math.max(0, Math.min(8, (bx - ax) / 2, (by - ay) / 2));
    const corners = [[bx - r, ay + r, -Math.PI / 2], [bx - r, by - r, 0], [ax + r, by - r, Math.PI / 2], [ax + r, ay + r, Math.PI]];
    const points = [];
    for (const [cx, cy, start] of corners) {
      for (let i = 0; i <= 8; i++) {
        const t = start + (i / 8) * (Math.PI / 2);
        points.push([Math.round(cx + r * Math.cos(t)), Math.round(cy + r * Math.sin(t))]);
      }
    }
    return points;
  }

  roundRect(x0, y0, x1, y1, stroke, fill, width = 1) {
    if (fill !== null) {
      const ax = Math.min(x0, x1), bx = Math.max(x0, x1), ay = Math.min(y0, y1), by = Math.max(y0, y1);
      const r = Math.max(0, Math.min(8.5, (bx - ax + 1) / 2, (by - ay + 1) / 2));
      this.fillPath((ctx) => ctx.roundRect(ax, ay, bx - ax + 1, by - ay + 1, r), fill);
    }
    if (stroke !== null) this.polyline(Raster.roundRectPoints(x0, y0, x1, y1, (width - 1) / 2), stroke, width, true);
  }

  polygon(points, stroke, fill, width = 1) {
    if (fill !== null && points.length > 2) {
      this.fillPath((ctx) => {
        ctx.moveTo(points[0][0] + 0.5, points[0][1] + 0.5);
        for (const [x, y] of points.slice(1)) ctx.lineTo(x + 0.5, y + 0.5);
        ctx.closePath();
      }, fill);
    }
    if (stroke !== null) this.polyline(points, stroke, width, true);
  }

  /**
   * Fills a canvas path without anti-aliasing: the path is filled on a scratch
   * canvas and every pixel at least half covered takes the colour.
   */
  fillPath(build, c) {
    this.fillMask(Raster.coverage(this.width, this.height, build), c);
  }

  fillMask(mask, c) {
    for (let i = 0; i < mask.length; i++) if (mask[i]) this.px[i] = c;
  }

  /** 1 for every pixel of a width×height area at least half covered by the path. */
  static coverage(width, height, build) {
    return Raster.mask(width, height, (ctx) => {
      ctx.beginPath();
      build(ctx);
      ctx.fillStyle = "#000";
      ctx.fill();
    });
  }

  /** 1 for every pixel at least half covered by whatever `draw` paints (paths, text). */
  static mask(width, height, draw) {
    const canvas = Raster.scratch(width, height);
    const ctx = canvas.getContext("2d", { willReadFrequently: true });
    ctx.setTransform(1, 0, 0, 1, 0, 0);
    ctx.clearRect(0, 0, width, height);
    ctx.save();
    draw(ctx);
    ctx.restore();
    const alpha = ctx.getImageData(0, 0, width, height).data;
    const mask = new Uint8Array(width * height);
    for (let i = 0; i < mask.length; i++) mask[i] = alpha[i * 4 + 3] >= 128 ? 1 : 0;
    return mask;
  }

  static scratch(width, height) {
    Raster._scratch ??= document.createElement("canvas");
    if (Raster._scratch.width !== width) Raster._scratch.width = width;
    if (Raster._scratch.height !== height) Raster._scratch.height = height;
    return Raster._scratch;
  }

  /** Flood fill of the 4-connected area that has the colour at (x, y). */
  floodFill(x, y, c) {
    if (!this.inside(x, y)) return false;
    const { width, height, px } = this;
    const target = px[y * width + x];
    if (target === c) return false;
    const stack = [[x, y]];
    while (stack.length) {
      let [sx, sy] = stack.pop();
      let i = sy * width + sx;
      while (sx > 0 && px[i - 1] === target) { sx--; i--; }
      let up = false, down = false;
      for (; sx < width && px[i] === target; sx++, i++) {
        px[i] = c;
        if (sy > 0) {
          const t = px[i - width] === target;
          if (t && !up) stack.push([sx, sy - 1]);
          up = t;
        }
        if (sy < height - 1) {
          const t = px[i + width] === target;
          if (t && !down) stack.push([sx, sy + 1]);
          down = t;
        }
      }
    }
    return true;
  }

  /** One burst of the airbrush: random pixels inside a disk of the given diameter. */
  spray(x, y, diameter, c, random = Math.random) {
    const r = diameter / 2, count = Math.max(4, Math.round(diameter * 0.9));
    for (let n = 0; n < count; n++) {
      const a = random() * Math.PI * 2, d = Math.sqrt(random()) * r;
      this.set(Math.round(x + Math.cos(a) * d), Math.round(y + Math.sin(a) * d), c);
    }
  }

  /** Copies a block out (pixels where mask is 0 get alpha 0). */
  extract(x, y, w, h, mask = null) {
    const out = new ImageData(w, h), dst = new Uint32Array(out.data.buffer);
    for (let j = 0; j < h; j++) {
      for (let i = 0; i < w; i++) {
        if (mask && !mask[j * w + i]) continue;
        dst[j * w + i] = this.get(x + i, y + j);
      }
    }
    return out;
  }

  /** Stamps a block in; `transparent` (a packed colour) is skipped, as are alpha-0 pixels. */
  stamp(block, x, y, transparent = null) {
    const src = new Uint32Array(block.data.buffer);
    for (let j = 0; j < block.height; j++) {
      for (let i = 0; i < block.width; i++) {
        const c = src[j * block.width + i];
        if ((c >>> 24) === 0 || c === transparent) continue;
        this.set(x + i, y + j, c);
      }
    }
  }

  /** Fills the selected part of a block area with a colour. */
  clearArea(x, y, w, h, c, mask = null) {
    for (let j = 0; j < h; j++) {
      for (let i = 0; i < w; i++) if (!mask || mask[j * w + i]) this.set(x + i, y + j, c);
    }
  }
}

// MARK: block transforms (selections and the whole picture)

const view = (block) => new Uint32Array(block.data.buffer);

export function flipBlock(block, horizontal) {
  const { width: w, height: h } = block, out = new ImageData(w, h), s = view(block), d = view(out);
  for (let y = 0; y < h; y++) {
    for (let x = 0; x < w; x++) d[y * w + x] = horizontal ? s[y * w + (w - 1 - x)] : s[(h - 1 - y) * w + x];
  }
  return out;
}

export function rotateBlock(block, degrees) {
  const { width: w, height: h } = block, s = view(block);
  if (degrees === 180) {
    const out = new ImageData(w, h), d = view(out);
    for (let i = 0; i < w * h; i++) d[i] = s[w * h - 1 - i];
    return out;
  }
  const out = new ImageData(h, w), d = view(out);
  for (let y = 0; y < h; y++) {
    for (let x = 0; x < w; x++) {
      if (degrees === 90) d[x * h + (h - 1 - y)] = s[y * w + x];
      else d[(w - 1 - x) * h + y] = s[y * w + x];
    }
  }
  return out;
}

/** Nearest-neighbour stretch to percentages of the current size. */
export function stretchBlock(block, xPercent, yPercent) {
  const sw = block.width, sh = block.height, s = view(block);
  const w = Math.max(1, Math.round((sw * xPercent) / 100)), h = Math.max(1, Math.round((sh * yPercent) / 100));
  const out = new ImageData(w, h), d = view(out);
  for (let y = 0; y < h; y++) {
    const row = Math.min(sh - 1, Math.floor((y * sh) / h)) * sw;
    for (let x = 0; x < w; x++) d[y * w + x] = s[row + Math.min(sw - 1, Math.floor((x * sw) / w))];
  }
  return out;
}

/** Shears rows (horizontal) or columns by an angle; the uncovered corners get `background`. */
export function skewBlock(block, degrees, horizontal, background) {
  if (!degrees) return block;
  const t = Math.tan((degrees * Math.PI) / 180), sw = block.width, sh = block.height, s = view(block);
  const extra = Math.round(Math.abs(t) * ((horizontal ? sh : sw) - 1));
  const w = horizontal ? sw + extra : sw, h = horizontal ? sh : sh + extra;
  const out = new ImageData(w, h), d = view(out);
  d.fill(background);
  for (let y = 0; y < sh; y++) {
    for (let x = 0; x < sw; x++) {
      const along = horizontal ? y : x, length = horizontal ? sh : sw;
      const offset = t >= 0 ? Math.round(t * (length - 1 - along)) : Math.round(-t * along);
      const dx = horizontal ? x + offset : x, dy = horizontal ? y : y + offset;
      d[dy * w + dx] = s[y * sw + x];
    }
  }
  return out;
}

export function invertBlock(block) {
  const out = new ImageData(new Uint8ClampedArray(block.data), block.width, block.height), d = view(out);
  for (let i = 0; i < d.length; i++) if (d[i] >>> 24) d[i] = (d[i] ^ 0x00ffffff) >>> 0;
  return out;
}

/** 24-bit Windows bitmap, the format Paint saved by default. */
export function encodeBMP(raster) {
  const { width: w, height: h, px } = raster, row = Math.ceil((w * 3) / 4) * 4, size = 54 + row * h;
  const bytes = new Uint8Array(size), v = new DataView(bytes.buffer);
  bytes[0] = 0x42; bytes[1] = 0x4d;
  v.setUint32(2, size, true);
  v.setUint32(10, 54, true);
  v.setUint32(14, 40, true);
  v.setInt32(18, w, true);
  v.setInt32(22, h, true);
  v.setUint16(26, 1, true);
  v.setUint16(28, 24, true);
  v.setUint32(34, row * h, true);
  v.setInt32(38, 2835, true);
  v.setInt32(42, 2835, true);
  for (let y = 0; y < h; y++) {
    let o = 54 + (h - 1 - y) * row;
    for (let x = 0; x < w; x++) {
      const c = px[y * w + x];
      bytes[o++] = (c >>> 16) & 0xff;
      bytes[o++] = (c >>> 8) & 0xff;
      bytes[o++] = c & 0xff;
    }
  }
  return bytes;
}
