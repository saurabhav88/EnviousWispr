#!/usr/bin/env node
// Checks that every built page under dist/ is reachable from / by `<a href>` links.
// Fixed-path entrypoint (no argv/env seam); runs in `npm run check:site` and deploy-blog.yml.
import path from 'node:path';
import { checkReachability } from './lib/orphan-check.mjs';

const result = checkReachability(path.join(process.cwd(), 'dist'));
if (!result.ok) {
  console.error(result.message);
  process.exit(1);
}
console.log(result.message);
