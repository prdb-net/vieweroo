# Vieweroo architecture decisions

## Established constraints

The [product vision](VISION.md) sets the following constraints for the implementation.

- **Platform and language.** Vieweroo is a native macOS desktop app written in Swift.
- **Media ownership.** Each library references one or more user-selected folders on local disks or mounted network drives. Media files stay in place. Disconnecting a drive preserves its library entries and viewing data.
- **Catalog and viewing data.** A local database holds file references, metadata, playlists, tags, ratings, favorites, and playback history. Watch history must distinguish segments actually played from time skipped by seeking.
- **Metadata lookup.** Match files against the public PRDB API by hash first, then by title. An unmatched file remains playable. Browsing a matched title uses its studio and performer metadata.
- **App lock.** Optional PIN protection covers launch and manual locking. Locking stops playback and conceals library content in windows and macOS window previews.

## Accepted decisions

### 1. Use AVPlayer for MVP playback

Use Apple's AVPlayer from AVFoundation. We expect most videos in the intended collections to be MP4 files, so MP4 is the primary playback target. Native AirPlay support is a deciding factor because watching library videos on an AirPlay receiver is part of the MVP. Verify playback with representative MP4 files from both local folders and mounted network drives, including playback through an AirPlay receiver.

During the recursive scan, import files with an `.mp4`, `.m4v`, or `.mov` extension (case-insensitive) and skip other extensions. If AVPlayer cannot decode an imported file, keep its entry and explain the playback failure. After the MVP, test additional container and codec combinations before extending the import filter.

### 2. Distribute a native Apple Silicon app directly

Use Swift 6 and target macOS 14 or later on Apple Silicon only. Distribute the app as a direct download without Apple notarization. Preserving developer anonymity is a release constraint.

Ship a ZIP containing the Apple Silicon `.app`. Document how to build and test from a fresh checkout. Provide English instructions for installation, first launch of the unnotarized app, and manual updates. Replacing the app must preserve the SQLite catalog and access to its existing Keychain items. Automatic updates are outside the MVP.

### 3. Use SwiftUI with targeted AppKit integration

Build the library, search, studio views, and settings in SwiftUI. Embed AVKit's AVPlayerView for playback and use AppKit where native Mac behavior requires it. Keep catalog, scanning, matching, and viewing-history logic in a testable Swift core so those behaviors can be exercised without opening a window.

### 4. Use SQLite with GRDB for local persistence

Store all libraries in one SQLite database on the Mac, including when the video files reside on a network drive. Libraries can reference the same PRDB studio and performer records. The Swift core accesses SQLite through GRDB and can use SQL for queries such as finding the most frequently replayed segments of a video.

Give each library entry a stable local ID independent of its file path and PRDB match. Correcting a match updates the metadata link and preserves the entry's personal data. In the MVP, two distinct files matched to the same PRDB title retain separate entries.

Scope favorites, ratings, and playback history to the library entry. When the same file appears in two libraries, each entry has its own resume position, playback sessions, and watched intervals. Calculate viewing statistics for each library from its own sessions.

Each library owns its tags and playlists. Tags apply to entries in their own library, and a playlist can contain only entries from its library.

Treat original media files as read-only. Before removing a source folder, show the number of entries that would lose their last source in this library. Let the user keep those entries with their personal data or remove both. Preserve every entry still covered by another source folder in the library. Deleting an entire library requires confirmation and removes its entries and personal data. Both operations preserve the files on disk and other libraries' data.

### 5. Catalog files locally before enriching them from PRDB

Recursively scan a source folder when the user adds it. Opening a library checks whether its source folders are reachable. The user can start a full rescan with **Refresh Library**. Make each discovered file available while the scan continues and resolve its metadata in the background.

Use OSHash for MVP file identification and reuse the stored hash for unchanged files. Check the Swift implementation against PRDB's reference files and expected results. Defer perceptual hashing (pHash) until after the MVP.

Apply a unique hash match automatically. If the hash does not identify a title, offer title-search results for the user to confirm, even when the search returns a single candidate. Preserve a user-confirmed match across rescans.

Attempt to identify the studio for every entry. Use the studio from a matched PRDB title when available. Otherwise, check both the folder names and the filename for a recognizable studio name. A clear studio match is enough to list the entry under that studio while its title match is still pending. Leave the studio unresolved if the clues are ambiguous.

Store a manual studio selection on the library entry. It takes precedence over automatic detection across rescans until the user selects **Use Automatic Studio**.

Treat an unreachable source folder as offline. If a completed scan of a reachable folder finds that a previously cataloged file is absent, mark the entry as missing. In both cases, retain the entry, its personal data, and its playlist memberships until the user explicitly removes it.

### 6. Record playback sessions and watched intervals

Record a session once actual playback begins. Only sessions with at least ten seconds of played intervals contribute to viewing history and Frequently Watched or update the resume position. A shorter visit preserves the previous resume position. Pausing and resuming, seeking, looping, or switching to AirPlay keeps the same session.

Store the portions of the video timeline actually played in each session. Pausing closes the current interval. Seeking closes it at the departure time, and the next interval starts where playback resumes. Replaying a section, including through a loop, records another pass. Preserve repeated passes so both viewing duration and frequently replayed sections can be derived.

### 7. Limit PIN protection to the app interface and playback

When PIN protection is enabled, require the PIN on launch and after manual locking. Locking stops local and AirPlay playback and conceals library content and previews. The PIN is an app access control. The catalog, viewing history, and image cache use ordinary local storage without app-level encryption.

Require the current PIN to change it. To reset a forgotten PIN, require successful local macOS user authentication before accepting a new PIN. Resetting the PIN preserves the catalog. If authentication fails or is canceled, keep the app locked and the existing PIN in place.

### 8. Require a personal PRDB API key and use read-only lookups in the MVP

Validate the user's personal PRDB API key online during setup before enabling library or playback features. Store one key for the app in the macOS Keychain and use it across all libraries. After successful setup, keep the library and player available during network or service outages, including on relaunch. Resume pending lookups when PRDB is reachable. An explicit invalid-key response requires a valid replacement before library use can continue. A timeout or rate limit leaves the previous validation intact.

For file identification, send the OSHash, file size, and filename without its directory path. Evaluate folder names locally for studio detection. MVP requests look up matches and retrieve metadata. User confirmations and corrections stay local. Submitting confirmed hash-to-title associations to PRDB is planned for after the MVP.

### 9. Open the last library by studio

Open the last-used library in its studio overview. Include an **Unknown Studio** group for entries whose studio has yet to be identified. Search titles, filenames, studios, performers, and tags within the active library. Provide sidebar access to favorites, playlists, and frequently watched videos. A video's detail view lets the user start playback at a frequently replayed segment.

### 10. Generate timeline previews automatically after the initial scan

Use an available PRDB preview image for a video tile, with a locally extracted still as the fallback. Source performer portraits from PRDB. As soon as the initial file scan completes, start generating timestamped thumbnail series for the discovered playable videos in the background. This work runs independently of PRDB lookups and of whether anyone has opened the videos. Cache the series locally for the player's timeline and keep browsing and playback available while generation runs.

### 11. Keep playback and discovery in the library window

Use native window full screen so AVPlayer, its active item and the privacy boundary stay together. Switching videos closes the previous playback session and reads the selected entry’s current saved position. Preserve the originating shelf, detail and search while the player is visible. Compute alternatives using the active catalog entries on the Mac. Window width determines where the list is presented.

The [interface guide](DESIGN.md) defines layout, spacing and feedback. Use one transient action notice in the unlocked window. Clear it on a library or access change. Keep form errors, persistent status and destructive confirmations at their point of use.

## MVP acceptance checks

- **Identification.** Use the PRDB SDK's OpenAPI contract for `POST /videos/identify`. A batch contains at most 200 files. Associate each result with its input using the client-supplied `ref`. Test four distinct responses: a unique `OsHash` match links the title, a filename match offers a candidate for confirmation, a site-only result supplies a studio, and an ambiguous result leaves the title unresolved. Verify OSHash against the SDK’s [published OSHash tests](https://github.com/prdb-net/prdb-sdk/blob/bf647a6e2164b3cfcdb74bb37d54d9568f939aee/csharp/tests/Prdb.Hashing.Tests/OsHashTests.cs). The SDK’s `docs/video-hashing-vectors.json` covers perceptual hashing.
- **Library isolation.** Add the same file to two libraries. Rate, tag, and play it in one. After restarting the app, verify that each library retains its own state and that correcting a PRDB match preserves personal data.
- **Rescanning.** Refresh once with a source drive disconnected and once with a file missing from a reachable folder. Verify the distinct availability states and that both entries keep their history and playlist memberships. Repeating the scan must preserve entry identities and manual studio choices.
- **Playback accounting.** Play the first minute, seek to minute ten, and play the next minute twice in a loop. At normal speed the result is one session, three minutes of viewing time, two passes through the repeated minute, and zero viewing time in the skipped span.
- **AirPlay and locking.** On an Apple Silicon Mac, play a representative MP4 from a mounted drive through an AirPlay video receiver. Lock Vieweroo during playback. Verify that local and remote playback stop and that the library stays concealed in application windows and macOS window previews until unlocked. Record the hardware result separately from automated player-state tests.
- **Access and recovery.** Use local PRDB test responses for initial key validation, offline relaunch, and explicit key rejection. Automated tests must run without a personal API key. Test both successful and canceled macOS authentication during PIN recovery.
- **Source removal.** Add a folder and a nested folder as separate sources in one library. Check the affected count, exercise both retention choices, and verify that entries covered by the remaining source survive. Confirm that deleting the library preserves original media and entries in a second library.
- **Import and previews.** Include all three supported extensions, a playable file with an uppercase extension, a file with an unsupported codec, and an excluded extension. Verify that an interrupted scan can resume without duplicate entries. Complete the scan without opening any video and verify that a playable file's preview series is generated and cached automatically.
- **Release and migration.** Follow the documented build and test commands from a fresh checkout. Install the packaged app on Apple Silicon and manually update an existing installation. Verify that the migrated catalog retains libraries, ratings, and viewing history and that the app can still access the stored key.
