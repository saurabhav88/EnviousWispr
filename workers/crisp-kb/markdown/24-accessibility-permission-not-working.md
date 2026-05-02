EnviousWispr uses Accessibility permission to paste transcribed text into your active app. Without it, Tier 1 direct insertion and Tier 2 simulated Cmd+V paste will silently fail. (Tier 2b AppleScript paste is governed separately by Automation / Apple Events permission, not Accessibility.)

## Granting Permission

1. Open **System Settings > Privacy & Security > Accessibility**.
2. Click the **+** button and add EnviousWispr (or drag the .app into the list).
3. Make sure the toggle next to EnviousWispr is **on**.

## Permission Can Be Revoked at Runtime

macOS allows revoking Accessibility permission while the app is running. EnviousWispr monitors this with a 5-second polling interval and will re-display a warning banner if permission is revoked. You do not need to restart the app after re-granting permission.

## Dev Builds and Signing

If you are running a development build, it uses a separate bundle ID (`com.enviouswispr.app.dev`) with a stable signing identity. This means permission grants persist across rebuilds. If you switch between production and dev builds, you may need to grant Accessibility permission separately for each.

## Resetting Permission

If permission seems stuck, you can reset it for EnviousWispr only:

```
tccutil reset Accessibility com.enviouswispr.app
```

For dev builds:

```
tccutil reset Accessibility com.enviouswispr.app.dev
```

**Never** run `tccutil reset Accessibility` without a bundle ID. That wipes Accessibility permission for every app on your system.