#!/usr/bin/env node
// Self-mute rules check (#4248, #4013 reading resilience). Runs from `npm run check:help` after
// `npm run build`.
//
// The app downloads public/meet/call-mute-rules.json at most once a day and validates it with
// CallMuteRules(validating:) (Sources/EnviousWisprServices/CallSelfMuteReader.swift). A hosted
// file that validator refuses leaves every user on the bundled copy, so this check fails first:
//   1. the hosted file, the built copy in dist/ and the app's bundled copy are byte-identical;
//   2. the hosted file passes the schema below;
//   3. the schema below agrees with call-mute-rules-fixtures.json, the same literal documents
//      CallSelfMuteReaderTests runs through the Swift validator, so the two cannot drift apart.
// A bad hosted file is corrected by publishing a fixed one with a higher revision, never by
// lowering the revision: the app keeps any cached revision that is higher.
import fs from 'node:fs';
import path from 'node:path';

const root = process.cwd();
const hosted = path.join(root, 'public/meet/call-mute-rules.json');
const built = path.join(root, 'dist/meet/call-mute-rules.json');
const bundled = path.join(root, '../Sources/EnviousWisprServices/Resources/call-mute-rules.json');
const fixturesFile = path.join(root, 'scripts/call-mute-rules-fixtures.json');

const MAX_BYTES = 16 * 1024;
const MAX_REVISION = 1000000000;
const SURFACES = ['zoom_app', 'teams_app', 'meet'];
const ROLE = /^AX[A-Za-z]{1,40}$/;
const STATES = ['muted', 'unmuted'];

const isObject = (v) => v !== null && typeof v === 'object' && !Array.isArray(v);
const isInt = (v) => typeof v === 'number' && Number.isInteger(v);
const optionalText = (entry, key) => !(key in entry) || (typeof entry[key] === 'string' && entry[key] !== '');

/** Returns the first problem, or null when the document is valid. Mirrors CallMuteRules(validating:). */
export function problem(doc) {
  if (!isObject(doc)) return 'document is not an object';
  const unknown = Object.keys(doc).find((k) => !['schema', 'revision', 'surfaces'].includes(k));
  if (unknown) return `unknown field ${unknown}`;
  if (!isInt(doc.schema) || doc.schema !== 1) return 'schema';
  if (!isInt(doc.revision) || doc.revision < 1 || doc.revision > MAX_REVISION) return 'revision';
  if (!isObject(doc.surfaces)) return 'surfaces';
  for (const [surface, entry] of Object.entries(doc.surfaces)) {
    const at = `surfaces.${surface}`;
    if (!SURFACES.includes(surface)) return `${at}: unsupported surface`;
    if (!isObject(entry)) return `${at}: not an object`;
    const extra = Object.keys(entry).find((k) => !['role', 'identifier', 'domIdentifier', 'labels'].includes(k));
    if (extra) return `${at}: unknown field ${extra}`;
    if (typeof entry.role !== 'string' || !ROLE.test(entry.role)) return `${at}.role`;
    if (!optionalText(entry, 'identifier')) return `${at}.identifier`;
    if (!optionalText(entry, 'domIdentifier')) return `${at}.domIdentifier`;
    if ('identifier' in entry && 'domIdentifier' in entry) return `${at}: both identifier and domIdentifier`;
    if (!isObject(entry.labels)) return `${at}.labels`;
    const states = new Set();
    for (const [label, state] of Object.entries(entry.labels)) {
      if (label === '') return `${at}.labels: empty label`;
      if (!STATES.includes(state)) return `${at}.labels.${label}`;
      states.add(state);
    }
    if (states.size !== STATES.length) return `${at}.labels: needs both states`;
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
    if (!bytes.equals(fs.readFileSync(built))) problems.push('dist/meet/call-mute-rules.json differs from the hosted file');
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
      // `raw` fixtures are exact JSON text, so a number's spelling (1.0, 2e0) reaches the check.
      const p = problem('raw' in f ? JSON.parse(f.raw) : f.document);
      if (f.accept && p) problems.push(`fixture "${f.name}" should pass but: ${p}`);
      if (!f.accept && !p) problems.push(`fixture "${f.name}" should fail but passed`);
      if (f.accept) accepted += 1;
      else rejected += 1;
    }
    if (accepted === 0 || rejected === 0) problems.push('fixtures need both accepted and rejected documents');
    if (problems.length === 0) {
      console.log(`OK: call mute rules valid and identical in 3 places; ${accepted} accepted and ${rejected} rejected fixtures agree.`);
    }
  }
  if (problems.length > 0) {
    for (const p of problems) console.error(`FAIL: ${p}`);
    process.exit(1);
  }
}

main();
