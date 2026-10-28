#!/usr/bin/env node
// Talker rules check (#4013). Runs from `npm run check:help` after `npm run build`.
//
// The app downloads public/meet/talker-rules.json at most once a day and decodes it with
// TalkerRules.decode (Sources/EnviousWisprServices/TalkerRules.swift). A hosted file that decoder
// refuses leaves every user on the bundled copy, so this check fails first:
//   1. the hosted file, the built copy in dist/ and the app's bundled copy are byte-identical;
//   2. the hosted file passes the schema below;
//   3. the schema below agrees with talker-rules-fixtures.json, the same literal documents
//      TalkerRulesTests runs through the Swift decoder, so the two validators cannot drift apart.
import fs from 'node:fs';
import path from 'node:path';

const root = process.cwd();
const hosted = path.join(root, 'public/meet/talker-rules.json');
const built = path.join(root, 'dist/meet/talker-rules.json');
const bundled = path.join(root, '../Sources/EnviousWisprServices/Resources/talker-rules.json');
const fixturesFile = path.join(root, 'scripts/talker-rules-fixtures.json');

const MAX_BYTES = 32 * 1024;
const LAG_BOUND_MS = 5000;
const MAX_REVISION = 1000000000;
const MAX_TALKING = 8;
const SURFACES = [
  'zoom_app', 'teams_app', 'zoom_web', 'teams_web', 'meet', 'slack_app', 'slack_web',
  'facetime', 'webex', 'dialpad', 'gather', 'lark', 'voov', 'whereby', 'jitsi',
];
const NATIVE = new Set(['zoom_app', 'teams_app', 'zoom_web']);
const ROSTER_ONLY = new Set(['facetime', 'webex', 'dialpad', 'gather', 'lark', 'voov', 'whereby', 'jitsi']);
const TOKEN = /^[A-Za-z_-][A-Za-z0-9_-]{0,99}$/;
const ROLE = /^AX[A-Za-z]{1,40}$/;

const isObject = (v) => v !== null && typeof v === 'object' && !Array.isArray(v);
const isInt = (v) => typeof v === 'number' && Number.isInteger(v);

/** Returns the first problem, or null when the document is valid. Mirrors TalkerRules.decode. */
export function problem(doc) {
  if (!isObject(doc)) return 'document is not an object';
  const unknown = Object.keys(doc).find((k) => !['schema', 'revision', 'lagMs', 'selectors'].includes(k));
  if (unknown) return `unknown field ${unknown}`;
  if (!isInt(doc.schema)) return 'schema';
  if (doc.schema !== 1) return 'unsupported schema';
  if (!isInt(doc.revision) || doc.revision < 0 || doc.revision > MAX_REVISION) return 'revision';
  if (!isObject(doc.lagMs)) return 'lagMs';
  for (const [key, value] of Object.entries(doc.lagMs)) {
    if (!SURFACES.includes(key)) return `lagMs.${key}: unknown surface`;
    if (!isInt(value) || value < -LAG_BOUND_MS || value > LAG_BOUND_MS) return `lagMs.${key}`;
  }
  if (!Array.isArray(doc.selectors)) return 'selectors';
  const seen = new Set();
  for (const [index, entry] of doc.selectors.entries()) {
    const at = `selectors[${index}]`;
    if (!isObject(entry)) return `${at}: not an object`;
    const allowed = ['surface', 'tileRole', 'tileClass', 'nameSource', 'nameSuffix', 'talkingClasses',
      'participantListClass', 'verification', 'tilesAreParticipants'];
    const extra = Object.keys(entry).find((k) => !allowed.includes(k));
    if (extra) return `${at}: unknown field ${extra}`;
    if (!SURFACES.includes(entry.surface)) return `${at}.surface`;
    if (NATIVE.has(entry.surface)) return `${at}.surface has a native reader`;
    for (const key of ['tileRole', 'tileClass', 'nameSuffix', 'participantListClass']) {
      if (key in entry && typeof entry[key] !== 'string') return `${at}.${key}`;
    }
    if ('tileRole' in entry && !ROLE.test(entry.tileRole)) return `${at}.tileRole`;
    if ('tileClass' in entry && !TOKEN.test(entry.tileClass)) return `${at}.tileClass`;
    if ('participantListClass' in entry && !TOKEN.test(entry.participantListClass)) {
      return `${at}.participantListClass`;
    }
    if (entry.nameSource === 'firstStaticText') {
      if ('nameSuffix' in entry) return `${at}.nameSuffix needs nameSource ownLabel`;
    } else if (entry.nameSource === 'ownLabel') {
      if (entry.nameSuffix === '') return `${at}.nameSuffix is empty`;
    } else {
      return `${at}.nameSource`;
    }
    const talking = entry.talkingClasses;
    if (!Array.isArray(talking) || talking.length > MAX_TALKING) return `${at}.talkingClasses`;
    if (talking.some((t, i) => typeof t !== 'string' || !TOKEN.test(t) || talking.indexOf(t) !== i)) {
      return `${at}.talkingClasses`;
    }
    if (!['verified', 'unverified'].includes(entry.verification)) return `${at}.verification`;
    if ('tilesAreParticipants' in entry && typeof entry.tilesAreParticipants !== 'boolean') {
      return `${at}.tilesAreParticipants`;
    }
    const hasTile = 'tileRole' in entry || 'tileClass' in entry;
    if (entry.tilesAreParticipants === true && !hasTile) {
      return `${at}: tilesAreParticipants without a tile selector`;
    }
    if (talking.length > 0 && !hasTile) return `${at}: talkingClasses without a tile selector`;
    if ('tileClass' in entry && talking.includes(entry.tileClass)) return `${at}: talking class equals tile class`;
    if (entry.verification === 'verified' && talking.length === 0) return `${at}: verified without talkingClasses`;
    if (ROSTER_ONLY.has(entry.surface) && (talking.length > 0 || entry.verification === 'verified')) {
      return `${at}: roster-only`;
    }
    if (entry.nameSource === 'ownLabel' && !hasTile) return `${at}: ownLabel without a tile selector`;
    if (seen.has(entry.surface)) return `${at}: second entry for ${entry.surface}`;
    seen.add(entry.surface);
  }
  return null;
}

function main() {
  const problems = [];
  for (const file of [hosted, built, bundled, fixturesFile]) {
    if (!fs.existsSync(file)) problems.push(`missing ${path.relative(root, file)}`);
  }
  if (problems.length === 0) {
    const bytes = fs.readFileSync(hosted);
    if (!bytes.equals(fs.readFileSync(built))) problems.push('dist/meet/talker-rules.json differs from the hosted file');
    if (!bytes.equals(fs.readFileSync(bundled))) problems.push('the app bundle copy differs from the hosted file');
    if (bytes.length > MAX_BYTES) problems.push(`hosted file is ${bytes.length} bytes, over ${MAX_BYTES}`);
    let doc;
    try {
      doc = JSON.parse(bytes.toString('utf8'));
    } catch (error) {
      problems.push(`hosted file is not JSON: ${error.message}`);
    }
    if (doc !== undefined) {
      const p = problem(doc);
      if (p) problems.push(`hosted file: ${p}`);
    }

    const { fixtures } = JSON.parse(fs.readFileSync(fixturesFile, 'utf8'));
    if (!Array.isArray(fixtures) || fixtures.length === 0) problems.push('no fixtures');
    let accepted = 0;
    let rejected = 0;
    for (const f of fixtures ?? []) {
      const p = problem(f.document);
      if (f.accept && p) problems.push(`fixture "${f.name}" should pass but: ${p}`);
      if (!f.accept && !p) problems.push(`fixture "${f.name}" should fail but passed`);
      if (f.accept) accepted += 1;
      else rejected += 1;
    }
    if (accepted === 0 || rejected === 0) problems.push('fixtures need both accepted and rejected documents');
    if (problems.length === 0) {
      console.log(`OK: talker rules valid and identical in 3 places; ${accepted} accepted and ${rejected} rejected fixtures agree.`);
    }
  }
  if (problems.length > 0) {
    for (const p of problems) console.error(`FAIL: ${p}`);
    process.exit(1);
  }
}

main();
