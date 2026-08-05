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

// Hero headline per screen, per ASC locale (2 lines). `fi` copy is TODO (owner writes it) — falls
// back to en-US until then.
const HEADLINES = {
	overview: {
		'en-US': ['Always know', 'where you stand.'],
	},
	scanning: {
		'en-US': ['Hand-pick your year.', 'Every photo, not an algorithm.'],
	},
	photoviewer: {
		'en-US': ['Look closer,', 'then pick the keeper.'],
	},
	export: {
		'en-US': ['A real album in Photos.', 'Yours to keep.'],
	},
};

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
		const m = file.match(/^(\d+)_[^_]+_(.+)\.png$/); // NN_<device>_<screen>.png
		if (!m) {
			console.warn(`skip (unrecognized name): ${file}`);
			continue;
		}
		const screen = m[2];
		const [line1, line2] = headline(screen, locale);
		const out = path.join(outDir, file);
		await frame({ rawPath: path.join(srcDir, file), out, line1, line2 });
		console.log(`framed  ${locale}/${file}  →  "${line1} ${line2}"`);
		framed += 1;
	}
}
console.log(`done — ${framed} framed image(s) under ${ROOT}/framed/`);
