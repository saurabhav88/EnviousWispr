// The two entities every page's JSON-LD talks about, defined once. Pages used to
// describe the publisher five different ways (name "Envious Labs" or "Envious Labs
// LLC", url enviouslabs.co or enviouswispr.com, sameAs on one page of 149). One
// stable @id per entity lets search engines and AI crawlers join them into one
// organisation and one app. The full Organization node, with address, contact and
// sameAs, is published on the homepage (components/home/StructuredData.astro).
export const SITE = 'https://enviouswispr.com';
export const ORG_ID = `${SITE}/#organization`;
export const APP_ID = `${SITE}/#app`;
export const ANDROID_APP_ID = `${SITE}/android/#app`;

/** The publisher, author or employer reference used on every page. */
export const ORG_REF = {
  '@type': 'Organization',
  '@id': ORG_ID,
  name: 'Envious Labs',
  url: 'https://enviouslabs.co',
  logo: { '@type': 'ImageObject', url: `${SITE}/favicon.svg` },
};

export const ORG_SAME_AS = [
  'https://x.com/EnviousLabs',
  'https://www.youtube.com/@EnviousLabs',
  'https://www.linkedin.com/company/envious-labs/',
  'https://github.com/Envious-Labs-LLC',
  'https://github.com/saurabhav88/EnviousWispr',
];

/** The app, as the subject of a feature or guide page. */
export const APP_REF = {
  '@type': 'SoftwareApplication',
  '@id': APP_ID,
  name: 'EnviousWispr',
  operatingSystem: 'macOS 14+',
  applicationCategory: 'ProductivityApplication',
  offers: { '@type': 'Offer', price: '0', priceCurrency: 'USD' },
};

/**
 * EnviousWispr for Android (#4161, #4171), the full node: published on the homepage
 * beside the Mac app and on /android/, under one @id. Name, requirement and wording
 * follow the Play listing (EnviousWispr-Android docs/play-listing/store-listing.md).
 */
export const ANDROID_APP = {
  '@type': 'MobileApplication',
  '@id': ANDROID_APP_ID,
  name: 'EnviousWispr: Voice to Text',
  alternateName: 'EnviousWispr for Android',
  operatingSystem: 'Android 13+',
  applicationCategory: 'ProductivityApplication',
  description:
    'Free on-device dictation for Android with built-in AI polish. Tap the bubble, speak, and finished text lands where you type. Your voice never leaves your phone.',
  url: `${SITE}/android/`,
  downloadUrl: 'https://play.google.com/store/apps/details?id=com.envi.wispr',
  installUrl: 'https://play.google.com/store/apps/details?id=com.envi.wispr',
  offers: { '@type': 'Offer', price: '0', priceCurrency: 'USD' },
  author: ORG_REF,
  publisher: ORG_REF,
};
