// Tests for the help article clip contract (#3703). Positive cases first, then one negative for each
// rejection the contract names, so a loosened rule fails here and not in a reader's browser.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { test } from 'node:test';
import { checkRenderedMedia, readMediaFields, validateMedia } from './help-media-contract.mjs';

const publicDir = fs.mkdtempSync(path.join(os.tmpdir(), 'help-media-contract-'));
fs.mkdirSync(path.join(publicDir, 'help-media'));
fs.writeFileSync(path.join(publicDir, 'help-media', 'clip-one.mp4'), 'x');
fs.writeFileSync(path.join(publicDir, 'help-media', 'clip-one-poster.jpg'), 'x');
fs.writeFileSync(path.join(publicDir, 'help-media', 'clip-one-poster.webp'), 'x');

const article = (fields) => `---\ntitle: "T"\n${fields}\ndeflection: "can_resolve"\n---\nBody.\n`;
const GOOD = [
  'video: "/help-media/clip-one.mp4"',
  'videoPoster: "/help-media/clip-one-poster.jpg"',
  'videoDescription: "It shows three parts."',
].join('\n');
const problems = (fields) => validateMedia('a.md', article(fields), publicDir);

test('no media fields is valid', () => {
  assert.deepEqual(problems('order: 1'), []);
});

test('all three valid fields pass', () => {
  assert.deepEqual(problems(GOOD), []);
});

test('a poster as webp passes', () => {
  assert.deepEqual(problems(GOOD.replace('clip-one-poster.jpg', 'clip-one-poster.webp')), []);
});

test('a description with a colon, escaped quotation marks and a backslash decodes and passes', () => {
  const description = 'videoDescription: "Part one: a \\"quoted\\" word and a back\\\\slash."';
  assert.deepEqual(problems([GOOD.split('\n').slice(0, 2).join('\n'), description].join('\n')), []);
  const { fields } = readMediaFields(description);
  assert.equal(fields.videoDescription, 'Part one: a "quoted" word and a back\\slash.');
});

test('video without both companions is rejected', () => {
  const out = problems('video: "/help-media/clip-one.mp4"');
  assert.ok(out.some((p) => p.includes('videoPoster is required')));
  assert.ok(out.some((p) => p.includes('videoDescription is required')));
});

test('a poster or a description without video is rejected', () => {
  assert.ok(problems('videoPoster: "/help-media/clip-one-poster.jpg"').some((p) => p.includes('video is required')));
  assert.ok(problems('videoDescription: "Words."').some((p) => p.includes('video is required')));
});

test('a wrong extension, uppercase name, nested path, query, fragment and traversal are rejected', () => {
  for (const bad of [
    '/help-media/clip-one.webm',
    '/help-media/Clip-One.mp4',
    '/help-media/a/clip-one.mp4',
    '/help-media/clip-one.mp4?x=1',
    '/help-media/clip-one.mp4#t=1',
    '/help-media/../clip-one.mp4',
    '/other/clip-one.mp4',
    'help-media/clip-one.mp4',
    '/help-media/-clip.mp4',
  ]) {
    const out = problems(GOOD.replace('/help-media/clip-one.mp4', bad));
    assert.ok(out.some((p) => p.includes('video must be')), `${bad} -> ${JSON.stringify(out)}`);
  }
  const poster = problems(GOOD.replace('clip-one-poster.jpg', 'clip-one-poster.gif'));
  assert.ok(poster.some((p) => p.includes('videoPoster must be')));
});

test('a file that is absent, or is a folder, is rejected', () => {
  const absent = problems(GOOD.replace('clip-one.mp4', 'clip-two.mp4'));
  assert.ok(absent.some((p) => p.includes('is not a file under public/')));
  fs.mkdirSync(path.join(publicDir, 'help-media', 'folder.mp4'));
  const folder = problems(GOOD.replace('clip-one.mp4', 'folder.mp4'));
  assert.ok(folder.some((p) => p.includes('is not a file under public/')));
});

test('a duplicate field is rejected', () => {
  const out = problems(`${GOOD}\nvideo: "/help-media/clip-one.mp4"`);
  assert.ok(out.some((p) => p.includes('video appears 2 times')));
});

test('a blank description, a YAML single-quoted value and a bare value are rejected', () => {
  assert.ok(problems(GOOD.replace('"It shows three parts."', '"   "')).some((p) => p.includes('videoDescription is blank')));
  assert.ok(problems(GOOD.replace('"/help-media/clip-one.mp4"', "'/help-media/clip-one.mp4'")).some((p) => p.includes('video is not one double-quoted JSON string')));
  assert.ok(problems(GOOD.replace('"/help-media/clip-one.mp4"', '/help-media/clip-one.mp4')).some((p) => p.includes('video is not one double-quoted JSON string')));
});

test('an em or an en dash in the description is rejected', () => {
  for (const dash of ['—', '–']) {
    const out = problems(GOOD.replace('three parts.', `three ${dash} parts.`));
    assert.ok(out.some((p) => p.includes('em or en dash')), JSON.stringify(out));
  }
});

test('a spaced or quoted key is still a declaration and is rejected as non-canonical', () => {
  for (const key of ['video :', '"video":', "'video':"]) {
    const out = problems(GOOD.replace('video:', key));
    assert.ok(out.some((p) => p.includes('video must be an unquoted key')), `${key} -> ${JSON.stringify(out)}`);
  }
  const alone = problems('video : "/help-media/clip-one.mp4"');
  assert.ok(alone.some((p) => p.includes('videoPoster is required')), JSON.stringify(alone));
});

test('an indented lookalike is not a top-level field', () => {
  assert.deepEqual(problems('related:\n  video: "x"'), []);
});

// Built-page side.
const FIELDS = {
  video: '/help-media/clip-one.mp4',
  videoPoster: '/help-media/clip-one-poster.jpg',
  videoDescription: 'It shows three parts.',
};
const PAGE = `<figure><video controls preload="none" playsinline poster="/help-media/clip-one-poster.jpg" aria-describedby="help-video-desc"><source src="/help-media/clip-one.mp4" type="video/mp4"></video><figcaption id="help-video-desc">Silent demonstration. It shows three parts.</figcaption></figure>`;

test('a correctly rendered page passes', () => {
  assert.deepEqual(checkRenderedMedia(PAGE, FIELDS), []);
});

test('an article with no clip renders no video; one that renders a video without declaring it fails', () => {
  assert.deepEqual(checkRenderedMedia('<p>text</p>', {}), []);
  assert.equal(checkRenderedMedia(PAGE, {}).length, 1);
});

test('each rendering defect is caught', () => {
  const cases = {
    'no source': PAGE.replace(/<source[^>]*>/, ''),
    'wrong type': PAGE.replace('video/mp4', 'video/webm'),
    'autoplay': PAGE.replace('<video ', '<video autoplay '),
    'loop': PAGE.replace('<video ', '<video loop '),
    'no controls': PAGE.replace(' controls', ''),
    'preload auto': PAGE.replace('preload="none"', 'preload="auto"'),
    'wrong poster': PAGE.replace('clip-one-poster.jpg', 'other.jpg'),
    'no aria-describedby': PAGE.replace(' aria-describedby="help-video-desc"', ''),
    'dangling aria-describedby': PAGE.replace('id="help-video-desc"', 'id="elsewhere"'),
    'empty caption': PAGE.replace('Silent demonstration. It shows three parts.', ' '),
    'two videos': PAGE + PAGE,
  };
  for (const [name, html] of Object.entries(cases)) {
    assert.ok(checkRenderedMedia(html, FIELDS).length > 0, `${name} was not caught`);
  }
});
