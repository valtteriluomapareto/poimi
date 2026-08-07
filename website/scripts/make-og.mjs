// Generates public/og-image.png — the social card: the app icon + wordmark + tagline.
// Re-run after changing the icon or the copy:  node scripts/make-og.mjs
import sharp from 'sharp';
import { fileURLToPath } from 'node:url';

const svg = `<svg width="1200" height="630" viewBox="0 0 1200 630" xmlns="http://www.w3.org/2000/svg">
  <rect width="1200" height="630" fill="#ffffff"/>
  <text x="196" y="150" font-family="Helvetica, Arial, sans-serif" font-size="46" font-weight="700" fill="#000000">Poimi</text>
  <text x="96" y="322" font-family="Helvetica, Arial, sans-serif" font-size="74" font-weight="800" fill="#000000" letter-spacing="-2">Hand-pick a year of photos</text>
  <text x="96" y="406" font-family="Helvetica, Arial, sans-serif" font-size="74" font-weight="800" fill="#000000" letter-spacing="-2">into one album.</text>
  <text x="96" y="496" font-family="Helvetica, Arial, sans-serif" font-size="34" font-weight="500" fill="#3F5E37">You choose every photo, not an algorithm.</text>
  <text x="96" y="552" font-family="Helvetica, Arial, sans-serif" font-size="26" font-weight="400" fill="#6b6b70">For iPhone &amp; iPad · Free</text>
</svg>`;

// Composite the real app icon (its white ground merges into the white card, so the
// grid + gold pick read as the mark). Keep it in sync by re-running after an icon change.
const iconPath = fileURLToPath(new URL('../public/icon.png', import.meta.url));
const icon = await sharp(iconPath).resize(92, 92).png().toBuffer();

const out = fileURLToPath(new URL('../public/og-image.png', import.meta.url));
await sharp(Buffer.from(svg))
	.composite([{ input: icon, top: 90, left: 96 }])
	.png()
	.toFile(out);
console.log('wrote', out);
