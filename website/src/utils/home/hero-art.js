// The homepage hero background, shared by Hero.astro (which paints it through
// CSS custom properties) and HeroArtPreload.astro (which preloads it from the
// document head). One source of truth for the variants, so the preloaded file
// is byte-for-byte the one hero.css selects.
import { getImage } from 'astro:assets';
import light from '../../assets/home/hero-light.png';
import dark from '../../assets/home/hero-dark.png';

export const widths = [720, 1440, 2160];

// Mirrors the selection in hero.css: index 0 under 600px wide, index 2 on a
// hi-dpi or ≥1600px viewport, index 1 otherwise. The `or` between the two
// index-2 conditions is expressed as two preload links because Safari 17
// (macOS 14, the oldest supported Mac) does not parse `or` inside a media query.
export const variantMedia = [
  ['(max-width: 600px)'],
  ['(min-width: 601px) and (max-width: 1599px) and (max-resolution: 1.49dppx)'],
  ['(min-width: 601px) and (min-resolution: 1.5dppx)', '(min-width: 1600px)'],
];

export async function heroArt() {
  const [lightSet, darkSet] = await Promise.all(
    [light, dark].map((src) =>
      Promise.all(widths.map((width) => getImage({ src, width, format: 'webp', quality: 85 }))),
    ),
  );
  return { light: lightSet, dark: darkSet };
}
