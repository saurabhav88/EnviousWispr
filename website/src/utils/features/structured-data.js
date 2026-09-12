// JSON-LD builders for the features launch pages (#2816): WebPage and
// BreadcrumbList on every page, ItemList on the directory. Same convention as
// speech-to-text-mac.astro and compare/index.astro: built in frontmatter,
// injected through the head slot.
import { catalog, itemList } from '../../data/site-navigation.js';

const SITE = 'https://enviouswispr.com';

export function webPage({ path, name, description, updated }) {
  return {
    '@context': 'https://schema.org',
    '@type': path === '/features/' ? 'CollectionPage' : 'WebPage',
    name,
    description,
    url: `${SITE}${path}`,
    dateModified: updated,
    isPartOf: { '@type': 'WebSite', name: 'EnviousWispr', url: `${SITE}/` },
    about: { '@type': 'SoftwareApplication', name: 'EnviousWispr', operatingSystem: 'macOS 14+', applicationCategory: 'ProductivityApplication' },
  };
}

export function breadcrumbs(path, name) {
  const items = [{ '@type': 'ListItem', position: 1, name: 'Home', item: `${SITE}/` }];
  if (path.startsWith('/features/') && path !== '/features/') {
    items.push({ '@type': 'ListItem', position: 2, name: 'Features', item: `${SITE}/features/` });
  }
  items.push({ '@type': 'ListItem', position: items.length + 1, name, item: `${SITE}${path}` });
  return { '@context': 'https://schema.org', '@type': 'BreadcrumbList', itemListElement: items };
}

export function featureItemList() {
  return {
    '@context': 'https://schema.org',
    '@type': 'ItemList',
    name: 'EnviousWispr features',
    itemListElement: itemList.map((entry, i) => ({ '@type': 'ListItem', position: i + 1, name: entry.name, url: `${SITE}${entry.path}` })),
  };
}

/** The catalog entry for a page path; throws so a typo fails the build. */
export function entryFor(path) {
  const entry = catalog.find((e) => e.path === path);
  if (!entry) throw new Error(`structured-data: ${path} is not in the catalog`);
  return entry;
}
