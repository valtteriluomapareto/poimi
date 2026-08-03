// Base-path join. `import.meta.env.BASE_URL` may or may not carry a trailing
// slash (it's "/poimi" for base:'/poimi'), so never string-concat it directly —
// always go through withBase() so links/assets get exactly one slash.
const RAW_BASE = import.meta.env.BASE_URL;
export const BASE = RAW_BASE.endsWith('/') ? RAW_BASE : `${RAW_BASE}/`;

/** Join a path onto the site base with exactly one separating slash. */
export function withBase(path = ''): string {
	return `${BASE}${path.replace(/^\//, '')}`.replace(/([^:])\/{2,}/g, '$1/');
}
