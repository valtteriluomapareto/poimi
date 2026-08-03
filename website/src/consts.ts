// Single source of truth for the outbound links + launch-gated App Store state.
// Flip IS_APP_STORE_LIVE to true (and set the real URL) once the listing exists;
// until then the CTAs render a "Coming to the App Store" state and the
// SoftwareApplication JSON-LD omits downloadUrl / offers.url rather than emit
// dead links (3-persona review, launch gate).

export const IS_APP_STORE_LIVE = false;
export const APP_STORE_URL = 'https://apps.apple.com/app/poimi/idPLACEHOLDER';

export const GITHUB_URL = 'https://github.com/valtteriluomapareto/poimi';
export const GITHUB_ISSUES_URL = `${GITHUB_URL}/issues`;
export const LICENSE_URL = `${GITHUB_URL}/blob/main/LICENSE`;
export const COMMERCIAL_LICENSE_URL = `${GITHUB_URL}/blob/main/COMMERCIAL-LICENSE.md`;

export const CONTACT_EMAIL = 'valtteri.e.luoma@gmail.com';

// Bump to the App Store version once live; used in the SoftwareApplication JSON-LD.
export const APP_VERSION = '1.0';
