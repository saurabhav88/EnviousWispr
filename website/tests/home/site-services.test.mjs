import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const SRC_DIR = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../../src');

test('SiteServices session replay masks reflected help-search status text', () => {
  const services = fs.readFileSync(path.join(SRC_DIR, 'components/SiteServices.astro'), 'utf8');
  const helpSearch = fs.readFileSync(path.join(SRC_DIR, 'components/HelpSearch.astro'), 'utf8');
  assert.match(helpSearch, /id="help-search-status"/);
  assert.match(services, /maskTextSelector:\s*['"][^'"]*#help-search-status[^'"]*['"]/);
});
