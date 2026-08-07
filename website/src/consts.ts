// Single source of truth for the outbound links + launch-gated App Store state.
// The app is LIVE (Apple ID 6787949877), so IS_APP_STORE_LIVE = true: the CTAs
// link to APP_STORE_URL and the SoftwareApplication JSON-LD emits offers.url /
// downloadUrl. The gate stays in place (a mechanism, not dead code): set it back
// to false to return to the "Coming to the App Store" state without dead links.

export const IS_APP_STORE_LIVE = true;
// Region-agnostic App Store link (no country code) so it redirects to the
// visitor's storefront rather than pinning everyone to /fi/. Apple ID 6787949877.
export const APP_STORE_URL =
	'https://apps.apple.com/app/poimi-photo-album-curation/id6787949877';

export const GITHUB_URL = 'https://github.com/valtteriluomapareto/poimi';
export const GITHUB_ISSUES_URL = `${GITHUB_URL}/issues`;
export const LICENSE_URL = `${GITHUB_URL}/blob/main/LICENSE`;
export const COMMERCIAL_LICENSE_URL = `${GITHUB_URL}/blob/main/COMMERCIAL-LICENSE.md`;

export const CONTACT_EMAIL = 'valtteri.e.luoma@gmail.com';

// Bump to the App Store version once live; used in the SoftwareApplication JSON-LD.
export const APP_VERSION = '1.0';
