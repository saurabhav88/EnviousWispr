EnviousWispr uses the **Sparkle** framework for automatic updates. The app periodically checks for new versions in the background. When an update is available, you will be prompted to download and install it.

## Manual Update Check

You can trigger an update check manually from the menu bar. Click the EnviousWispr icon in the menu bar and look for the update option.

## What Happens During an Update

1. The app downloads the new version from GitHub Releases.
2. The update is verified (signature check via Sparkle).
3. The app restarts with the new version.

## Update Source

Updates are distributed as DMG files hosted on GitHub Releases. The update feed (appcast.xml) is served from enviouswispr.com and cached by Cloudflare with a short TTL for fast propagation.