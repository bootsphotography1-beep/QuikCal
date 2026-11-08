# QuikCal

QuikCal is a macOS menu bar calendar app with voice capture: speak a request,
review the suggested event, and save it. Includes a live transcript bar,
on-device speech models, and Google Calendar support.

- **Download:** [QuikCal 0.3.19 (DMG)](https://github.com/bootsphotography1-beep/QuikCal/releases/latest) — Apple Silicon, macOS 14 or later
- **All releases:** https://github.com/bootsphotography1-beep/QuikCal/releases

## Updates

QuikCal checks for updates automatically about once a day and shows Sparkle's
update alert — nothing is ever downloaded, installed, or relaunched without
your explicit action. Automatic checks are on by default and can be turned
off in Settings → General; "Check for Updates…" works at any time.

Updates are delivered via the EdDSA-signed Sparkle feed:

https://github.com/bootsphotography1-beep/QuikCal/releases/latest/download/appcast.xml

**On 0.3.18:** use "Check for Updates…" from the menu to get 0.3.19 — no
manual download needed.

**On 0.3.17 or earlier:** the in-app updater arrived in 0.3.18, so those
versions can't see this feed yet. Download the DMG from the releases page
once to bootstrap; future updates will then arrive in-app.

## Package notes

- Apple Silicon (arm64), macOS 14.0 or later.
- Signed with an Apple Development certificate; **not notarized** — macOS may
  ask you to approve the app the first time you open it (System Settings →
  Privacy & Security → Open Anyway).
