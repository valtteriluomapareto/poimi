//
//  frame.mjs — composite a raw App Store screenshot into a real device frame, on a branded
//  background with an Inter hero headline, at the exact App Store size (#230).
//
//  - iPhone 17 Pro Max bezel from fastlane/frameit-frames (frames/) + its offsets.json screen rect,
//    so the phone looks real (correct corners, rails, Dynamic Island) — no hand-drawn frame.
//  - Headline in Inter ExtraBold (fonts/Inter.ttf), rendered via libvips text with a fontfile (no
//    system font install needed). Both lines share one size (scaled so the wider fills the canvas).
//  - Output: an opaque PNG at the accepted App Store resolution.
//
//  Library:  import { frame } from './frame.mjs'; await frame({ rawPath, out, line1, line2 })
//  CLI:      node frame.mjs <raw.png> <out.png> "<line 1>" "<line 2>"
//
import sharp from 'sharp';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const DIR = path.dirname(fileURLToPath(import.meta.url));
const FONT = path.join(DIR, 'fonts/Inter.ttf');

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

const FRAME = { png: path.join(DIR, 'frames/iphone-17-pro-max.png'), w: 1470, h: 3000, screen: { x: 75, y: 66, w: 1320, h: 2868 } };
const CANVAS = { w: 1320, h: 2868 };   // App Store 6.9" output
const PHONE_W = 1012;
const PHONE_Y = 566;
const SCREEN_R = 152;
const TITLE_MAXW = 1170;               // the wider headline line fills this width
const TITLE_TOP = 178;
const INK = '#1C1C1E';
const ACCENT = '#D08A2A';

const roundRect = (w, h, r, fill) =>
	Buffer.from(`<svg width="${w}" height="${h}"><rect width="${w}" height="${h}" rx="${r}" ry="${r}" fill="${fill}"/></svg>`);
const escapeXml = (s) =>
	String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');

/** Render one headline line as an Inter ExtraBold rgba text image. */
async function renderLine(text) {
	const buf = await sharp({
		text: {
			text: `<span weight="800" foreground="${INK}">${escapeXml(text)}</span>`,
			font: 'Inter 100',
			fontfile: FONT,
			rgba: true,
			dpi: 72,
		},
	})
		.png()
		.toBuffer();
	const meta = await sharp(buf).metadata();
	return { buf, w: meta.width, h: meta.height };
}

/** Frame one screenshot → an opaque App-Store-sized PNG. */
export async function frame({ rawPath, out, line1 = '', line2 = '' }) {
	if (!fs.existsSync(FRAME.png)) throw new Error(`missing device bezel ${FRAME.png} — run Scripts/framing/fetch-assets.sh`);
	if (!fs.existsSync(FONT)) throw new Error(`missing font ${FONT} — run Scripts/framing/fetch-assets.sh`);

	// 1. Framed phone: rounded screenshot into the cutout, bezel PNG on top.
	const screenshot = await sharp(
		await sharp(rawPath).resize(FRAME.screen.w, FRAME.screen.h, { fit: 'fill' }).toBuffer(),
	)
		.composite([{ input: roundRect(FRAME.screen.w, FRAME.screen.h, SCREEN_R, '#fff'), blend: 'dest-in' }])
		.png()
		.toBuffer();
	const phone = await sharp({ create: { width: FRAME.w, height: FRAME.h, channels: 4, background: { r: 0, g: 0, b: 0, alpha: 0 } } })
		.composite([
			{ input: screenshot, left: FRAME.screen.x, top: FRAME.screen.y },
			{ input: FRAME.png, left: 0, top: 0 },
		])
		.png()
		.toBuffer();

	// 2. Scale the framed phone.
	const phoneH = Math.round((PHONE_W * FRAME.h) / FRAME.w);
	const phoneScaled = await sharp(phone).resize(PHONE_W, phoneH).png().toBuffer();
	const phoneX = Math.round((CANVAS.w - PHONE_W) / 2);

	// 3. Headline: render both lines, scale by a common factor so the wider one fills TITLE_MAXW.
	const lines = (await Promise.all([line1, line2].filter((l) => l).map(renderLine)));
	const maxW = Math.max(1, ...lines.map((l) => l.w));
	const scale = Math.min(1, TITLE_MAXW / maxW);
	const scaled = await Promise.all(
		lines.map(async (l) => {
			const w = Math.max(1, Math.round(l.w * scale));
			const h = Math.max(1, Math.round(l.h * scale));
			return { buf: await sharp(l.buf).resize(w, h).png().toBuffer(), w, h };
		}),
	);

	// 4. Branded gradient background.
	const bg = Buffer.from(`<svg width="${CANVAS.w}" height="${CANVAS.h}" xmlns="http://www.w3.org/2000/svg">
  <defs><linearGradient id="g" x1="0" y1="0" x2="0" y2="1">
    <stop offset="0" stop-color="#F5F6F9"/><stop offset="1" stop-color="#E6E9F0"/></linearGradient></defs>
  <rect width="${CANVAS.w}" height="${CANVAS.h}" fill="url(#g)"/>
</svg>`);

	// 5. Phone-shaped drop shadow.
	const shadow = await sharp(roundRect(PHONE_W, phoneH, Math.round(PHONE_W * 0.155), 'rgba(20,22,28,0.28)'))
		.extend({ top: 70, bottom: 70, left: 70, right: 70, background: { r: 0, g: 0, b: 0, alpha: 0 } })
		.blur(48)
		.png()
		.toBuffer();

	// 6. Lay out headline lines (centered, stacked) + a gold accent rule beneath.
	const layers = [
		{ input: shadow, left: phoneX - 70, top: PHONE_Y - 70 + 34 },
		{ input: phoneScaled, left: phoneX, top: PHONE_Y },
	];
	let y = TITLE_TOP;
	for (const s of scaled) {
		layers.push({ input: s.buf, left: Math.round((CANVAS.w - s.w) / 2), top: Math.round(y) });
		y += s.h + Math.round(s.h * 0.06);
	}
	layers.push({ input: roundRect(144, 9, 4.5, ACCENT), left: Math.round((CANVAS.w - 144) / 2), top: Math.round(y + 30) });

	await sharp(bg).composite(layers).flatten({ background: '#F5F6F9' }).png().toFile(out);
}

// CLI
if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
	const [rawPath, out, line1, line2] = process.argv.slice(2);
	if (!rawPath || !out) {
		console.error('usage: node frame.mjs <raw.png> <out.png> "<line 1>" "<line 2>"');
		process.exit(1);
	}
	await frame({ rawPath, out, line1, line2 });
	console.log('wrote', out);
}
