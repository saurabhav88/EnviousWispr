import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';
import { checkReachability } from '../scripts/lib/orphan-check.mjs';

const CLI_PATH = fileURLToPath(new URL('../scripts/check-orphan-pages.mjs', import.meta.url));
const DEPLOY_WORKFLOW_PATH = fileURLToPath(
  new URL('../../.github/workflows/deploy-blog.yml', import.meta.url),
);

function withTempWorkspace(pages, fn) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'ew-orphan-test-'));
  try {
    if (pages !== null) {
      const distDir = path.join(root, 'dist');
      fs.mkdirSync(distDir, { recursive: true });
      for (const [relPath, html] of Object.entries(pages)) {
        const target = path.join(distDir, relPath);
        fs.mkdirSync(path.dirname(target), { recursive: true });
        fs.writeFileSync(target, html, 'utf8');
      }
    }
    return fn(root);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
}

function runCli(cwd) {
  const res = spawnSync(process.execPath, [CLI_PATH], { cwd, encoding: 'utf8' });
  return {
    status: res.status,
    output: `${res.stdout ?? ''}${res.stderr ?? ''}`,
  };
}

/**
 * Validates that `.github/workflows/deploy-blog.yml` runs `npm run check:reachability`
 * before `Deploy to Cloudflare Pages` with fail-closed default `success()` semantics.
 */
function reachabilityGateProblems(yamlText) {
  const problems = [];
  const lines = yamlText.split(/\r?\n/);
  const steps = [];
  let inSteps = false;
  let current = null;

  for (const line of lines) {
    if (!inSteps) {
      if (/^ {4}steps:\s*$/.test(line)) {
        inSteps = true;
      }
      continue;
    }

    if (/^ {0,4}[^#\s]/.test(line)) {
      break;
    }

    const stepMatch = line.match(/^ {6}- name:\s*(.+?)\s*$/);
    if (stepMatch) {
      current = {
        name: stepMatch[1].replace(/^(['"])(.*)\1$/, '$2'),
        runs: [],
        workingDirs: [],
        ifs: [],
        continues: [],
      };
      steps.push(current);
      continue;
    }

    if (!current) continue;
    const keyMatch = line.match(/^ {8}([A-Za-z][\w-]*):(.*)$/);
    if (!keyMatch) continue;

    const key = keyMatch[1];
    const value = keyMatch[2].trim().replace(/^(['"])(.*)\1$/, '$2');
    if (key === 'run') current.runs.push(value);
    if (key === 'working-directory') current.workingDirs.push(value);
    if (key === 'if') current.ifs.push(value);
    if (key === 'continue-on-error') current.continues.push(value);
  }

  const checkMatches = steps
    .map((step, index) => ({ step, index }))
    .filter(({ step }) => step.name === 'Check reachability');

  if (checkMatches.length !== 1) {
    problems.push(`expected exactly 1 "Check reachability" step, found ${checkMatches.length}`);
  } else {
    const { step: checkStep, index: checkIdx } = checkMatches[0];
    if (checkStep.runs.length !== 1 || checkStep.runs[0] !== 'npm run check:reachability') {
      problems.push(`Check reachability must have run: npm run check:reachability`);
    }
    if (checkStep.workingDirs.length !== 1 || checkStep.workingDirs[0] !== 'website') {
      problems.push(`Check reachability must have working-directory: website`);
    }
    if (checkStep.ifs.length > 0) {
      problems.push(`Check reachability must not declare an if: condition`);
    }
    if (checkStep.continues.length > 0) {
      problems.push(`Check reachability must not declare continue-on-error`);
    }

    const buildIdx = steps.findIndex((s) => s.name === 'Build Astro site');
    const deployIdx = steps.findIndex((s) => s.name === 'Deploy to Cloudflare Pages');
    if (buildIdx === -1) problems.push('missing "Build Astro site" step');
    if (deployIdx === -1) problems.push('missing "Deploy to Cloudflare Pages" step');
    if (buildIdx !== -1 && checkIdx <= buildIdx) {
      problems.push('"Check reachability" must run after "Build Astro site"');
    }
    if (deployIdx !== -1 && checkIdx >= deployIdx) {
      problems.push('"Check reachability" must run before "Deploy to Cloudflare Pages"');
    }
  }

  const deployMatches = steps.filter((s) => s.name === 'Deploy to Cloudflare Pages');
  if (deployMatches.length !== 1) {
    problems.push(`expected 1 "Deploy to Cloudflare Pages" step, found ${deployMatches.length}`);
  } else {
    const deployStep = deployMatches[0];
    for (const cond of deployStep.ifs) {
      if (/\b(?:always|failure|cancelled)\s*\(/i.test(cond)) {
        problems.push(`deploy step if: must not bypass failures (${cond})`);
      }
    }
  }

  return problems;
}

function mutateOnce(text, pattern, replacement, label) {
  const matches = text.match(new RegExp(pattern.source, pattern.flags.includes('g') ? pattern.flags : `${pattern.flags}g`));
  assert.equal(matches?.length ?? 0, 1, `${label}: expected exactly 1 match`);
  const next = text.replace(pattern, replacement);
  assert.notEqual(next, text, `${label}: mutation produced identical text`);
  return next;
}

test('1. linked page is reachable via function and CLI', () => {
  withTempWorkspace(
    {
      'index.html': '<a href="/a/">A</a>',
      'a/index.html': '<h1>A</h1>',
    },
    (root) => {
      const fnResult = checkReachability(path.join(root, 'dist'));
      assert.equal(fnResult.ok, true);
      assert.deepEqual(fnResult.routes, ['/', '/a/']);
      assert.deepEqual(fnResult.unreachable, []);

      const cli = runCli(root);
      assert.equal(cli.status, 0);
      assert.match(cli.output, /PASS: 2 routes, 2 reachable from \//);
    },
  );
});

test('2. self-link only is orphaned and named in CLI failure', () => {
  withTempWorkspace(
    {
      'index.html': '<p>Home</p>',
      'a/index.html': '<a href="/a/">Self</a>',
    },
    (root) => {
      const fnResult = checkReachability(path.join(root, 'dist'));
      assert.equal(fnResult.ok, false);
      assert.deepEqual(fnResult.unreachable, ['/a/']);

      const cli = runCli(root);
      assert.equal(cli.status, 1);
      assert.match(cli.output, /\/a\//);
    },
  );
});

test('3. two-page island not linked from / reports both routes', () => {
  withTempWorkspace(
    {
      'index.html': '<p>Home</p>',
      'a/index.html': '<a href="/b/">B</a>',
      'b/index.html': '<a href="/a/">A</a>',
    },
    (root) => {
      const fnResult = checkReachability(path.join(root, 'dist'));
      assert.equal(fnResult.ok, false);
      assert.deepEqual(fnResult.unreachable, ['/a/', '/b/']);

      const cli = runCli(root);
      assert.equal(cli.status, 1);
      assert.match(cli.output, /\/a\//);
      assert.match(cli.output, /\/b\//);
    },
  );
});

test('4. absolute same-origin URL with query/fragment counts; missing trailing slash does not', () => {
  withTempWorkspace(
    {
      'index.html':
        '<a href="https://enviouswispr.com/a/?x=1#top">A</a><a href="/b?x=1">B</a>',
      'a/index.html': '<h1>A</h1>',
      'b/index.html': '<h1>B</h1>',
    },
    (root) => {
      const fnResult = checkReachability(path.join(root, 'dist'));
      assert.equal(fnResult.ok, false);
      assert.deepEqual(fnResult.reached, ['/', '/a/']);
      assert.deepEqual(fnResult.unreachable, ['/b/']);

      const cli = runCli(root);
      assert.equal(cli.status, 1);
      assert.match(cli.output, /\/b\//);
    },
  );
});

test('5. non-anchor href (<link>, <script>, </script >, <style>, <article>, HTML comment) leaves page orphaned; quoted > in attr still links', () => {
  withTempWorkspace(
    {
      'index.html':
        '<head><link rel="alternate" href="/a/"><style>/* <a href="/a/"> */</style ></head>' +
        '<body><article href="/a/">ignored</article>' +
        '<!-- <a href="/a/">A</a> -->' +
        '<script>const u="<a href=\\"/a/\\">A</a>";</script >' +
        '<a data-x="1>2" href="/b/">B</a></body>',
      'a/index.html': '<h1>A</h1>',
      'b/index.html': '<h1>B</h1>',
    },
    (root) => {
      const fnResult = checkReachability(path.join(root, 'dist'));
      assert.equal(fnResult.ok, false);
      assert.deepEqual(fnResult.reached, ['/', '/b/']);
      assert.deepEqual(fnResult.unreachable, ['/a/']);

      const cli = runCli(root);
      assert.equal(cli.status, 1);
      assert.match(cli.output, /\/a\//);
    },
  );
});

test('6. missing dist directory fails via CLI with message', () => {
  withTempWorkspace(null, (root) => {
    const cli = runCli(root);
    assert.equal(cli.status, 1);
    assert.match(cli.output, /dist directory unavailable/);
  });
});

test('7. empty dist directory fails with zero routes message', () => {
  withTempWorkspace({}, (root) => {
    const cli = runCli(root);
    assert.equal(cli.status, 1);
    assert.match(cli.output, /zero routes/);
  });
});

test('8. missing root /index.html fails via CLI with message', () => {
  withTempWorkspace(
    {
      'a/index.html': '<h1>A</h1>',
    },
    (root) => {
      const cli = runCli(root);
      assert.equal(cli.status, 1);
      assert.match(cli.output, /missing root \/index\.html/);
    },
  );
});

test('9. unreadable page (chmod 000) fails and names the file', (t) => {
  if (typeof process.getuid === 'function' && process.getuid() === 0) {
    t.skip('cannot enforce chmod 000 read failure when running as root (UID 0)');
    return;
  }

  withTempWorkspace(
    {
      'index.html': '<a href="/a/">A</a>',
      'a/index.html': '<h1>A</h1>',
    },
    (root) => {
      const target = path.join(root, 'dist', 'a', 'index.html');
      fs.chmodSync(target, 0o000);
      try {
        const cli = runCli(root);
        assert.equal(cli.status, 1);
        assert.match(cli.output, /unreadable page .*a\/index\.html/);
      } finally {
        fs.chmodSync(target, 0o644);
      }
    },
  );
});

test('10. root 404.html present and unlinked is excluded from routes and passes', () => {
  withTempWorkspace(
    {
      'index.html': '<h1>Home</h1>',
      '404.html': '<h1>Not found</h1>',
    },
    (root) => {
      const fnResult = checkReachability(path.join(root, 'dist'));
      assert.equal(fnResult.ok, true);
      assert.deepEqual(fnResult.routes, ['/']);

      const cli = runCli(root);
      assert.equal(cli.status, 0);
      assert.match(cli.output, /PASS: 1 routes, 1 reachable from \//);
    },
  );
});

test('11. live-shape chain / -> /why-offline/ -> /speech-to-text-mac/ passes, breaking link fails', () => {
  withTempWorkspace(
    {
      'index.html': '<a href="/why-offline/">Why offline</a>',
      'why-offline/index.html': '<a href="/speech-to-text-mac/">How local speech to text works</a>',
      'speech-to-text-mac/index.html': '<h1>Local Speech to Text on Mac</h1>',
    },
    (root) => {
      assert.equal(runCli(root).status, 0);

      fs.writeFileSync(path.join(root, 'dist/why-offline/index.html'), '<p>No link</p>', 'utf8');
      const broken = runCli(root);
      assert.equal(broken.status, 1);
      assert.match(broken.output, /\/speech-to-text-mac\//);
    },
  );
});

test('12. deploy-blog.yml enforces Check reachability gate before deploy (with 8 negative controls)', () => {
  const realYaml = fs.readFileSync(DEPLOY_WORKFLOW_PATH, 'utf8');
  assert.deepEqual(reachabilityGateProblems(realYaml), []);

  const checkBlockRe = /(      - name: Check reachability\r?\n(?:        .*\r?\n)*)/;
  const deployStepRe = /(      - name: Deploy to Cloudflare Pages\r?\n)/;

  // (a) replace run: npm run check:reachability with run: echo ok
  const mutA = mutateOnce(
    realYaml,
    /(      - name: Check reachability\r?\n        working-directory: website\r?\n        )run: npm run check:reachability/,
    '$1run: echo ok',
    'control (a) benign run',
  );
  assert.ok(reachabilityGateProblems(mutA).length > 0, 'control (a) must fail');

  // (b) add continue-on-error: true to Check reachability
  const mutB = mutateOnce(
    realYaml,
    /(      - name: Check reachability\r?\n)/,
    '$1        continue-on-error: true\n',
    'control (b) continue-on-error',
  );
  assert.ok(reachabilityGateProblems(mutB).length > 0, 'control (b) must fail');

  // (c) add if: always() to Check reachability
  const mutC = mutateOnce(
    realYaml,
    /(      - name: Check reachability\r?\n)/,
    '$1        if: always()\n',
    'control (c) check if: always()',
  );
  assert.ok(reachabilityGateProblems(mutC).length > 0, 'control (c) must fail');

  // (d) remove working-directory: website from Check reachability
  const mutD = mutateOnce(
    realYaml,
    /(      - name: Check reachability\r?\n)        working-directory: website\r?\n/,
    '$1',
    'control (d) remove working-directory',
  );
  assert.ok(reachabilityGateProblems(mutD).length > 0, 'control (d) must fail');

  // (e) comment out step header
  const mutE = mutateOnce(
    realYaml,
    /      - name: Check reachability/,
    '      # - name: Check reachability',
    'control (e) commented header',
  );
  assert.ok(reachabilityGateProblems(mutE).length > 0, 'control (e) must fail');

  // (f) move Check reachability block after Deploy to Cloudflare Pages
  const checkMatch = realYaml.match(checkBlockRe);
  assert.ok(checkMatch, 'real file must match Check reachability block');
  const mutF = `${mutateOnce(realYaml, checkBlockRe, '', 'control (f) strip block')}\n${checkMatch[1]}`;
  assert.ok(reachabilityGateProblems(mutF).length > 0, 'control (f) moved after deploy must fail');

  // (g) add always() to Deploy to Cloudflare Pages (plus whitespace variant)
  const mutG = mutateOnce(
    realYaml,
    /(      - name: Deploy to Cloudflare Pages\r?\n        if: )steps\.decide\.outputs\.deploy == 'true'/,
    "$1always()",
    'control (g) deploy always()',
  );
  assert.ok(reachabilityGateProblems(mutG).length > 0, 'control (g) must fail');
  const mutG2 = mutateOnce(
    realYaml,
    /(      - name: Deploy to Cloudflare Pages\r?\n        if: )steps\.decide\.outputs\.deploy == 'true'/,
    "$1failure ()",
    'control (g2) deploy failure () with space',
  );
  assert.ok(reachabilityGateProblems(mutG2).length > 0, 'control (g2) spaced status fn must fail');

  // (h) duplicate Check reachability step
  const mutH = mutateOnce(
    realYaml,
    checkBlockRe,
    '$1$1',
    'control (h) duplicate Check reachability step',
  );
  assert.ok(reachabilityGateProblems(mutH).length > 0, 'control (h) must fail');
});
