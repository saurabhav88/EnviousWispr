import fs from 'node:fs';
import path from 'node:path';
import { internalLinks } from './dist-links.mjs';

function fail(message, routes = [], reached = [], unreachable = []) {
  return { ok: false, message, routes, reached, unreachable };
}

function collectRoutes(distDir) {
  const routeMap = new Map();

  function walk(currentDir) {
    const entries = fs.readdirSync(currentDir, { withFileTypes: true });
    for (const entry of entries) {
      const fullPath = path.join(currentDir, entry.name);
      const relPosix = path.relative(distDir, fullPath).split(path.sep).join('/');

      if (entry.isDirectory()) {
        walk(fullPath);
        continue;
      }
      if (!entry.isFile() && !entry.isSymbolicLink()) continue;
      if (relPosix === '404.html') continue;
      if (entry.name !== 'index.html') continue;

      const dirPosix = path.posix.dirname(relPosix);
      const route = dirPosix === '.' ? '/' : `/${dirPosix}/`;
      routeMap.set(route, fullPath);
    }
  }

  walk(distDir);
  return new Map([...routeMap.entries()].sort(([a], [b]) => a.localeCompare(b)));
}

/**
 * Walks built HTML files under `distDir` from `/` via `<a href>` edges and
 * fails closed if `distDir` is missing/empty, `/` is absent, any page cannot
 * be read, or any route is unreachable from `/`.
 */
export function checkReachability(distDir) {
  let stats;
  try {
    stats = fs.statSync(distDir);
  } catch (err) {
    return fail(`FAIL: dist directory unavailable (${distDir}): ${err.message}`);
  }
  if (!stats.isDirectory()) {
    return fail(`FAIL: dist path is not a directory (${distDir})`);
  }

  let routeMap;
  try {
    routeMap = collectRoutes(distDir);
  } catch (err) {
    return fail(`FAIL: failed reading dist directory (${distDir}): ${err.message}`);
  }

  const routes = [...routeMap.keys()];
  if (routes.length === 0) {
    return fail(`FAIL: zero routes found under ${distDir}`);
  }
  if (!routeMap.has('/')) {
    return fail(
      `FAIL: missing root /index.html in ${distDir} (${routes.length} other route(s) present)`,
      routes,
      [],
      routes,
    );
  }

  const htmlByRoute = new Map();
  for (const [route, filePath] of routeMap) {
    try {
      htmlByRoute.set(route, fs.readFileSync(filePath, 'utf8'));
    } catch (err) {
      return fail(`FAIL: unreadable page ${filePath}: ${err.message}`, routes, [], routes);
    }
  }

  const visited = new Set(['/']);
  const queue = ['/'];
  while (queue.length > 0) {
    const current = queue.shift();
    for (const target of internalLinks(htmlByRoute.get(current), current)) {
      if (routeMap.has(target) && !visited.has(target)) {
        visited.add(target);
        queue.push(target);
      }
    }
  }

  const reached = [...visited].sort();
  const unreachable = routes.filter((r) => !visited.has(r));
  if (unreachable.length > 0) {
    const list = unreachable.map((r) => `  - ${r}`).join('\n');
    return fail(
      `FAIL: ${unreachable.length} unreachable route(s) (${reached.length}/${routes.length} reachable from /):\n${list}`,
      routes,
      reached,
      unreachable,
    );
  }

  return {
    ok: true,
    message: `PASS: ${routes.length} routes, ${reached.length} reachable from /`,
    routes,
    reached,
    unreachable: [],
  };
}
