//
//  frame.mjs — composite a raw App Store screenshot into a real device frame, on a branded
//  background with a hero headline, at the exact App Store size (#230).
//
//  Uses a real iPhone 17 Pro Max bezel from fastlane/frameit-frames (frames/) + its offsets.json
//  screen rect, so the phone looks real (correct corners, rails, Dynamic Island) — no hand-drawn
//  frame. Output is an opaque PNG at the accepted App Store resolution.
//
//  Library:  import { frame } from './frame.mjs'; await frame({ rawPath, out, line1, line2 })
//  CLI:      node frame.mjs <raw.png> <out.png> "<line 1>" "<line 2>"
//
import sharp from 'sharp';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const DIR = path.dirname(fileURLToPath(import.meta.url));

// iPhone 17 Pro Max bezel (1470×3000) + screen rect from offsets.json ("+75+66", width 1320 → our
// 1320×2868 capture fits exactly).
const FRAME = { png: path.join(DIR, 'frames/iphone-17-pro-max.png'), w: 1470, h: 3000, screen: { x: 75, y: 66, w: 1320, h: 2868 } };
const CANVAS = { w: 1320, h: 2868 };   // App Store 6.9" output
const PHONE_W = 1012;                   // framed phone width on the canvas
const PHONE_Y = 566;
const SCREEN_R = 152;                   // screenshot corner radius (tucks inside the bezel)

const roundRect = (w, h, r, fill) =>
	Buffer.from(`<svg width="${w}" height="${h}"><rect width="${w}" height="${h}" rx="${r}" ry="${r}" fill="${fill}"/></svg>`);

const escapeXml = (s) =>
	String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');

/** Frame one screenshot → an opaque App-Store-sized PNG. */
export async function frame({ rawPath, out, line1 = '', line2 = '' }) {
	if (!fs.existsSync(FRAME.png)) {
		throw new Error(`missing device bezel ${FRAME.png} — run Scripts/framing/fetch-frames.sh first`);
	}

	// 1. Framed phone: screenshot (corners rounded to the screen radius so they don't poke past the
	//    device's rounded corners) into the cutout, bezel PNG on top.
	const screenshot = await sharp(
		await sharp(rawPath).resize(FRAME.screen.w, FRAME.screen.h, { fit: 'fill' }).toBuffer(),
	)
		.composite([{ input: roundRect(FRAME.screen.w, FRAME.screen.h, SCREEN_R, '#fff'), blend: 'dest-in' }])
		.png()
		.toBuffer();
	const phone = await sharp({
		create: { width: FRAME.w, height: FRAME.h, channels: 4, background: { r: 0, g: 0, b: 0, alpha: 0 } },
	})
		.composite([
			{ input: screenshot, left: FRAME.screen.x, top: FRAME.screen.y },
			{ input: FRAME.png, left: 0, top: 0 },
		])
		.png()
		.toBuffer();

	// 2. Scale the framed phone to sit below the headline.
	const phoneH = Math.round((PHONE_W * FRAME.h) / FRAME.w);
	const phoneScaled = await sharp(phone).resize(PHONE_W, phoneH).png().toBuffer();
	const phoneX = Math.round((CANVAS.w - PHONE_W) / 2);

	// 3. Branded background + hero headline (Helvetica placeholder → embed Inter for the real set).
	const bg = Buffer.from(`<svg width="${CANVAS.w}" height="${CANVAS.h}" xmlns="http://www.w3.org/2000/svg">
  <defs><linearGradient id="g" x1="0" y1="0" x2="0" y2="1">
    <stop offset="0" stop-color="#F5F6F9"/><stop offset="1" stop-color="#E6E9F0"/></linearGradient></defs>
  <rect width="${CANVAS.w}" height="${CANVAS.h}" fill="url(#g)"/>
  <text x="${CANVAS.w / 2}" y="270" text-anchor="middle" font-family="Helvetica" font-size="86" font-weight="800" fill="#1C1C1E" letter-spacing="-2">${escapeXml(line1)}</text>
  <text x="${CANVAS.w / 2}" y="386" text-anchor="middle" font-family="Helvetica" font-size="86" font-weight="800" fill="#1C1C1E" letter-spacing="-2">${escapeXml(line2)}</text>
  <rect x="${CANVAS.w / 2 - 72}" y="456" width="144" height="9" rx="4.5" fill="#D08A2A"/>
</svg>`);

	// 4. Soft phone-shaped drop shadow.
	const shadow = await sharp(roundRect(PHONE_W, phoneH, Math.round(PHONE_W * 0.155), 'rgba(20,22,28,0.28)'))
		.extend({ top: 70, bottom: 70, left: 70, right: 70, background: { r: 0, g: 0, b: 0, alpha: 0 } })
		.blur(48)
		.png()
		.toBuffer();

	// 5. Compose, flatten opaque (App Store rejects alpha), write.
	await sharp(bg)
		.composite([
			{ input: shadow, left: phoneX - 70, top: PHONE_Y - 70 + 34 },
			{ input: phoneScaled, left: phoneX, top: PHONE_Y },
		])
		.flatten({ background: '#F5F6F9' })
		.png()
		.toFile(out);
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
