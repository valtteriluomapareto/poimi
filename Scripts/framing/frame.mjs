//
//  frame.mjs — composite a raw App Store screenshot into a real device frame, on a branded
//  background with an Inter hero headline, at the exact App Store size (#230).
//
//  Device bezels from fastlane/frameit-frames (frames/) + their screen rects; the headline is Inter
//  ExtraBold via libvips text + a fontfile (no system install). Output: an opaque PNG at the accepted
//  App Store resolution. Parameterized per device (iPhone 6.9" + iPad 13").
//
//  Library:  import { frame } from './frame.mjs'; await frame({ rawPath, out, line1, line2, device })
//  CLI:      node frame.mjs <raw.png> <out.png> "<line 1>" "<line 2>" [device]
//
import sharp from 'sharp';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const DIR = path.dirname(fileURLToPath(import.meta.url));
const FONT = path.join(DIR, 'fonts/Inter.ttf');
const INK = '#1C1C1E';
const ACCENT = '#D08A2A';

// A minimal fontconfig so libvips finds our font dir + stops warning about a missing default config.
const FC = path.join(os.tmpdir(), 'poimi-fonts.conf');
try {
	fs.writeFileSync(
		FC,
		`<?xml version="1.0"?><!DOCTYPE fontconfig SYSTEM "fonts.dtd"><fontconfig><dir>${path.join(DIR, 'fonts')}</dir><cachedir>${path.join(os.tmpdir(), 'poimi-fc-cache')}</cachedir></fontconfig>`,
	);
	process.env.FONTCONFIG_FILE = FC;
} catch {
	/* non-fatal */
}

// Per-device: bezel + its screen rect (from frameit-frames offsets.json), output canvas (the exact
// accepted App Store size), and layout. `frames/*` fetched by fetch-assets.sh.
const DEVICES = {
	iphone69: {
		frame: 'frames/iphone-17-pro-max.png', fw: 1470, fh: 3000, screen: { x: 75, y: 66, w: 1320, h: 2868 },
		canvas: { w: 1320, h: 2868 }, deviceW: 1012, deviceY: 566, screenR: 152, shadowRF: 0.155,
		titleMaxW: 1170, titleTop: 178,
	},
	ipad13: {
		frame: 'frames/ipad-pro-13.png', fw: 2245, fh: 2930, screen: { x: 96, y: 102, w: 2048, h: 2732 },
		canvas: { w: 2064, h: 2752 }, deviceW: 1680, deviceY: 496, screenR: 42, shadowRF: 0.035,
		titleMaxW: 1560, titleTop: 150,
	},
};

const roundRect = (w, h, r, fill) =>
	Buffer.from(`<svg width="${w}" height="${h}"><rect width="${w}" height="${h}" rx="${r}" ry="${r}" fill="${fill}"/></svg>`);
const escapeXml = (s) => String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');

/** Render the (1–2 line) headline as ONE centered Inter ExtraBold block, trimmed to content. A single
 *  pango render gives natural line spacing (no cramped manual line stacking). */
async function renderHeadline(line1, line2) {
	const text = [line1, line2].filter(Boolean).map(escapeXml).join('\n');
	if (!text) return null;
	const raw = await sharp({
		text: {
			text: `<span weight="800" foreground="${INK}">${text}</span>`,
			font: 'Inter 100', fontfile: FONT, rgba: true, dpi: 72,
			align: 'centre', width: 4000, spacing: 12,
		},
	}).png().toBuffer();
	const trimmed = await sharp(raw).trim().toBuffer();
	const m = await sharp(trimmed).metadata();
	return { buf: trimmed, w: m.width, h: m.height };
}

/** Frame one screenshot → an opaque App-Store-sized PNG. */
export async function frame({ rawPath, out, line1 = '', line2 = '', device = 'iphone69' }) {
	const d = DEVICES[device];
	if (!d) throw new Error(`unknown device '${device}' (have: ${Object.keys(DEVICES).join(', ')})`);
	const framePng = path.join(DIR, d.frame);
	if (!fs.existsSync(framePng)) throw new Error(`missing bezel ${framePng} — run Scripts/framing/fetch-assets.sh`);
	if (!fs.existsSync(FONT)) throw new Error(`missing font ${FONT} — run Scripts/framing/fetch-assets.sh`);

	// 1. Framed device: rounded screenshot into the cutout, bezel on top.
	const screenshot = await sharp(
		await sharp(rawPath).resize(d.screen.w, d.screen.h, { fit: 'fill' }).toBuffer(),
	)
		.composite([{ input: roundRect(d.screen.w, d.screen.h, d.screenR, '#fff'), blend: 'dest-in' }])
		.png().toBuffer();
	const framed = await sharp({ create: { width: d.fw, height: d.fh, channels: 4, background: { r: 0, g: 0, b: 0, alpha: 0 } } })
		.composite([
			{ input: screenshot, left: d.screen.x, top: d.screen.y },
			{ input: framePng, left: 0, top: 0 },
		])
		.png().toBuffer();

	// 2. Scale the framed device onto the canvas.
	const deviceH = Math.round((d.deviceW * d.fh) / d.fw);
	const deviceScaled = await sharp(framed).resize(d.deviceW, deviceH).png().toBuffer();
	const deviceX = Math.round((d.canvas.w - d.deviceW) / 2);

	// 3. Headline: one centered Inter block, scaled so it fills titleMaxW (natural line spacing).
	const head = await renderHeadline(line1, line2);
	let headScaled = null;
	if (head) {
		const scale = Math.min(1, d.titleMaxW / head.w);
		const w = Math.max(1, Math.round(head.w * scale));
		const h = Math.max(1, Math.round(head.h * scale));
		headScaled = { buf: await sharp(head.buf).resize(w, h).png().toBuffer(), w, h };
	}

	// 4. Background + phone-shaped shadow.
	const bg = Buffer.from(`<svg width="${d.canvas.w}" height="${d.canvas.h}" xmlns="http://www.w3.org/2000/svg">
  <defs><linearGradient id="g" x1="0" y1="0" x2="0" y2="1">
    <stop offset="0" stop-color="#F5F6F9"/><stop offset="1" stop-color="#E6E9F0"/></linearGradient></defs>
  <rect width="${d.canvas.w}" height="${d.canvas.h}" fill="url(#g)"/>
</svg>`);
	const shadow = await sharp(roundRect(d.deviceW, deviceH, Math.round(d.deviceW * d.shadowRF), 'rgba(20,22,28,0.26)'))
		.extend({ top: 70, bottom: 70, left: 70, right: 70, background: { r: 0, g: 0, b: 0, alpha: 0 } })
		.blur(52).png().toBuffer();

	// 5. Compose: shadow, device, headline lines (centered, stacked), gold rule.
	const layers = [
		{ input: shadow, left: deviceX - 70, top: d.deviceY - 70 + 34 },
		{ input: deviceScaled, left: deviceX, top: d.deviceY },
	];
	if (headScaled) {
		layers.push({ input: headScaled.buf, left: Math.round((d.canvas.w - headScaled.w) / 2), top: d.titleTop });
		const ruleY = d.titleTop + headScaled.h + 34;
		layers.push({ input: roundRect(144, 9, 4.5, ACCENT), left: Math.round((d.canvas.w - 144) / 2), top: Math.round(ruleY) });
	}

	await sharp(bg).composite(layers).flatten({ background: '#F5F6F9' }).png().toFile(out);
}

// CLI
if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
	const [rawPath, out, line1, line2, device] = process.argv.slice(2);
	if (!rawPath || !out) {
		console.error('usage: node frame.mjs <raw.png> <out.png> "<line 1>" "<line 2>" [device]');
		process.exit(1);
	}
	await frame({ rawPath, out, line1, line2, device });
	console.log('wrote', out);
}
