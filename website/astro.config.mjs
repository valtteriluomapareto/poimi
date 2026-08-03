// @ts-check
import { defineConfig } from 'astro/config';
import sitemap from '@astrojs/sitemap';

// Derived from the GitHub Actions context so that renaming the repository
// automatically updates the Pages base path on the next deploy. Falls back to
// the current slug for local builds.
const FALLBACK_REPOSITORY = 'valtteriluomapareto/poimi';
const repository = process.env.GITHUB_REPOSITORY || FALLBACK_REPOSITORY;
const [repoOwner, repoName] = repository.split('/');
if (!repoOwner || !repoName || repository.split('/').length !== 2) {
	throw new Error(
		`Invalid GITHUB_REPOSITORY value: "${repository}". Expected "owner/repo".`,
	);
}

// https://astro.build/config
export default defineConfig({
	site: 'https://valtteriluomapareto.github.io',
	base: `/${repoName}`,
	trailingSlash: 'ignore',
	integrations: [
		sitemap({
			// Legal pages stay out of the sitemap until sign-off (they also carry
			// `noindex` in their <head>). Support is a normal indexable page.
			filter: (page) =>
				!page.endsWith('/privacy/') &&
				!page.endsWith('/privacy') &&
				!page.endsWith('/terms/') &&
				!page.endsWith('/terms'),
		}),
	],
});
