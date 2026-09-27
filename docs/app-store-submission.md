---
title: SwiftFlac App Store Submission
---

# App Store submission

What was needed to get SwiftFlac ready for review, and why. Kept in the repo so the reasoning survives, and because most of it applies to any small, free, offline app.

## Notes for App Review

Paste this into the "Notes for Review" field in App Store Connect. It exists because the app ships with no music: without instructions a reviewer opens it, sees an empty library, and has nothing to test. That is the most likely cause of a rejection under guideline 2.1 (App Completeness) for an app like this.

> SwiftFlac is an offline music player for music files you already own. It ships with no music, so it needs one audio file added before there is anything to play. This takes about 30 seconds:
>
> 1. Open Safari and go to: https://krisfur.github.io/swiftflac/sample.flac
> 2. The file downloads. Tap the download, then "Save to Files".
> 3. Choose On My iPad (or On My iPhone) > SwiftFlac, and tap Save.
> 4. Open SwiftFlac. The track appears under All Tracks and Albums. Tap it to play.
>
> Alternatively, connect the device to a Mac and drag any .flac, .mp3, .m4a, .wav, or .aiff file into the SwiftFlac folder under Files sharing in Finder.
>
> On Mac:
>
> 1. Open the same link in Safari; the file downloads to Downloads.
> 2. Open SwiftFlac, click the gear icon (Settings), then Choose Folder..., and pick Downloads.
> 3. The track appears under All Tracks and Albums. Click it to play.
>
> The app also accepts any folder via the gear icon (Settings) > Choose Folder. Each subfolder inside the chosen folder becomes a playlist.
>
> Siri and Shortcuts: requests such as "Shuffle my library in SwiftFlac" or "Play <folder, album, or artist> in SwiftFlac" play music, and the same actions appear in the Shortcuts app. As with any app's shortcuts, Siri must first be turned on for SwiftFlac: open Settings (gear icon) > Siri & Shortcuts, which opens SwiftFlac's page in the Shortcuts app, tap the info (i) button at the top right, and turn on Siri.
>
> Notes on the app:
>
> - No account, no login, no purchases, no subscriptions. Everything is free.
> - No network access whatsoever. The app works fully in airplane mode. The only web link is the GitHub link in Settings (gear icon), which opens Safari.
> - No data is collected or transmitted. No analytics, no tracking, no third-party SDKs.
> - No permission prompts. The app reads only files you place in its own folder or a folder you explicitly pick.
> - Background audio is used so playback continues when the screen locks, with standard Control Centre and lock screen controls.
>
> Contact for any questions: k_furman@outlook.com

## The sample track

`sample.flac` is served from this site rather than bundled in the app, so it costs users nothing in download size while still giving a reviewer something to play in one step.

It is generated, not sourced from a music library: `make-sample.sh` builds it from `sample-tone.py` (a C major arpeggio, stdlib Python) and `sample-cover.swift` (white text on black, CoreGraphics). Nothing in it belongs to anyone else, so there is no licence to honour and no attribution to carry. The short music FLACs on Wikimedia Commons are CC-BY, which would have meant an attribution notice in perpetuity for a throwaway demo file.

The file is about 94 KB: a 5 second mono tone plus a 600x600 cover. The cover matters more than it looks: it means the reviewer sees the tag parser read a real embedded picture rather than the placeholder artwork.

## Checklist

**Privacy manifest.** `SwiftFlac/PrivacyInfo.xcprivacy` declares `NSPrivacyAccessedAPICategoryUserDefaults` with reason `CA92.1`. Since May 2024 App Store Connect rejects uploads that use a required-reason API without declaring it, with `ITMS-91053`, before review even begins. UserDefaults is the only such API the app touches. File timestamps are deliberately avoided, including in the library change detection, to keep it that way.

**Export compliance.** `ITSAppUsesNonExemptEncryption` is set to false in `Support/Info.plist`. Without it, App Store Connect asks the export question on every single submission.

**Code signing.** `CODE_SIGN_IDENTITY` for macOS was pinned to `-` (ad-hoc) in both build configurations, which overrides automatic signing and cannot produce a distributable archive. It is now Debug only, so local builds still need no provisioning profile.

**Accessibility.** The transport, shuffle, repeat, and search-clear controls are icon-only, so VoiceOver announced the SF Symbol name. They now carry labels, with shuffle and repeat exposing their state as an accessibility value rather than folding it into the label.

**Privacy policy.** Required for every app in App Store Connect, including apps that collect nothing. Served from this site at [privacy](privacy.md), so the published text lives with the code and cannot drift from it. It covers the one on-device sharing there is: folder, album, and artist names given to the system for Siri and Shortcuts.

**Siri and Shortcuts.** Built with App Intents, which need no entitlement and show no permission prompt. Siri phrases only work once the user turns on Siri for the app in the Shortcuts app, and apps cannot do that themselves, so the review notes walk through it and Settings links straight there.

**Library refresh.** Not a store requirement, but it was the real reason the app looked untestable. The library only scanned at launch, so music added while the app sat in the background stayed invisible until a relaunch or a manual rescan, which reads as a broken app. It now rescans when the app returns to the foreground, gated behind a cheap fingerprint of the file tree so an unchanged library costs a directory walk instead of reopening every file.

## Still needed outside the repo

- A support URL. The GitHub repository serves.
- App Privacy answers in App Store Connect: "Data Not Collected" throughout.
- Screenshots: the files in `screenshots/` are App Store sizes (`ios-*` for the 6.9-inch iPhone, `ipad-*` for the 13-inch iPad, `mac-*` for Mac), generated from a demo library by `take_screenshots.sh`.
