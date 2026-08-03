// Generates public/og-image.png — a PLACEHOLDER social card (text-on-brand)
// until the real icon/wordmark art exists (#227 open item E). Re-run with:
//   node scripts/make-og.mjs
import sharp from 'sharp';
import { fileURLToPath } from 'node:url';

const svg = `<svg width="1200" height="630" viewBox="0 0 1200 630" xmlns="http://www.w3.org/2000/svg">
  <rect width="1200" height="630" fill="#ffffff"/>
  <rect x="96" y="92" width="72" height="72" rx="18" fill="#D08A2A"/>
  <path d="M117 130 l14 14 l26 -28" fill="none" stroke="#1C1C1E" stroke-width="8" stroke-linecap="round" stroke-linejoin="round"/>
  <text x="186" y="148" font-family="Helvetica, Arial, sans-serif" font-size="46" font-weight="700" fill="#000000">Poimi</text>
  <text x="96" y="322" font-family="Helvetica, Arial, sans-serif" font-size="74" font-weight="800" fill="#000000" letter-spacing="-2">Hand-pick a year of photos</text>
  <text x="96" y="406" font-family="Helvetica, Arial, sans-serif" font-size="74" font-weight="800" fill="#000000" letter-spacing="-2">into one album.</text>
  <text x="96" y="496" font-family="Helvetica, Arial, sans-serif" font-size="34" font-weight="500" fill="#3F5E37">You choose every photo, not an algorithm.</text>
  <text x="96" y="552" font-family="Helvetica, Arial, sans-serif" font-size="26" font-weight="400" fill="#6b6b70">For iPhone &amp; iPad · Free</text>
</svg>`;

const out = fileURLToPath(new URL('../public/og-image.png', import.meta.url));
await sharp(Buffer.from(svg)).png().toFile(out);
console.log('wrote', out);
