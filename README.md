# Vieweroo

Vieweroo is a native macOS video library and player for collections spread across local disks and mounted drives. Browse by studio or performer, collect favorites, and return to the parts of a video you watch most. Your files stay in their original folders.

## Build, test, and package

Use an Apple Silicon Mac with Xcode 16.3 or later selected as the active developer directory and a Swift 6.1 or newer toolchain. Swift Package Manager downloads the pinned GRDB dependency on the first build. The app targets macOS 14 and later.

Run these three commands from the repository root.

```sh
./scripts/build
./scripts/test
./scripts/package
```

The build produces `dist/Vieweroo.app`. The test suite uses temporary catalogs, generated video, synthetic PRDB responses, and a substitute Keychain. Packaging rebuilds and signs the Apple Silicon app locally, then writes `dist/Vieweroo-apple-silicon.zip`.

## Run the synthetic test library

Run `./scripts/test-library --install` once on a supported Mac to install **Vieweroo Test Library** in your personal Applications folder (`~/Applications`). Setup uses Python 3 and FFmpeg with libx264 (`brew install ffmpeg`) to generate 40 short H.264 movies with audio. The app opens **Motion Archive** in its studio overview. Allow the initial scan and thumbnail generation to finish.

After setup, double-click the app in Finder or open it from Spotlight. The simulated PRDB runs inside the app and works offline. Everyday launches need only the installed app and its data in `~/Library/Application Support/net.prdb.vieweroo.test-library.installed/`. Favorites, playback positions and settings persist after quitting or restarting your Mac. To update to a newer checkout build, quit the test app and run the install command again.

Explore eight fictional studios with five titles each and a recurring cast of 16 performers with illustrated portraits. Search for **Lanterns at Dusk**, open its cast, or play another title from **More to Watch**. The clips run for 24–48 seconds so you can try seeking, resuming, muting and A–B loops.

The simulator supplies its own test key. The scanner reads each file, computes its OSHash and identifies it by hash and byte size. Studio lookup, title search and match correction use the same Swift client as the regular app. Test credentials and preferences use a dedicated defaults suite.

For an independent development library, run `./scripts/test-library` without arguments. This builds and opens a checkout-local copy with its own media and catalog in `.local/test-library/`.

## Install and update

1. Extract the ZIP and drag **Vieweroo.app** to **Applications**.
2. Open Vieweroo. The app is ad hoc signed and distributed without Apple notarization. If macOS blocks a copy that you trust, open **System Settings → Privacy & Security**, choose **Open Anyway** for Vieweroo, and confirm.
3. Enter your personal PRDB API key while online. Vieweroo validates it and saves it in your login Keychain. One key works across all your libraries.
4. Choose **New Library**, give it a name, then open **Source Folders → Add Folder…** or press ⌘O. The first scan imports MP4, M4V, and MOV files, including subfolders. Tiles appear as files are discovered. Vieweroo prepares timeline previews in the background.

To update, quit Vieweroo and replace the app in Applications with the new copy. The catalog lives in `~/Library/Application Support/net.prdb.vieweroo/`; previews live in `~/Library/Caches/net.prdb.vieweroo/`. The replacement opens the existing catalog and migrates it as needed. If macOS requests Keychain authorization after an update, allow the trusted replacement to access the existing Vieweroo items.

## Browse and play

- Open a studio or use the sidebar search to find a title, filename, studio, performer, or tag in the active library. Press ⌘F to focus search, including when the sidebar is hidden. Select a video to see its cast, save a favorite, rate it, or open **Library Details** to edit tags or confirm a suggested PRDB title. **Set Studio** keeps your choice across scans.
- Click **Back** or press **⌘[** to return through videos, performers, studios, playlists and searches. Back restores your scroll position and highlights the tile you opened.
- Create a playlist in the sidebar. Use **Add to Playlist** on a video. In a playlist, Control-click a tile to move it earlier or later or remove it.
- Choose **Play**, **Resume**, **From Beginning**, or a segment under **Viewing History**. Use the arrow keys to skip ten seconds, and the bracket keys to mark the start and end of a loop. Click the video or press Space to toggle playback. Use the volume slider or press M to mute. Click the full-screen button, double-click the video, or press F to enter or leave full screen. Escape leaves full screen first, then returns to the library. Use the AirPlay picker to select a video receiver.
- Select a title under **More to Watch** to play it at its saved position. A narrower player has a **More to Watch** button in its header. Closing the player returns to the original browsing location.
- Choose **Refresh Library** (⌘R) after adding or moving files. Disconnected sources and missing files retain their entries and personal data. **Source Folders** lets you see the effect of removing a source before you confirm.

## Privacy and access

PRDB receives the filename, file size, and available OSHash for identification. Folder names are evaluated on your Mac. PRDB also supplies candidate titles, artwork, studios, and cast. Ratings, tags, playlists, match corrections, and viewing history stay local.

Enable a PIN under **Privacy** and press ⇧⌘L to lock the app and stop playback. **Forgot PIN?** uses macOS account authentication. PIN protection controls the interface and playback. The SQLite catalog and image cache use ordinary local storage.

The [product vision](VISION.md), [architecture decisions](ARCHITECTURE.md) and [interface guide](DESIGN.md) describe MVP behavior, hardware acceptance checks and the macOS design conventions.
