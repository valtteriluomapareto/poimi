//
//  frame-all.mjs — frame every raw App Store capture with its hero headline (#230).
//
//  Reads screenshots/appstore/<locale>/NN_<device>_<screen>.png (from appstore-screenshots.sh),
//  looks up the per-screen / per-locale headline, and writes the framed image to
//  screenshots/appstore/framed/<locale>/<same name>. Run after a capture:
//
//      node Scripts/framing/frame-all.mjs
//
import { frame } from './frame.mjs';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const DIR = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(DIR, '../../screenshots/appstore');

// Hero headline per screen, per ASC locale (2 lines). A missing locale falls back to en-US. Copy was
// reviewed by a 4-lens panel incl. a native-Finnish pass (#230); worth the owner's final eye before
// publish. Store display order is set by STORE_ORDER below — not the app-flow order.
const HEADLINES = {
	overview: {
		'en-US': ['Thousands of photos.', 'One clear view.'],
		fi: ['Tuhansia kuvia.', 'Yksi selkeä näkymä.'],
	},
	scanning: {
		'en-US': ['You pick every photo.', 'Not an algorithm.'],
		fi: ['Sinä poimit jokaisen kuvan.', 'Ei algoritmi.'],
	},
	photoviewer: {
		'en-US': ['Take a closer look.', 'Pick what stays.'],
		fi: ['Katso tarkemmin.', 'Poimi, mikä jää.'],
	},
	export: {
		'en-US': ['A real album in Photos.', 'Yours to keep.'],
		fi: ['Oikea albumi Kuvissa.', 'Sinun, pysyvästi.'],
	},
};

// App Store display order — `deliver`/ASC sorts by the framed filename's numeric prefix, so we renumber
// the framed set here. Leads with the grid (the "every photo, not an algorithm" differentiator);
// screenshot 1 is what shows in search results. (Keep in sync with SCREEN_ORDER in the capture script.)
const STORE_ORDER = ['scanning', 'photoviewer', 'overview', 'export'];

function headline(screen, locale) {
	const s = HEADLINES[screen];
	if (!s) return ['', ''];
	return s[locale] ?? s['en-US'] ?? ['', ''];
}

if (!fs.existsSync(ROOT)) {
	console.error(`no captures at ${ROOT} — run Scripts/appstore-screenshots.sh first`);
	process.exit(1);
}

const locales = fs
	.readdirSync(ROOT, { withFileTypes: true })
	.filter((d) => d.isDirectory() && d.name !== 'framed')
	.map((d) => d.name);

let framed = 0;
for (const locale of locales) {
	const srcDir = path.join(ROOT, locale);
	const outDir = path.join(ROOT, 'framed', locale);
	fs.mkdirSync(outDir, { recursive: true });

	for (const file of fs.readdirSync(srcDir).filter((f) => f.endsWith('.png')).sort()) {
		const m = file.match(/^(\d+)_([^_]+)_(.+)\.png$/); // NN_<device>_<screen>.png
		if (!m) {
			console.warn(`skip (unrecognized name): ${file}`);
			continue;
		}
		const device = m[2];
		const screen = m[3];
		const [line1, line2] = headline(screen, locale);
		// Renumber to STORE_ORDER (independent of the raw capture prefix) so `deliver` shows them in
		// store order. Unknown screens sort last (99).
		const pos = STORE_ORDER.indexOf(screen);
		const prefix = String(pos < 0 ? 99 : pos + 1).padStart(2, '0');
		const out = path.join(outDir, `${prefix}_${device}_${screen}.png`);
		await frame({ rawPath: path.join(srcDir, file), out, line1, line2, device });
		console.log(`framed  ${locale}/${path.basename(out)}  (${device})  →  "${line1} ${line2}"`);
		framed += 1;
	}
}
console.log(`done — ${framed} framed image(s) under ${ROOT}/framed/`);
