# Issue #2498 - Dictionary Help Terminology - 2026-09-01

GitHub issue: `#2498`. Parent: `#2491`. Tier: SMALL. Status: APPROVED under founder autopilot.

## Preface - Lane + Live UAT declaration

**Lane:** Content

**Live UAT:** Y. Build the real Astro site, inspect the Help index, Dictionary category, and affected article pages in a browser, and confirm the visible labels and instructions match the shipped app.

## Preface - User Rubric

1. **Who:** Meera has just seen a colleague's name misspelled in a message and opens Help before changing Settings.
2. **Why:** "Just show me where to teach it the right spelling."
3. **Invocation:** Reactive and voluntary, from the Help Center after a bad dictation.
4. **App:** A browser for Help, then EnviousWispr Settings.
5. **Natural inputs:** "how do I add a name", "where is your words", "fix a misspelled name", "turn on vocabulary packs", and "import my contacts".
6. **Success:** The Help path says Settings > Dictionary and names the exact tab she sees.
7. **Wrong but not broken:** The article is understandable but points to an old page name, so she assumes her app version differs and gives up.
8. **Power-user workaround:** Search every Settings page or use site search for both "Dictionary" and "Custom Words".
9. **Control:** No behavior control is involved; wording must simply mirror the shipped UI.

**Cross-persona check:** Priya and Aaron need exact tab names; Diana and Meera need low-friction navigation; Marcus needs plain language; Dr. Vasquez needs the privacy explanation preserved; Frank needs stable labels with no translation burden. All seven favor the same wording.

## 0. TL;DR

The shipped settings page is named Dictionary, but the public Help Center still displays Custom Words as its category and four listed articles contain stale terminology or navigation. A whole-Help sweep found two additional category articles carrying the stale `section: "Custom Words"` frontmatter. This value is not currently rendered because the category has exactly four articles, but all four values must move together to preserve grouping and Related fallback if the category grows. Update the category display label and six articles while preserving URLs, category slugs, existing search keywords, behavior claims, and unrelated prose. Prove it with the Astro content checks, production build, link check, and browser inspection.

## 1. Problem

- `website/src/data/help-categories.ts:57-59` displays the category as `Custom Words`.
- `adding-custom-words.md:17,34,40` points all three tasks to the old `Your Words` page instead of the current Dictionary tabs.
- `importing-and-exporting-custom-words.md:11,17` omits Dictionary from its paths.
- `why-is-my-dictation-inaccurate.md:23-25` uses deprecated entry terminology and the old page path.
- `how-smart-polish-works-context-aware.md:37` describes the old enablement location.
- `how-custom-word-correction-works.md:5` and `adding-a-word-from-your-selection.md:5` retain stale section metadata; the latter also calls saved words `terms` at line 20. The section value is currently hidden, but all four category articles must agree so grouping and Related fallback stay stable if the category grows.

Seven other articles named in #2498 were read through EOF and contain no stale Dictionary terminology, so changing them would be unnecessary churn.

## 2. Goals and non-goals

### 2.1 Goals

- Match current labels: Dictionary, Your Words, Vocabulary Packs, Learn from..., Quick Add, and Enable Dictionary.
- Use `word` for a saved Dictionary entry.
- Keep privacy and functional claims unchanged.
- Keep public URLs, category slugs, and every existing keyword value stable.
- Add the five User Rubric phrases as search synonyms on the existing `adding-custom-words` article.

### 2.2 Non-goals

- No app code, behavior, routing, URL, or SEO-keyword change.
- No blanket replacement of ordinary English or legal uses of `term`.
- No rewriting of already-correct articles.

## 2.5 Grounding brief

1. **Producer to consumer:** `HELP_CATEGORIES` owns the category display label at `website/src/data/help-categories.ts:56-60`. `[...slug].astro:86,104,110` uses that label in breadcrumbs and structured metadata. Article frontmatter owns section headings; `[...slug].astro:118-120` groups those articles for category rendering. Article Markdown is rendered directly as user-visible Help content.
2. **Existing authority:** `SettingsSection.swift:72` names the settings section `Dictionary`; `YourWordsView.swift:49-52` owns `Your Words`, `Vocabulary Packs`, `Learn from...`, and `Quick Add`; `YourWordsView.swift:226,237` owns `Dictionary` and `Enable Dictionary`. This plan mirrors those strings rather than creating terminology.
3. **Prior direction:** #2491 and #2493 established Dictionary as the feature, `word` as the entry noun, and the current tab names. #2498 explicitly split public content into a separate Content lane.
4. **Boundaries:** The Help category slug remains `custom-words`, while its display label changes. Search keywords may retain phrases users search for. App copy is source evidence, not part of this PR.
5. **High-risk premises:** The full Help grep found six affected articles and one category label. The other seven listed articles were read fully and are already current. The rendered category label has more consumers than the visible index because it also feeds breadcrumbs and JSON-LD.

Evidence commands:

```text
rg -n "Custom Words|custom words|custom word|\\bterms?\\b|Your Words|Vocabulary Packs|Learn from" website/src/content/help website/src/data/help-categories.ts
rg -n "Dictionary|Your Words|Vocabulary Packs|Learn from|Enable Dictionary" Sources/EnviousWisprAppKit/Views/Settings
nl -ba website/src/pages/help/'[...slug].astro' | sed -n '80,130p'
```

## 3. Design

Treat the shipped app labels as the terminology authority. Change the Help category display label to Dictionary. In the six affected articles, replace only user-visible product terms and navigation instructions, selecting the correct tab for each task. Preserve the `custom-words` slug, filenames, links, article titles, and every existing keyword value. Add the five User Rubric phrases to `adding-custom-words.md` as browser-search synonyms: `how do I add a name`, `where is your words`, `fix a misspelled name`, `turn on vocabulary packs`, and `import my contacts`. These additions use the existing article-keyword authority and change no visible label, route, title, SEO URL, or behavior claim.

## 3b. Ownership justification

N/A - no coordinator or manager changes. Existing content authorities remain in place.

Parent epic: `#2491` has no repository plan file. Its shipped direction renamed the feature and organized it into tabs. This content-only mirror is consistent with that direction.

## 3a. Metric definition + earliest failure point

No numerical product target or new fitness gate. Earliest failure is plan review for wrong scope or terminology; Astro content validation catches schema errors; browser review catches visibly awkward or misleading copy.

## 3c. Single-authority check

The app remains the authority for product labels, and `help-categories.ts` remains the Help authority for category identity. Article prose is intentionally local because each task needs different navigation.

§3c-answer: partial-consolidation via the shipped app labels and Help category metadata

## 4. Contract deltas

- **Help category label:** Change the display identity from Custom Words to Dictionary. Keep the `custom-words` slug and route unchanged.
- **Section metadata:** Change `section: "Custom Words"` to `section: "Dictionary"` in all four articles in the `custom-words` category. Moving all four together preserves same-section Related ordering. The value is not currently rendered as a category heading because the category has four articles, but it becomes visible if the category grows beyond four articles and contains more than one section.
- **Article instructions:** Change navigation or enablement instructions in four articles: `adding-custom-words.md`, `importing-and-exporting-custom-words.md`, `why-is-my-dictation-inaccurate.md`, and `how-smart-polish-works-context-aware.md`.
- **Entry noun:** Use word for a saved Dictionary entry. Ordinary English and legal uses of term remain unchanged.
- **Search compatibility:** Preserve existing article titles, filenames, slugs, links, and useful legacy search phrases while proving the user-rubric queries still reach the intended article.
- **Review date:** Update all six changed articles. This drives the visible Last checked line, article JSON-LD `dateModified`, and sitemap lastmod for the articles, their categories, and the Help index.
- **Legacy compatibility:** No persisted application data or executable behavior changes.

## 5. E2E state and lifecycle audit

This is static content with no in-flight application state. The Astro build reads category metadata and article frontmatter, renders every Help route and structured-data block, creates the browser search corpus, and derives sitemap dates. Existing and newly loaded pages use the same built output. Browser caches may briefly retain old copy until normal deployment cache expiry.

## 6. Downstream consumer matrix

| Contract delta | Consumers | Required behavior | Verified by |
|---|---|---|---|
| Category display label | Help index topic cards, Help index Every article groups, desktop and mobile Help sidebar, category page title and heading, article and category breadcrumbs, page metadata and JSON-LD, search-result category badges | Display Dictionary everywhere while retaining `/help/custom-words/` | Astro build, rendered-source inspection, browser inspection |
| Section frontmatter | `groupBySection`, future category section headings, same-section Related fallback, serialized search corpus | All four `custom-words` articles use Dictionary together; Related ordering remains stable | targeted frontmatter grep, browser inspection of Related lists |
| Navigation copy | Four affected article bodies and search snippets | Use the exact Dictionary tab or control for each task | targeted grep, browser article review |
| Entry noun and changed descriptions | Article pages, Help lists, meta descriptions, search corpus and snippets | Use word for saved entries without replacing ordinary uses of term | scoped diff, targeted grep, browser search review |
| Updated date | Visible Last checked line, JSON-LD `dateModified`, article/category/index sitemap lastmod | Reflect the review date on all six changed articles | built HTML and sitemap check |
| Stable identity | Category slug, article filenames, titles, internal links, inbound links and indexed URLs | No route or title changes | route-set equality and internal-link check |
| Search discovery | Browser search index and result ordering | The five User Rubric queries reach the intended Dictionary article while legacy `custom words` search remains green | search assertion suite and browser search UAT |

## 7. Failure-mode x caller table

| Failure mode | Origin | Caller | Expected UX | Persisted state | Metadata | Retry |
|---|---|---|---|---|---|---|
| Bad frontmatter or dead link | edited content | Astro build or route check | deployment blocked | none | build failure | fix and rebuild |
| Partial section rename | only some category articles updated | Related derivation and future category grouping | inconsistent grouping or changed Related order | none | mixed section values | update all four together |
| Wrong tab instruction | prose choice | Help reader | reader cannot find the named control | none | stale search snippet | browser review before PR |
| Search regression | terminology removed from indexed prose | Help search user | intended article no longer ranks first | none | changed search corpus | adjust scoped keywords or prose and rerun |
| Route drift | filename or slug changed | inbound links and search engines | existing URL breaks | none | sitemap route change | restore the stable identity |
| Over-broad replacement | mechanical editing | unrelated prose | ordinary or legal meaning becomes incorrect | none | misleading snippet | scoped diff and review |

No ambiguous lookup or partial batch behavior is introduced.

## 8. Caller-visible signals audit

| Signal | Producer | Consumers | Meaning | Falsifying case |
|---|---|---|---|---|
| Category label | `help-categories.ts` | Help index, desktop/mobile sidebar, category and article pages, breadcrumbs, JSON-LD, search-result category badges | Display identity only | changing the slug or leaving any visible consumer on Custom Words |
| Article `section` | four `custom-words` article frontmatters | grouping, future section headings, same-section Related fallback; serialized but not ranked by current search fields | Help grouping identity | changing fewer than all four articles |
| Article title, description, keywords and body | article renderer and browser search corpus | page metadata, Help lists, snippets and search ranking | user-facing content and discoverability | a User Rubric query no longer reaches the intended article |
| Article `updated` | six changed article frontmatters | Last checked, JSON-LD and sitemap lastmod derivation | content review date | changed instructions retaining the old date |
| Category slug and article filename | `help-categories.ts` and Markdown filenames | routes, internal links, sitemap and indexed URLs | stable public identity | any `/help/.../` route changes |

No nullable, identity-bearing, lifecycle, telemetry, or pipeline-state signal is touched.

## 9. Fallback source-of-truth audit

No fallback branch is introduced. Invalid content fails the build. Search may return an explicitly labelled closest match under its existing rules, but this change does not alter that policy or substitute different terminology.

## 10. File-by-file changes

- `website/src/data/help-categories.ts`: display the `custom-words` category as Dictionary.
- `website/src/content/help/adding-custom-words.md`: change `section` to Dictionary, correct saved-entry nouns, and use Your Words, Vocabulary Packs, and Learn from... in the three task-specific paths.
- `website/src/content/help/importing-and-exporting-custom-words.md`: change `section` to Dictionary, correct saved-entry nouns, and use Settings > Dictionary > Your Words.
- `website/src/content/help/why-is-my-dictation-inaccurate.md`: point to Dictionary and separate the Your Words and Vocabulary Packs steps.
- `website/src/content/help/how-smart-polish-works-context-aware.md`: point enablement to Enable Dictionary.
- `website/src/content/help/how-custom-word-correction-works.md`: change the hidden section metadata to Dictionary; make no body-copy change.
- `website/src/content/help/adding-a-word-from-your-selection.md`: change the hidden section metadata to Dictionary and replace the saved-entry noun `terms` with `words` at line 20.
- `website/scripts/check-help-search.mjs`: append the five User Rubric rows to `PINNED`, retain the existing `custom words` assertion, and update the adjacent count comment from `ten queries` to `fifteen queries`.

## 11. Testing

1. **New suite class:** none. Extend the existing `website/scripts/check-help-search.mjs` assertion table with five pinned queries; no new test file or duplicate search implementation is introduced. Test-hardening issue #2565 carries exactly one human recipe block. Its mutant was caught and restored overnight; the generic validator transparently reported the website suite as unsupported rather than being given an unrelated Swift suite.
2. **Real boundary:** no capture, transcription, or delivery code changes.
3. **Cases not written:** no automated prose snapshots; the existing content schema, build, link check, scoped grep, and browser render are more direct.

### 11.1 Content-lane live UAT

1. After the eight website changes are committed, run `EW_PLAN_FILE=docs/feature-requests/issue-2498-2026-09-01-dictionary-help-terminology.md scripts/validate-pr.sh` and use the run directory it prints.
2. From `website/`, run `npm run build` and save the successful output as `astro-build.log` in that run directory. This includes the content validator and production Astro build.
3. Run `npm run check:help` and save the successful output as `link-check.txt` in that run directory. This proves route-set equality, sitemap coverage, internal Help links, and search assertions.
4. Add pinned search assertions for `how do I add a name`, `where is your words`, `fix a misspelled name`, `turn on vocabulary packs`, and `import my contacts`. Each must rank `adding-custom-words` first. The existing `custom words` assertion must remain green.
5. Serve the production build and save the inspected production-preview address as `preview-url.txt` in the run directory.
6. At desktop and narrow widths, inspect `/help/`, `/help/custom-words/`, and all six changed article pages. In the production preview, run all five User Rubric searches plus `custom words`; confirm `Adding Custom Words` ranks first, its category badge says `Dictionary`, and its snippet contains no stale navigation. Also confirm Dictionary in the index, desktop and mobile sidebars, breadcrumbs, category heading, and unchanged Related ordering.
7. Confirm all existing `/help/.../` URLs remain present and no filename, category slug, article title, or internal link changed.
8. Attest `astro-build` and `link-check` with `scripts/attest.sh`, then require `scripts/check-validation.sh "$RUN_DIR" --strict` to pass.

## 12. Blast radius and rollback

Eight website files are in scope: one category authority, six Help articles, and the existing search assertion file. App code, routes, slugs, analytics, and persisted data remain untouched. Roll back with a normal revert of the content commit.

## 13. Ship criteria

- [ ] Targeted stale-copy grep contains no unintended product terminology.
- [ ] Website content validation passes.
- [ ] Production Astro build passes.
- [ ] Link check passes.
- [ ] Browser inspection passes on Help index, category, and six article pages.
- [ ] Codex plan and diff reviews pass.
- [ ] Human-facing copy contains no em dash or en dash.
- [ ] PR CI passes.

## 14. Open questions

None. Preserve the URL slug and keyword metadata while updating visible product language.

## 15. Related

- #2491 Dictionary redesign epic
- #2493 terminology authority
- #2498 current Content ticket
