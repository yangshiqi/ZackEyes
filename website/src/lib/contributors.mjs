// Real human contributors to ZackEyes, auto-fetched from the GitHub
// contributors graph at BUILD TIME, with the curated FALLBACK list below used
// whenever the API is unreachable or rate-limited — so the footer never
// renders empty and the build never fails on a network blip.
//
// Bots are excluded on purpose:
//   - AI co-authors (Claude / Codex / Gemini) only ever appear as
//     `Co-Authored-By` trailers, never as the commit *author*, so the GitHub
//     contributors API never lists them.
//   - `*[bot]` accounts (github-actions[bot], dependabot[bot], ...) are
//     filtered out by `isBot()` below.
//
// Source graph: https://github.com/yangshiqi/ZackEyes/graphs/contributors

const OWNER_REPO = 'yangshiqi/ZackEyes';

// Display-name overrides for logins that differ from the person's name.
// Anyone not listed renders with their GitHub login.
const NAME_OVERRIDES = {
  Foen1x: 'Johnny Fu',
};

// Used only when the build-time GitHub fetch fails (offline / rate-limited /
// API error). Keep this in sync as a sensible last-known-good snapshot.
const FALLBACK = [
  { login: 'yangshiqi', name: 'yangshiqi' },
  { login: 'Foen1x', name: 'Johnny Fu' },
];

function isBot(c) {
  return c.type === 'Bot' || /\[bot\]$/i.test(c.login) || /-bot$/i.test(c.login);
}

// Memoized across the whole build so every page/footer render shares ONE API
// call (Astro renders the footer on each of the 8 pages).
let cache;

export function getContributors() {
  if (!cache) cache = fetchContributors();
  return cache;
}

async function fetchContributors() {
  try {
    const res = await fetch(
      `https://api.github.com/repos/${OWNER_REPO}/contributors?per_page=100`,
      {
        headers: {
          Accept: 'application/vnd.github+json',
          // GitHub rejects unauthenticated requests without a User-Agent.
          'User-Agent': 'zackeyes-website-build',
        },
      },
    );
    if (!res.ok) throw new Error(`GitHub API ${res.status}`);
    const data = await res.json();
    // API returns contributors already sorted by contributions desc.
    const humans = data
      .filter((c) => !isBot(c))
      .map((c) => ({ login: c.login, name: NAME_OVERRIDES[c.login] || c.login }));
    if (humans.length === 0) throw new Error('no human contributors returned');
    return humans;
  } catch (err) {
    console.warn(`[contributors] GitHub fetch failed, using fallback list: ${err.message}`);
    return FALLBACK;
  }
}
