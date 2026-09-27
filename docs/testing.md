# Tests

The SwiftFlacTests target uses Swift Testing against the existing app module. The Core plan is the scheme default; Command-U runs it. There is no UI automation target.

```sh
xcodebuild test -project SwiftFlac.xcodeproj -scheme SwiftFlac -testPlan Core -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```

Use a macOS CI runner with Xcode installed. The tests use isolated temporary files and preferences. The application test host starts without scanning the user's library or registering system playback handlers. Audio integration checks load and decode fixtures without playing them, so they need no audio device, physical phone, or external dependencies.

The suite covers nine areas, with parameterized cases for formats and malformed inputs:

- Metadata: FLAC tags, cover selection, malformed blocks, and tags from other audio formats.
- Library: discovery, nested folders, grouping, deduplication, refresh, stale scans, and security-scope balancing.
- Playback: queues, repeat/shuffle, seeks, failures, interruptions, and metadata payloads.
- Activation: cancellation, serialized requests, failure, and retry.
- Persistence: paused session restore, relocated roots, missing tracks, invalid state, and library cache recovery.
- Navigation/search policy: punctuation and accent folding, title precedence, and destination restoration.
- Artwork: bounded thumbnails, fallback, caching, and canceled loads.
- Audio quality: format, bit depth, sample rate, and bitrate for each supported format.
- Siri and Shortcuts: library item listing and matching, and playing or shuffling an item.

This covers application logic and audio-file integration, not button interactions, gestures, or OS delivery of lock-screen/AirPlay events. For layout, `./take_screenshots.sh qa` captures every screen on iPhone (portrait and landscape) and iPad (portrait; iPadOS ignores app rotation requests) simulators for review. Those remain manual checks. There is no coverage-percentage target or testing of trivial getters and framework internals.

Fixtures are generated tones and the existing sample FLAC. They are bundled only with the test target; running tests does not require ffmpeg. Tests control asynchronous completions and use bounded waits rather than fixed sleeps.
