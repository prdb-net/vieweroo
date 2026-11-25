# Vieweroo Product Vision

Vieweroo is a native, open-source macOS app written in Swift. It brings an adult video collection spread across several drives into one personal library. If you remember a studio, a face, or a favorite moment, you should be able to find the video and start watching at the spot you had in mind.

## A library across folders and drives

To use Vieweroo, validate your personal PRDB API key during setup. One key covers all your libraries. Vieweroo saves it in a separate local settings database so routine launches and updates can open your collection without a Keychain prompt. Once set up, you can browse and play available videos while PRDB is unreachable. Pending lookups resume when the connection returns. If PRDB reports that the key is invalid, Vieweroo asks for a valid replacement.

You can create multiple libraries, each with its own set of folders on local disks or mounted network drives. Use the title bar to switch libraries or create one. The active library’s **Settings** in the sidebar brings together its name, source folders, and deletion. Adding a folder scans it and its subfolders and catalogs each video's file path and metadata in a local database. The files stay in their folders. The details panel shows the local resolution tier, such as 720p, 1080p, or 4K. In the same panel you can inspect the video encoding, reveal the file in Finder, add or reuse library tags, and rename the file on disk while keeping its library history. Opening a library checks which folders are available. Choose **Refresh Library** to pick up changes. When a network drive is temporarily disconnected, its titles, your ratings, and your playback positions stay in the library.

Each library keeps its own tags, playlists, favorites, ratings, and viewing history. If the same video appears in two libraries, you can rate it differently in each and resume from the point where you last watched it in that library. If a file goes missing from a reachable folder, its entry is marked as missing. You keep its history and its place in your playlists until you choose to remove it.

The MVP catalogs MP4, M4V, and MOV files. If a file uses an unsupported codec, its entry explains why playback is unavailable. Removing a folder shows how many entries would lose their source and lets you keep or remove them. Removing folders or deleting a library leaves your original videos on disk.

Vieweroo automatically links a video to its PRDB title when its file hash produces a unique match through the public prdb.net API. Otherwise, it suggests titles for you to confirm. Vieweroo remembers your choice on the next scan. You can search PRDB by title, studio or performer and correct a match while keeping your rating and viewing history. You can remove a linked title and leave the video unmatched across rescans until you choose another title. You can also play, tag, and add unmatched videos to playlists. PRDB keeps growing. Choose **Check Again** in the library activity to look up the videos that still have no title.

## Exploring by studio and performer

Vieweroo opens the last-used library in the view you last used there. A library you have not browsed yet opens in its studio overview, or in All Videos while fewer than two of its studios are identified. Open a studio to see its videos from across the library's folders, or choose **Unknown Studio** for videos still awaiting identification of their studio. Search, filter or sort the open collection in place. Videos are listed by title. You can also order them by when you added or last watched them, by length or by folder and file name. A playlist keeps its own sequence and Watch History its ranking until you choose another order, and Vieweroo remembers your choice. During a library session, return to any collection with its applied filters, search and place intact. Find studios by name, platform or account handle, and mark favorite studios within each library. Choose a frame from one of a studio’s videos as its cover, or return to the automatic poster. The Favorites shelf contains saved videos. Video collections search their own titles, filenames, studios, performers and tags. Combine the search with multiple local quality tiers, studios and tags, and see the matching video count before applying the selection. The sidebar gives you direct access to Favorites, Watch History and Playlists. It also remembers the five most recently opened playlists in each library.

For each matched video, the detail view shows the PRDB title, studio, and cast, with performer portraits where PRDB provides them. Select a portrait to see other videos in your library featuring that performer. Use Back to retrace your steps through videos, performers, studios and search results. Returning to a collection restores your place and highlights the tile you opened.

Even a video with no PRDB title match can appear under its studio. Vieweroo recognizes studio folders inside a selected source, including the source folder itself. In a filename it looks for a distinctive studio name at the beginning, followed by a separator. Common words such as “Black” and mentions in the middle of a title provide too little evidence for an automatic assignment.

From the studio overview, you can create a named studio in the active library before assigning any videos to it. You can rename your own studios there, including studios with videos already assigned. If you delete one, its videos return to automatic studio assignment. PRDB studios stay available for selection. Creator accounts appear under their publishing platform. Choose a linked OnlyFans or Fansly handle to open the public profile. A studio you create also claims the videos in a source folder of the same name. On a video, choose one studio from the list or create one as you assign it. Vieweroo keeps your choice across scans until you remove the studio chip to restore automatic assignment.

The interface should feel familiar on a Mac and invite you to browse. Large thumbnails and legible titles help you choose what to watch. After playback, you return to your previous place in the studio view, search results, or playlist.

Click a video thumbnail to start or resume that video in Cinema Mode. Click its title or choose **Details** from its context menu to open its details beside the collection, which stays in view and usable. You can play the video, explore its studio and cast, react to it and organize it there. Selecting another title updates the same panel. An unavailable thumbnail opens its details and explains why playback is unavailable. In edit mode the entire tile selects the video.

Video tiles use a PRDB preview when available or a still from the local file. As soon as the first scan finishes, Vieweroo automatically starts preparing timeline previews in the background. You can browse or play a video while the previews are being generated. Move the pointer across a video thumbnail to see cached moments and their times. Previewing is silent and preserves playback history and resume positions. The sidebar shows how many are ready. Click the status to see what is being prepared, waiting or unavailable.

## A player for repeat viewing

Sometimes you want to watch an entire video. Other times you have a particular scene in mind. You can start from the beginning or resume where you left off. Keyboard controls, short skips, and thumbnail previews on the timeline help you find a scene. To watch a segment on repeat, set the start and end of a loop.

Enter full screen from the player to give the video the whole window. The controls recede during uninterrupted playback and return on pointer movement. Leave full screen to continue watching in windowed Cinema Mode.

Choose **Cinema Mode** in any video collection to watch in the library window, with the video extending behind the Mac window buttons. Previous and Next move through playable titles in the order shown when you enter Cinema Mode, including any search or filters. In windowed Cinema Mode, playback controls and icon-only reactions stay visible along the bottom, with the picture showing through the controls. The recommendations fade after three idle seconds of playback, so they do not cover the picture while you watch. In full screen the bottom bar fades with them. Move the pointer or pause to bring them back. Returning to the collection restores your browsing position. A transparent overlay on the right offers other playable videos from the same selection. Choose 2, 4 or 6 recommendations in Settings. The default is 4, and smaller player windows show at most 4. Select a title to resume it or hide the list from the bottom bar. Vieweroo remembers your preference.

Use a second player window to watch up to two videos at once, each in full screen on its own display. Send a title or a filtered Cinema collection to a named display while browsing in the library. Move an open player to a display with its position, sound, pause state, loop and Cinema order intact. Each window has its own controls and history session. An additional video starts muted when the other player is audible. Disconnecting the second player's display pauses it and returns it to a remaining screen. Locking stops both players.

AirPlay is part of the MVP. You can choose an Apple TV or another compatible AirPlay receiver from the player and watch the video on that screen while controlling playback from your Mac.

Vieweroo records locally how often you play each video, how long you spend watching it, and which segments you play. If you jump from minute two to minute ten, those eight minutes are excluded from your watch time. A session appears in viewing history and updates your resume position once you have watched at least ten seconds in that session. This history lets you browse frequently watched videos and see which parts of a video you replay most. You can start playback directly from a highlighted segment.

Watching the same minute five times in a loop counts as one session, five minutes of viewing time at normal speed, and five passes through that segment. Pausing or switching to AirPlay keeps the session going.

## Organizing your collection

Short confirmations appear at the lower right when you save changes. Playback problems and library availability stay visible where you can address them.

Alongside your viewing history, you can make your own selections. Save a video to Favorites for quick access. Independently, give it a thumbs up or thumbs down to record whether you liked it. Custom tags let you search the collection using your own vocabulary. Open **Tags** to browse the active library’s tags by their cover images. Choose a tag to see its videos, or use **Manage Tags** to create, rename and delete tags. Each tag can use an automatic still or an exact frame you choose from one of its videos. Empty tags remain available for reuse. Playlists let you arrange videos from different studios in the order you want to watch them. Browse playlists by cover image and choose an exact frame from any video in the playlist, just as you can for a tag. Use the edit pencil in the playlist overview to create, rename, choose covers or delete selected playlists. Inside a playlist, check several videos and remove them together. Undo restores their order and cover.

In All Videos and in an open studio or performer, select multiple videos to favorite, like, dislike, tag, append them to a playlist or set their studio. In Favorites and Liked, select multiple videos to remove the current mark, apply the other mark, add tags or append to a playlist. In Watch History, select videos to favorite, like, tag or append to a playlist. You can also clear their viewing history while keeping their resume positions. In an open tag, select videos to remove that tag. Select all matches in a filtered collection and undo a batch in one step.

How you find something again depends on what you remember. A title you saved is in Favorites. Videos you liked can be viewed together. A scene you often replay is accessible through your viewing history, even if you never marked it.

## Privacy on launch and while locked

Your viewing history, ratings, favorites, playlists, and tags stay in the local database. Vieweroo uses the public PRDB API to match titles and retrieve metadata.

Open **Vieweroo → Settings…** for PIN protection and PRDB access across libraries. With optional PIN protection enabled, the first thing you see when you open Vieweroo is the PIN prompt. You can also lock the library while using it. Locking stops playback and hides titles, thumbnails, the current video frame, and personal lists in every window. macOS window previews should also keep the collection out of view while the app is locked.

Use your current PIN to change it. If you forget it, authenticate with your macOS user account to set a new PIN and keep your library.

A companion app on the same Mac can enrich the catalog when you enable **Local catalog API** in Vieweroo’s global settings. One revocable key covers all libraries. The app can discover libraries and entries, correct a display title, supply a description or poster, add tags, and create or assign a studio. Local metadata survives rescans and is available offline. Locking Vieweroo suspends API access.

## After the MVP

These ideas are planned for after the minimum viable product (MVP). During development, an individual feature can move into the MVP if it fits naturally with work already underway.

### Finding and playing favorite moments

1. **Bookmarks.** Press a keyboard shortcut to save the current playback position, then optionally give it a name. Each bookmark has a thumbnail so you can recognize the moment and jump back to it.
2. **Clips in playlists.** Mark the start and end of a scene and add that range to a playlist. Clips from different videos can play back to back without editing the source files.
3. **Scene overview.** Open a grid of timestamped thumbnails from across a video. Seeing several moments side by side helps you recognize the scene you remember and start playback there.
4. **Filtered shuffle.** Shuffle the current selection, such as favorites you have not watched in three months. Each video plays at most once per shuffle session.

### Exploring the library

5. **Smart collections.** Save a set of filters as a collection, such as favorites from a particular studio with a particular tag. Its contents update as videos meet or cease to meet those conditions.
6. **Performers who appear together.** A performer's profile shows who else appears in their videos in your library. Select a second performer to browse the titles they share.
7. **Play queue.** Choose “Play Next” as you browse, rearrange the queue, and save it as a playlist if you want to keep the sequence.

### Maintaining the collection

8. **Reconnect moved files.** When you rename a video outside Vieweroo or move its folder, Vieweroo reconnects the file to its existing library entry so its bookmarks, ratings, and history follow it.
9. **Multiple versions of a title.** Choose between versions such as 1080p and 4K from a single title entry. If the 4K copy is on a disconnected drive, you can play an available local copy.
10. **PRDB match review.** Review uncertain matches together, with the filename, thumbnail, and suggested PRDB title side by side. You can also revisit a previously matched video to correct its assignment.
11. **Library backup and restore.** Back up tags, playlists, ratings, bookmarks, and viewing history. When moving to another Mac, restore the library and reconnect it to your existing video folders.

### Control over viewing data and access

12. **Private playback sessions.** Pause recording for a session. Playback during that session leaves viewing history, watch statistics, and previously saved playback positions untouched.
13. **History deletion by time period.** Clear viewing data for a chosen time period while keeping the bookmarks, tags, and playlists you created.
14. **Automatic locking.** With PIN protection enabled, you can have Vieweroo lock when you lock your Mac or after an inactivity interval you choose. Active playback counts as use for the inactivity timer.

### Contributing to PRDB

15. **Hash contributions.** Submit confirmed file hash and title associations to PRDB so future lookups can identify the same file.

### Playback compatibility

16. **Additional video formats.** Test AVPlayer with more container and codec combinations and expand the set of formats Vieweroo imports based on the results.
