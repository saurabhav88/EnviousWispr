#!/usr/bin/env node
// The published language count for EnviousWispr's WhisperKit path, enforced.
// Runs from `npm run build` via prebuild (beside check-help-content.mjs), so
// it executes in CI on every deploy — the website-check job in pr-check.yml.
//
// WHY 99+ (mirror the vendor — not "99+ forever"):
// We ship openai_whisper-large-v3-v20240930_turbo through WhisperKit
// (argmaxinc/argmax-oss-swift, see Package.swift). Argmax publishes 99 to 101
// languages for large-v3 / large-v3-turbo, and the founder's 2026-08-24
// direction settled this repo on "99+ for wisprkit". 99+ is true against
// WhisperKit's 99-101, true against our own accepted-code set, and overstates
// nothing. If a future reader finds Argmax publishing a DIFFERENT figure for
// the weights we ship, that number wins: change COUNT below and every site in
// SITES in the same commit. The OpenAI hosted-API figure (98) is NOT our
// vendor — we do not ship that API (#2368).
//
// Two things are checked. Never a whole-site regex over "<number> languages":
// such a pattern cannot tell our claim from a competitor's, which is the exact
// defect #2368 nearly shipped (seventeen sourced competitor "100+" claims).
//   1. Every claim site below — enumerated explicitly — carries COUNT.
//   2. The doc block directly above the two declarations where the count used
//      to live carries no count at all: the set's size is a validation-set
//      size, not a marketed number, and welding the two is how four numbers
//      were born.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

// Resolved from THIS file's location, not the cwd, so the guard inspects the
// tree it lives in — including a scratch copy of the repo.
const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');

const COUNT = '99+';

// [file, phrase] — phrase is a single-line substring of the claim and carries
// COUNT exactly once. Pairs where the same sentence ships twice in one file
// (FAQ JSON + rendered FAQ) are listed once per copy, with the wrapper that
// distinguishes the two.
const SITES = [
  ['README.md', 'WhisperKit (99+ languages, with automatic language detection)'],
  ['README.md', 'Broadest language coverage and automatic language detection | 99+ languages | ~1.6 GB'],
  ['Sources/EnviousWisprAppKit/Views/Settings/SpeechEngineSettingsView.swift', '("Languages", "99+ languages")'],
  ['Sources/EnviousWisprAppKit/Views/Settings/SpeechEngineSettingsView.swift', 'WhisperKit supports 99+ languages.'],
  ['Sources/EnviousWisprAppKit/Views/Settings/WhatsNewContent.swift', 'title: "Dictate in 99+ languages"'],
  ['website/src/content/blog/live-transcription-that-keeps-up-with-you.md', 'the one that covers 99+ languages and the toughest audio'],
  ['website/src/content/blog/on-device-dictation-polishing-small-models.md', 'with WhisperKit available for 99+ languages.'],
  ['website/src/content/blog/getting-started-enviouswispr-under-2-minutes.md', 'A secondary engine is available for 99+ languages.'],
  ['website/src/content/blog/welcome-to-enviouswispr.md', 'A secondary engine covers 99+ languages.'],
  ['website/src/content/help/choosing-a-speech-engine-parakeet-vs-whisperkit.md', '| Languages | 25 European | 99+ |'],
  ['website/src/content/help/multi-language-dictation.md', 'switch to the WhisperKit engine, which supports 99+ languages.'],
  ['website/src/pages/compare/apple-dictation.astro', '25 European (Parakeet), 99+ languages via WhisperKit'],
  ['website/src/pages/compare/best-dictation-apps-for-mac.astro', 'ew: "25 European (Parakeet) + 99+ (WhisperKit)"'],
  ['website/src/pages/compare/best-dictation-apps-for-mac.astro', 'you can switch to WhisperKit for 99+ languages.'],
  ['website/src/pages/compare/fluidvoice.astro', '"text": "EnviousWispr runs NVIDIA Parakeet TDT v3 for 25 European languages and WhisperKit for 99+ languages, switched manually under Settings, Transcription.'],
  ['website/src/pages/compare/fluidvoice.astro', '<td>25 European (Parakeet), 99+ via WhisperKit</td>'],
  ['website/src/pages/compare/fluidvoice.astro', '<p class="faq-a">EnviousWispr runs NVIDIA Parakeet TDT v3 for 25 European languages and WhisperKit for 99+ languages, switched manually under Settings, Transcription.'],
  ['website/src/pages/compare/google-docs-voice-typing.astro', '<td>25 European (Parakeet), 99+ languages via WhisperKit</td>'],
  ['website/src/pages/compare/google-docs-voice-typing.astro', 'WhisperKit supports 99+ but with varying accuracy'],
  ['website/src/pages/compare/handy.astro', '<td>25 European (Parakeet), 99+ via WhisperKit</td>'],
  ['website/src/pages/compare/index.astro', '25 European (Parakeet) + 99+ via WhisperKit'],
  ['website/src/pages/compare/notta.astro', '<td>25 European (Parakeet), 99+ languages via WhisperKit</td>'],
  ['website/src/pages/compare/superwhisper.astro', '"text": "Yes. EnviousWispr offers on-device transcription on Apple Silicon Macs, completely free, with no account or subscription required. It uses Parakeet TDT for 25 European languages and WhisperKit for 99+."'],
  ['website/src/pages/compare/superwhisper.astro', 'language count (99+ via WhisperKit) re-measured 2026-08-21'],
  ['website/src/pages/compare/superwhisper.astro', '<td>25 European (Parakeet), 99+ languages via WhisperKit</td>'],
  ['website/src/pages/compare/superwhisper.astro', '<p class="faq-a">Yes. EnviousWispr offers on-device transcription on Apple Silicon Macs, completely free, with no account or subscription required. It uses Parakeet TDT for 25 European languages and WhisperKit for 99+.</p>'],
  ['website/src/pages/compare/typewhisper.astro', '"text": "EnviousWispr runs NVIDIA Parakeet TDT v3 for 25 European languages and WhisperKit for 99+ languages, switched manually in Settings.'],
  ['website/src/pages/compare/typewhisper.astro', '<p class="faq-a">EnviousWispr runs NVIDIA Parakeet TDT v3 for 25 European languages and WhisperKit for 99+ languages, switched manually in Settings.'],
  ['website/src/pages/compare/voiceink.astro', '"text": "Yes. Parakeet TDT covers 25 European languages. For wider coverage, EnviousWispr switches to WhisperKit, which supports 99+ languages. VoiceInk supports 100+ languages through whisper.cpp."'],
  ['website/src/pages/compare/voiceink.astro', 'EnviousWispr supports 99+ languages via WhisperKit. For English specifically'],
  ['website/src/pages/compare/voiceink.astro', '<td>25 European (Parakeet), 99+ languages via WhisperKit</td>'],
  ['website/src/pages/compare/voiceink.astro', 'WhisperKit handles 99+ languages when you need wider coverage'],
  ['website/src/pages/compare/voiceink.astro', 'EnviousWispr supports 99+ via WhisperKit, and Parakeet TDT (the fast engine)'],
  ['website/src/pages/compare/voiceink.astro', '<p class="faq-a">Yes. Parakeet TDT covers 25 European languages. For wider coverage, EnviousWispr switches to WhisperKit, which supports 99+ languages. VoiceInk supports 100+ languages through whisper.cpp.</p>'],
  ['website/src/pages/compare/voiceink.astro', 'EnviousWispr supports 99+ via WhisperKit, and its fastest engine (Parakeet TDT)'],
  ['website/src/pages/compare/whisper-cpp.astro', '<td>25 European (Parakeet), 99+ via WhisperKit</td>'],
  ['website/src/pages/compare/whisper-cpp.astro', 'with 99+ languages via WhisperKit as a secondary option'],
  ['website/src/pages/compare/willow-voice.astro', 'language count (99+ via WhisperKit) re-measured 2026-08-21'],
  ['website/src/pages/compare/willow-voice.astro', '<td>25 European (Parakeet), 99+ languages via WhisperKit</td>'],
  ['website/src/pages/compare/willow-voice.astro', 'WhisperKit covers 99+ but with higher latency on less common ones'],
  ['website/src/pages/compare/wisprflow.astro', '<td>25 European (Parakeet), 99+ languages via WhisperKit</td>'],
  ['website/src/pages/speech-to-text-mac.astro', 'Runs on the GPU. Slower than Parakeet, covers 99+ languages, and this is the one'],
];

// A language count in prose: a 1-3 digit number (optionally +) within two
// words of "language/languages" OR its abbreviation "lang/langs". Catches
// "(99 languages)", "All 99 Whisper-supported languages", "99-language set",
// and "99-lang set"; does not catch ISO designators like "639-1" (a digit
// cannot continue the match past "-1").
//
// The abbreviation was added by #2368's follow-up, and the omission is why the
// guard could scan a file and report it clean: the stale comment read
// "the Whisper-supported 99-lang set", so a pattern requiring the whole word
// matched nothing and empty read as an answer. Adding the file to ANCHORS
// without this would have changed nothing.
//
// Widening was two-way controlled before shipping rather than assumed safe: run
// over every `//` comment in `Sources/`, the wider alternation newly matches
// EXACTLY ONE line — the defect itself. That matters because this guard was
// deliberately kept narrow (see ANCHORS below) after broad scanning produced
// three false positives on correct prose, and a guard that cries wolf on correct
// code trains people to skip it. This does not reopen that trade.
const COUNT_IN_PROSE = /\b\d{1,3}\+?[\s-]*([A-Za-z-]+\s+){0,2}(languages?|langs?)\b/i;

// The two declarations where the count used to live. The doc block directly
// above each must carry no count. Deliberately NARROW: the other seven
// cleaned comments from #2368 (LanguageCatalog's enum and sortedByEnglishName
// docs, LanguageLockOptions, LanguageLockSheet x2, LanguageDetector) are fixed
// but NOT guarded — scanning every comment in those files produced three false
// positives on correct prose (a "last 10 accepted languages" recents ring
// buffer, a "10 minutes" timeout, Parakeet's correct "25 European languages").
// A guard that cries wolf on correct code trains people to skip it. If one of
// the seven regrows a count, the residue grep from the #2368 PR body is the
// manual net.
const ANCHORS = [
  {
    file: 'Sources/EnviousWisprCore/LanguageTypes.swift',
    label: 'whisperSupportedLanguages',
    declRe: /public static let whisperSupportedLanguages\b/,
  },
  {
    file: 'Sources/EnviousWisprAppKit/Views/Settings/LanguageCatalog.swift',
    label: 'all:',
    declRe: /static let all: \[Entry\]/,
  },
  // The CONSUMER, added by #2368's follow-up (Codex post-merge review on #2372).
  //
  // `SettingsManager` describes the same `LanguageTypes.isSupported` validation
  // and had drifted to "the Whisper-supported 99-lang set" — the stale count this
  // issue set out to remove, in a file the guard did not read.
  //
  // Its comment is a `//` block INSIDE a function body rather than a `///` doc
  // block above a declaration, which is why this entry carries its own
  // `commentRe`. Anchoring on the `let` the block introduces keeps the guard
  // narrow: it reads that block and nothing else in a 1,000-line file.
  {
    file: 'Sources/EnviousWisprServices/SettingsManager.swift',
    label: 'resolvedLanguageMode',
    declRe: /let resolvedLanguageMode: LanguageMode = \{/,
    commentRe: /^\s*\/\//,
  },
];

const failures = [];
const esc = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
const read = (rel) => {
  const p = path.join(ROOT, rel);
  return fs.existsSync(p) ? fs.readFileSync(p, 'utf8') : null;
};

let readableSites = 0;
for (const [rel, phrase] of SITES) {
  const text = read(rel);
  if (text === null) {
    failures.push(`${rel}: file not found — claim site cannot be verified`);
    continue;
  }
  readableSites++;
  if (text.includes(phrase)) continue;
  // What does the site carry instead? Same phrase, any number in COUNT's place.
  const variant = esc(phrase).split(esc(COUNT)).join('([0-9]+\\+?)');
  const m = text.match(new RegExp(variant, 'm'));
  if (m) {
    const lineNo = text.slice(0, m.index).split('\n').length;
    failures.push(`${rel}:${lineNo}: expected "${COUNT}" — site carries "${m[1]}" instead`);
  } else {
    failures.push(`${rel}: claim site no longer reads "${phrase.slice(0, 70)}…" — restore the claim or update this list`);
  }
}
// Fail closed: a check that cannot see a single subject is not a pass.
if (readableSites === 0) {
  failures.push(`no claim-site files could be read under ${ROOT} — the guard cannot see its subject, refusing to pass`);
}

for (const { file, label, declRe, commentRe } of ANCHORS) {
  // `///` unless the entry says otherwise — see the SettingsManager entry.
  const commentLine = commentRe ?? /^\s*\/\/\//;
  const text = read(file);
  if (text === null) {
    failures.push(`${file}: file not found — anchor "${label}" cannot be verified`);
    continue;
  }
  const lines = text.split('\n');
  const idx = lines.findIndex((l) => declRe.test(l));
  if (idx === -1) {
    failures.push(`${file}: anchor declaration "${label}" not found — the guard cannot verify the doc block above it`);
    continue;
  }
  const block = [];
  for (let i = idx - 1; i >= 0 && commentLine.test(lines[i]); i--) block.unshift(lines[i]);
  if (block.length === 0) {
    failures.push(`${file}:${idx + 1}: no doc comment directly above "${label}" — restore the explanation; this guard verifies it carries no count`);
    continue;
  }
  const m = block.join('\n').match(COUNT_IN_PROSE);
  if (m) {
    failures.push(`${file}:${idx + 1 - block.length}..${idx}: doc block above "${label}" carries a language count ("${m[0]}") — the set's size is not a marketed figure (#2368); describe what it is, with no number`);
  }
}

for (const f of failures) console.error(`FAIL: ${f}`);
console.log(
  `language count: ${SITES.length} claim sites carry "${COUNT}" (vendor: Argmax/WhisperKit), ${failures.length} failure(s)`
);
process.exit(failures.length ? 1 : 0);
