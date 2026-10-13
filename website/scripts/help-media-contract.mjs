// Contract for the optional clip a help article can carry (#3703).
//
// An article declares a silent clip with three top-level frontmatter fields, each ONE line holding ONE
// double-quoted JSON string:
//
//   video: "/help-media/push-to-talk-modes.mp4"
//   videoPoster: "/help-media/push-to-talk-modes-poster.jpg"
//   videoDescription: "What the clip shows, in words."
//
// The fields are optional as a group: all three or none. JSON quoting is the supported subset; YAML-only
// quoting and escaping are rejected on purpose, so there is one decoding rule (`JSON.parse`) and no
// reading of a field two ways. The instructional equivalent of the clip stays in the article's Markdown
// (WCAG 1.2.1); `videoDescription` only says what the clip shows.
//
// Used by scripts/check-help-content.mjs (source side, runs in `npm run build` via prebuild) and by
// scripts/check-help-media.mjs (built-page side, runs in `npm run check:help`).
import fs from 'node:fs';
import path from 'node:path';

export const MEDIA_FIELDS = ['video', 'videoPoster', 'videoDescription'];

const VIDEO_PATH = /^\/help-media\/[a-z0-9][a-z0-9-]*\.mp4$/;
const POSTER_PATH = /^\/help-media\/[a-z0-9][a-z0-9-]*\.(jpg|png|webp)$/;
const DASH = /[—–]/;

/** The frontmatter block of an article, or null when there is none. */
export function frontmatterBlock(source) {
  const m = source.match(/^---\n([\s\S]*?)\n---\n/);
  return m ? m[1] : null;
}

function declaredLines(lines, name) {
  return lines.filter((line) => line.startsWith(`${name}:`));
}

// Any top-level spelling YAML reads as this key: `video:`, `video :`, `"video":`, `'video':`. The page
// schema accepts all of them, so the all-three-or-none rule must see them; only the first is canonical.
function mentionedLines(lines, name) {
  const loose = new RegExp(`^["']?${name}["']?\\s*:`);
  return lines.filter((line) => loose.test(line));
}

/**
 * Reads the three media fields from a frontmatter block.
 * Returns the decoded values that parsed and the problems found; a field that appears more than once,
 * is not one JSON string, or is blank is a problem and is left out of `fields`.
 */
export function readMediaFields(frontmatter) {
  const lines = frontmatter.split('\n');
  const fields = {};
  const errors = [];
  for (const name of MEDIA_FIELDS) {
    const hits = declaredLines(lines, name);
    if (hits.length === 0) continue;
    if (hits.length > 1) {
      errors.push(`${name} appears ${hits.length} times`);
      continue;
    }
    let value;
    try {
      value = JSON.parse(hits[0].slice(name.length + 1).trim());
    } catch {
      errors.push(`${name} is not one double-quoted JSON string`);
      continue;
    }
    if (typeof value !== 'string' || !value.trim()) {
      errors.push(`${name} is blank or not a string`);
      continue;
    }
    fields[name] = value;
  }
  return { fields, errors };
}

/**
 * Source-side check of one article. `publicDir` is the website's `public/` folder.
 * Returns problem strings, each starting with the file name. No media fields is valid.
 */
export function validateMedia(file, source, publicDir) {
  const frontmatter = frontmatterBlock(source);
  if (frontmatter === null) return [`${file}: no frontmatter block`];
  const lines = frontmatter.split('\n');
  const declared = MEDIA_FIELDS.filter((name) => mentionedLines(lines, name).length > 0);
  if (declared.length === 0) return [];

  const { fields, errors: readErrors } = readMediaFields(frontmatter);
  const problems = readErrors.map((e) => `${file}: ${e}`);
  for (const name of declared) {
    if (declaredLines(lines, name).length === 0) {
      problems.push(`${file}: ${name} must be an unquoted key followed at once by a colon`);
    }
  }

  for (const name of MEDIA_FIELDS) {
    if (!declared.includes(name)) problems.push(`${file}: ${name} is required when any media field is set`);
  }
  if (fields.video !== undefined && !VIDEO_PATH.test(fields.video)) {
    problems.push(`${file}: video must be /help-media/<lowercase-name>.mp4, got ${JSON.stringify(fields.video)}`);
  }
  if (fields.videoPoster !== undefined && !POSTER_PATH.test(fields.videoPoster)) {
    problems.push(
      `${file}: videoPoster must be /help-media/<lowercase-name>.jpg, .png or .webp, got ${JSON.stringify(fields.videoPoster)}`,
    );
  }
  if (fields.videoDescription !== undefined && DASH.test(fields.videoDescription)) {
    problems.push(`${file}: videoDescription has an em or en dash (global Rule 6)`);
  }
  for (const [name, regex] of [['video', VIDEO_PATH], ['videoPoster', POSTER_PATH]]) {
    const value = fields[name];
    if (value === undefined || !regex.test(value)) continue;
    let isFile = false;
    try {
      isFile = fs.statSync(path.join(publicDir, value)).isFile();
    } catch {
      isFile = false;
    }
    if (!isFile) problems.push(`${file}: ${name} ${value} is not a file under public/`);
  }
  return problems;
}

/**
 * Built-page side: what the rendered article must contain for an article that declares a clip, or must
 * NOT contain for one that does not. `fields` is `readMediaFields(...).fields` of the source, empty for an
 * article without a clip. Returns problem strings.
 */
export function checkRenderedMedia(html, fields) {
  const videoTags = html.match(/<video\b[^>]*>/g) ?? [];
  if (fields.video === undefined) {
    return videoTags.length === 0 ? [] : [`renders ${videoTags.length} <video> but declares no clip`];
  }
  const problems = [];
  if (videoTags.length !== 1) return [`expected exactly one <video>, found ${videoTags.length}`];
  const tag = videoTags[0];
  if (!/\scontrols(\s|=|>|\/)/.test(tag)) problems.push('<video> has no controls');
  if (!/\spreload="none"/.test(tag)) problems.push('<video> is not preload="none"');
  if (!tag.includes(`poster="${fields.videoPoster}"`)) problems.push(`<video> poster is not ${fields.videoPoster}`);
  if (/\sautoplay(\s|=|>|\/)/.test(tag)) problems.push('<video> autoplays');
  if (/\sloop(\s|=|>|\/)/.test(tag)) problems.push('<video> loops');
  const sources = html.match(/<source\b[^>]*>/g) ?? [];
  const matching = sources.filter(
    (s) => s.includes(`src="${fields.video}"`) && s.includes('type="video/mp4"'),
  );
  if (matching.length !== 1) problems.push(`expected one <source src="${fields.video}" type="video/mp4">, found ${matching.length}`);
  const described = tag.match(/\saria-describedby="([^"]+)"/);
  if (!described) {
    problems.push('<video> has no aria-describedby');
  } else {
    const target = html.match(new RegExp(`<figcaption\\b[^>]*\\sid="${described[1]}"[^>]*>([\\s\\S]*?)</figcaption>`));
    if (!target || !target[1].replace(/<[^>]*>/g, '').trim()) {
      problems.push(`aria-describedby ${described[1]} does not resolve to a nonempty <figcaption>`);
    }
  }
  return problems;
}
