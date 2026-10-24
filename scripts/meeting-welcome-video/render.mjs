// Renders the EnviousMeet welcome scene (index.html) frame by frame into the app's resources
// (#4017 O7): one muted, looping MP4 per language, 940 x 352 pixels (the 470 x 176 point slot
// at 2x), 30 fps.
//
//   npm install --prefix <tools dir> puppeteer-core@23.11.1
//   NODE_PATH=<tools dir>/node_modules node scripts/meeting-welcome-video/render.mjs [--stills 1,2.4,5]
//
// Needs Google Chrome and ffmpeg. Writes Sources/EnviousWispr/Resources/MeetingWelcome-<lang>.mp4.
import { spawn } from "node:child_process";
import { once } from "node:events";
import { mkdirSync, writeFileSync } from "node:fs";
import { createRequire } from "node:module";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const require = createRequire(import.meta.url);
const puppeteer = require("puppeteer-core");
const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = resolve(HERE, "..", "..");
const CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";
const FPS = 30;
const LANGUAGES = ["en", "de"];
const args = process.argv.slice(2);
const stillsAt = args.indexOf("--stills");
const stills = stillsAt >= 0 ? args[stillsAt + 1].split(",").map(Number) : null;

const browser = await puppeteer.launch({
  executablePath: CHROME,
  headless: true,
  defaultViewport: { width: 470, height: 176, deviceScaleFactor: 2 },
  args: ["--hide-scrollbars", "--force-color-profile=srgb", "--allow-file-access-from-files"],
});
const page = await browser.newPage();
page.on("pageerror", (err) => console.error("[pageerror]", err.message));

for (const lang of LANGUAGES) {
  await page.goto(`file://${join(HERE, "index.html")}?lang=${lang}`, { waitUntil: "load" });
  await page.waitForFunction(() => window.READY === true, { timeout: 30000 });
  const total = await page.evaluate(() => window.TOTAL);
  if (stills) {
    const dir = join(HERE, "out");
    mkdirSync(dir, { recursive: true });
    for (const t of stills) {
      await page.evaluate((x) => window.renderAt(x), t);
      writeFileSync(join(dir, `still-${lang}-${t}.png`), await page.screenshot({ type: "png" }));
    }
    continue;
  }
  const out = join(ROOT, "Sources", "EnviousWispr", "Resources", `MeetingWelcome-${lang}.mp4`);
  const ff = spawn(
    "ffmpeg",
    [
      "-y", "-hide_banner", "-loglevel", "error",
      "-f", "image2pipe", "-framerate", String(FPS), "-c:v", "png", "-i", "-",
      "-vf", "format=yuv420p", "-c:v", "libx264", "-preset", "slow", "-crf", "20",
      "-profile:v", "high", "-tune", "animation", "-an", "-movflags", "+faststart", out,
    ],
    { stdio: ["pipe", "inherit", "inherit"] },
  );
  const frames = Math.round(total * FPS);
  for (let i = 0; i < frames; i++) {
    await page.evaluate((x) => window.renderAt(x), i / FPS);
    const buf = await page.screenshot({ type: "png" });
    if (!ff.stdin.write(buf)) await once(ff.stdin, "drain");
  }
  ff.stdin.end();
  const [code] = await once(ff, "close");
  if (code !== 0) throw new Error(`ffmpeg exited ${code} for ${lang}`);
  console.log("wrote", out);
}
await browser.close();
