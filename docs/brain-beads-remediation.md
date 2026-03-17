# Beads Memory Remediation — One-Time Cleanup

> Independent of V1 freshness system rollout. Execute at any time.
> Source: [brain-synapse-map.md](brain-synapse-map.md) audit findings.

## Delete stale (2)

| Key | Reason |
|-----|--------|
| `website-astro-migration-website-files-in-docs-website` | Describes "next step" (Astro migration) that shipped weeks ago. Fully superseded. |
| `website-seo-status-seo-score-97-100-meta` | Says canonical URLs still point to github.io. They don't. Superseded by `website-seo-status`. |

```bash
bd forget website-astro-migration-website-files-in-docs-website
bd forget website-seo-status-seo-score-97-100-meta
```

## Delete redundant (2)

| Key | Reason | Covered by |
|-----|--------|------------|
| `buddies-hygiene-proactively-offer-to-delete-finished-session` | One-liner subsumed by HYGIENE section | `buddies-rulebook` |
| `swiftui-plain-button-hit-testing-buttonstyle-plain-makes` | Same content as rules file | `.claude/rules/swift-patterns.md` |

```bash
bd forget buddies-hygiene-proactively-offer-to-delete-finished-session
bd forget swiftui-plain-button-hit-testing-buttonstyle-plain-makes
```

## Consolidate (3 → 1)

Merge `website-astro-migration`, `astro-website-setup-*`, and `website-cloudflare-live` into one entry.

```bash
bd remember "website-setup" "Astro 6 website in website/ dir. @astrojs/sitemap + @astrojs/cloudflare adapter. Deployed to Cloudflare Pages at enviouswispr.com (auto-deploys on push to main). appcast.xml synced to website/public/appcast.xml during release CI. Blog posts: src/content/blog/*.md. Shared layouts: BaseLayout, Nav, Footer. Build: npm run build, output: dist/client/."
bd forget website-astro-migration
bd forget astro-website-setup-astro-website-lives-in-website
bd forget website-cloudflare-live
```

## Result

34 → 27 memories. 4 deleted, 3 consolidated into 1.
