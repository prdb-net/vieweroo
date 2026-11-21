# Vieweroo interface guide

Vieweroo serves two moments at a Mac. While browsing, people compare titles by their images. During playback, they either settle in or move quickly to another video. Keep the artwork, the current position and the route back easy to find. Use familiar macOS controls for the work of managing a collection.

## Spacing and type

Use the shared `VSpace` values in points. Choose the distance by the relationship between the elements.

| Points | Token | Use |
| --- | --- | --- |
| 4 | `unit` | A title and its studio, tag or other supporting line |
| 8 | `tight` | A thumbnail and its caption, neighboring transport buttons |
| 12 | `control` | A related video's thumbnail and text, icon and message, rows in an editor |
| 16 | `group` | Grid columns, player side insets, related controls within a group |
| 24 | `section` | Content margins, independent sections, video and recommendation columns |
| 32 | `page` | Outer breathing room around a standalone access form |

In the library window, carry the native sidebar divider to the top of the title bar. Run one separator beneath the toolbar across both columns. Align the window title to the collection heading’s 24 pt inset while the sidebar is visible.

Keep the area from the library title to the trailing window edge available for native window gestures. Use the system title bar background so clicks reach the window, including above scrollable content. Put search in the sidebar, folder import in Source Folders and the PIN lock next to Privacy.

Align the poster, title, actions and section headings to the same leading edge. Set collection titles in the system large title, the selected video in title bold and section headings in title 3. Use body or headline weight for a title in a list. Use secondary system text for metadata and monospaced digits for a moving clock. A compact row may truncate a title at two lines. The detail view gives the full title room to wrap.

Follow the system appearance and accent. Use SF Symbols with a short action label or tooltip and an accessible name. Use a filled heart for a saved favorite and a filled thumb for an active rating. Preserve native focus rings and keyboard activation. Keep artwork in a 16∶9 frame with an 8 pt continuous corner. In the windowed player, fit the playback surface to the video's presentation aspect ratio and center it on the window background. In full screen, fit the complete picture against black.

## Choosing a video

The library grid opens details. The large poster on a detail page starts playback and shows the saved time when resuming. Keep **From Beginning** beside the title information when a resume point exists. Keep **Library Details** expandable for file information, tags, manual studio assignment and PRDB corrections.

**More to Watch** offers up to eight playable titles from the current library. Prefer the same studio, then a shared performer, then a shared tag. Fill the remaining places in catalog order, starting after the current video. Include the relationship in the subtitle when available. Choosing a title starts it at its saved position. The list stays out of the layout when there are no alternatives.

Adapt to the width available to each surface. At 760 pt of detail space the list can sit beside the poster. Below that, put it in a horizontal shelf after the viewing actions and show a compact poster beside the title. At 960 pt of player width, show a 300 pt side list. Give it unused horizontal space when height limits the picture, up to 400 pt or one third of the window width, whichever is smaller. In a smaller player, expose the same list from a labeled header button. Full screen uses the video area for playback.

## Watching

Keep the timeline above one row of transport controls. Group the ten-second skips around play/pause, followed by the elapsed and total time. Put loop, sound and full screen on the other end. Keep AirPlay in the header. Playback errors stay on the video, and the viewer can still go back or choose another title.

Offer full screen in the current window with a visible button, F and a double-click on the video. Escape first leaves full screen with playback continuing. Escape in the windowed player returns to the original browsing context. In full screen, fade the controls after three idle seconds during playback. Reveal them on pointer movement and keep them visible when paused, while adjusting controls or when VoiceOver is active.

## Messages and motion

| Situation | Presentation | Behavior |
| --- | --- | --- |
| A completed edit or save | One notice at the bottom trailing corner | Show the outcome for 3.2 seconds. A newer action replaces it and restarts the timer. |
| A recoverable failed edit | Error symbol and concise text | Allow 5 seconds to read it. Keep editable input available for correction. |
| Ongoing scan or PRDB outage | Sidebar activity or status | Keep it visible while the condition applies. |
| File offline, playback failure or invalid field | At the affected video or field | Keep the explanation in context so the user can act on it. |
| Destructive decision | Native confirmation dialog | State what is affected and offer Cancel before changing the catalog. |

Inset notices 24 pt from the window edges and raise them above the player controls. Pair a short ease-out entrance with a small icon response and a thin countdown line. A newly saved favorite gets a pink heart and a brief sparkle. Use a warning symbol for errors. A notice passes clicks through, preserves focus and announces its text to assistive technology. Reduce Motion removes travel, sparkle and countdown movement. Reduce Transparency uses a solid system surface. Locking or changing libraries clears the current notice.

The [interactive reaction proposal](Design/reactions.html) explores feedback on the detail buttons. Try switching between Like and Dislike, saving a Favorite independently and turning on reduced motion. The proposed effects play once when a selection is saved. Clearing a selection returns its symbol to an outline.

Two other candidates are playlist saves and A–B loops. A checkmark on **Add to Playlist** could confirm insertion while the notice names the chosen playlist. On the timeline, setting A could place a start marker. Setting B could briefly brighten the selected range and leave it visible while the loop is active.

## Review on a Mac

Exercise the 790 × 535 pt minimum and the 1080 × 720 pt default, plus native full screen. Check a long title, a library with one playable item, unavailable media and a repeated save while a notice is visible. Use synthetic videos to verify that selecting another title, leaving full screen and returning to the library preserve the intended playback and browsing state. Use keyboard-only navigation and check both system appearances before changing the visual hierarchy.
