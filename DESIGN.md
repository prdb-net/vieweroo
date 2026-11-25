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

In the library window, carry the native sidebar divider to the top of the title bar. Run one separator beneath the toolbar across both columns. Place the active library’s name and a menu indicator at the leading edge of the content toolbar. Keep the menu compact and truncate long names. Offer library switching and creation in this menu.

Keep the area from the end of the library menu to the trailing window edge available for native window gestures. Use the system title bar background so clicks reach the window, including above scrollable content.

Place activity, the PIN lock and refresh at the foot of the sidebar. Click the activity label to inspect scans, PRDB matching and preview progress. Beside the number of videos without a title, offer **Check Again** to repeat their PRDB lookup. Show **Ready** when idle and surface conditions that need attention. Use **Vieweroo → Settings…** (⌘,) for PIN protection, PRDB access and the local catalog API. End the Library section with **Settings**, where users can rename the active library, open **Manage Folders**, or confirm deletion of the library.

Align the poster, title, actions and section headings to the same leading edge. Set collection titles in the system large title, the selected video in title bold and section headings in title 3. Use body or headline weight for a title in a list. Use secondary system text for metadata and monospaced digits for a moving clock. A compact row may truncate a title at two lines. The detail view gives the full title room to wrap.

Follow the system appearance and accent. Use a filled heart for a saved favorite and a filled thumb for an active rating. Preserve native focus rings and keyboard activation. Keep artwork in a 16∶9 frame with an 8 pt continuous corner. In the windowed player, fit the playback surface to the video's presentation aspect ratio and center it on the window background. In full screen, fit the complete picture against black.

## Buttons and action labels

Use an icon-only button for a familiar action when its placement makes the target clear. Use the same SF Symbol for that action throughout the app.

| Action | SF Symbol | Placement |
| --- | --- | --- |
| Add or create | `plus` | In a collection header or beside the new tag field |
| Edit or rename | `pencil` | Beside the item, filename, setting or assignment being edited |
| Delete an item | `trash` | On the affected row, opening the confirmation |
| Remove a source folder from a library | `minus` | On the folder row |
| Clear a field or remove a chip | `xmark.circle.fill` | Inside the field or chip |
| Open settings or manage a collection | `gearshape` | In the overview or beside the collection name |
| Refresh or retry | `arrow.clockwise` | Beside the relevant status |
| Search | `magnifyingglass` | Beside a search field that requires submission |

Use the pencil for both name-only forms and editors with several fields. When the form edits only the name, use **Rename** in the tooltip, VoiceOver label and confirmation button.

Give every icon button a short tooltip naming the action, such as **New Playlist…** or **Rename File…**. Give repeated row actions a VoiceOver label that identifies the item, such as **Rename Playlist “Weekend”**. Keep native button activation and keyboard focus. Expose toggle state to assistive technology and describe the next action on hover.

Keep visible text for menu items, dialog decisions (**Cancel**, **Rename**, **Delete Playlist**, **Done**) and primary actions in empty states. Also show text when it explains a destination, consequence or value, such as **Add to Playlist**, **Remove Library Entry…** or **Resume at 0:12**. Wrap a group of actions when it runs out of room so these labels stay visible.

## Collection search, filters and settings

Use the same control order across collection overviews. Keep **Back** on the left. On the right, place the search field, **Filters** (sliders), then the edit pencil for in-place editing or the gear for a separate manager. Give each control a tooltip and an accessible action name.

Scope search to the open collection. Name the scope in the placeholder, update results as the user types, and let Command–F focus the active search field. Clearing the field keeps focus there. Show the matching count beside the collection title. Tint the Filters icon when filters are active and show each applied choice as a removable chip. Wrap chips below the heading on narrow windows and keep them available when there are no matches.

Use a popover with immediate updates for a short set of filters. For several filter groups, use a resizable sheet. In **Video Filters**, start with the collection’s current query and selections. Give long option lists their own search fields, such as **Find a studio** or **Find a tag**. Searching an option list keeps checked values selected, including those outside the search results. Keep **Reset filters**, **Cancel** and the default **Show** button visible while scrolling. Reset clears the draft, Cancel discards it, and Show displays the matching count and applies the draft.

For Studios and Tags, group management actions in the sheet opened by the gear. Put the plus in the sheet header and the pencil and trash buttons on the affected row. Prefill the current name for renaming. Name the item in the delete confirmation and explain what happens to its videos. A manager with a long list has its own search and filters. **Done** returns to the overview with its browsing state intact.

The Studios overview keeps the favorite heart beside each studio name. Offer **Choose Cover…** on a populated studio tile and a photo button in **Manage Studios**. Use the same frame picker as Tags. **Use Automatic Cover** restores the first studio video’s poster. Place **Playlists** immediately above **Settings** in the sidebar. Show playlists alphabetically in the same 16∶9 cover grid as Tags, with the playlist name and video count. Use the playlist symbol for empty playlists and while a still is pending. Offer **Choose Cover…** in each populated tile’s context menu and a photo button when one populated playlist is selected in edit mode. Use the tag cover sheet layout and list videos in playlist order. In the overview, the edit pencil switches tiles to checkbox selection. The plus creates a playlist even when the grid is empty. Enable rename for one selection and confirm deletion for one or more selected playlists. An open playlist offers actions on its videos, including reordering and removing a video. Show up to five recently opened playlists in a separate sidebar section, newest first. Hide the section until a playlist has been opened.

Place **Tags** below **Liked** in the sidebar. Show tags alphabetically in the Studios grid layout with a 16∶9 local still, tag name and video count. Use the tag symbol for empty tags and while a still is pending. Open **Manage Tags** from the gear for creation, renaming, cover selection and confirmed deletion. Also offer **Choose Cover…** in each populated tile’s context menu. The cover sheet pairs a list of the tag’s videos with a silent frame preview, filmstrip, time slider and previous/next frame buttons. Preselect the current cover video. **Use This Frame** saves the displayed frame and **Use Automatic Cover** restores automatic selection.

In an open tag, playlist, studio or performer, All Videos, Favorites, Liked and Watch History, place the icon-only edit pencil beside Filters. Its tooltip and accessibility label name the collection. In edit mode a click selects the tile, with a circle in the play position, a checkmark and an accent outline for selection. Keep the selection count, Select All, batch actions and Done above the scroll area. In All Videos and in an open studio or performer, show favorite, like, dislike, playlist, tag and studio actions directly. **Set Studio…** opens the studio list for the selection, with **Use Automatic Studio** to remove a manual choice. Wrap the buttons when space is limited. In Favorites, Liked and Watch History, show the primary collection action and group the additional actions under More. In an open playlist, use **Remove from Playlist** as the primary action. In an open tag, use **Remove Tag from Selected Videos** as the primary action. In Watch History, confirm removal with the number of selected videos and explain that the resume positions are kept. A bulk edit confirmation offers **Undo** for 12 seconds.

## Choosing a video

Keep **Back** at the upper leading edge of the content, above the scroll area. Enable it when an earlier browsing location exists. Command–[ retraces one step, restoring the search term, filters, scroll position and selected tile. When users reopen a collection from the sidebar, a tile or a link, restore its last applied search, filters and scroll offset in a new visit. Keep chips and the count visible for empty results. Back retraces the actual visits. Clear remembered collections and history on lock, library switch and quit.

On a video poster, show the duration at the lower trailing corner and saved reactions at the lower leading corner on dark badges. Draw the resume position as a thin accent line along the lower edge. Below the title show the studio and the quality tier, each only when known. Offline, missing and unsupported videos show that state instead.

Right-click a video tile in a collection to play or resume, add or remove a favorite, set or clear a like or dislike, or choose a destination under **Add to Playlist**. Keep reactions and playlist actions available for offline and missing videos. In Watch History, offer **Play from Beginning** alongside **Resume** when there is a saved position. In a playlist, group reordering and removal below **Add to Playlist**. In selection mode, use the bulk action bar.

Select a video tile to open its title page or use the tile’s Play button to start or resume immediately. Keep the title and a link to its studio above the 16∶9 poster. Play replaces the poster with the video in place and reveals the transport beneath it. When a resume point exists, offer both Resume and Play from Beginning on the poster. Group reactions and playlist actions below the video with the play count, total watch time and Library Details button. Open the most-watched segments in a popover anchored to the counts. Selecting a segment closes the popover and plays from its start. Place the local resolution tier beside the studio. Library Details opens a wide, scrollable sheet. Show the file and folder together with **Show in Finder** and a **Video Encoding** button that opens a popover below it. Follow the file with its PRDB match, studio and library tags. Keep Done within reach while scrolling.

In Library Details, show **Remove Match** beside **Correct Match…** whenever a title is linked. After removal, show **No title linked** and offer **Find Match…**.

In **Match a PRDB Title**, keep the filename and current match visible. With no active search, show suggested titles. Search PRDB by title, studio or performer and combine the filters. Show studio and cast on each result and save the selected row with **Use Title**.

Moving the pointer horizontally across a video tile, title poster or suggested thumbnail steps through its cached stills. Show the time of the displayed still. Restore the poster on exit and keep the poster visible while frames are unavailable.

**More to Watch** offers up to eight playable titles from the current library. Prefer the same studio, then a shared performer, then a shared tag. Fill the remaining places in catalog order, starting after the current video. Include the relationship in the subtitle when available. Choosing a title starts it at its saved position. On the title page and in Cinema Mode, right-click a recommendation to add or remove that video from Favorites while playback continues. The list stays out of the layout when there are no alternatives.

Keep the same recommendation layout before and during playback. At 760 pt of detail space, place the list beside the video. Below that, use a horizontal shelf below the cast. Selecting a suggestion replaces the current title in place. Full screen dedicates the window to playback.

## Watching

Keep the timeline above one row of transport controls. Float the seek time just above the slider and any loop markers, aligned with the pointer or dragged knob. Size the label to its text until a cached still is available, then show a 96 × 54 pt preview above the time. Group the ten-second skips around play/pause, followed by the elapsed and total time. Put loop, sound and full screen on the other end. Keep AirPlay beside the windowed transport and in the full-screen header. Playback errors stay on the video, and the viewer can still go back or choose another title.

Offer **Cinema Mode** in the heading of each video collection. Disable it when the visible results contain no playable videos. In Cinema Mode, group Previous, the ten-second skips, Play/Pause and Next along the bottom edge. Keep reactions and output controls in the same row with the title, timeline and playback time directly above. Fade the background from clear to a translucent shade at the bottom so the picture remains visible. Use a solid background with Reduce Transparency enabled. In Cinema Mode, place the recommendation thumbnails and white labels directly over the picture. Below each title show only its studio name, when available. Give the lettering a dark edge and a soft shadow for legibility on bright frames. Use a solid backing for the list when Reduce Transparency or Increase Contrast is enabled.

Offer full screen in the current window with a visible button, F and a double-click on the video. Escape first leaves full screen with playback continuing. Escape in the windowed player returns to the original browsing context. In full screen, fade the controls after three idle seconds during playback. Reveal them on pointer movement and keep them visible when paused, while adjusting controls or when VoiceOver is active.

## Messages and motion

| Situation | Presentation | Behavior |
| --- | --- | --- |
| A completed edit or save | One notice at the bottom trailing corner | Show the outcome for 3.2 seconds. A newer action replaces it and restarts the timer. |
| A recoverable failed edit | Error symbol and concise text | Allow 5 seconds to read it. Keep editable input available for correction. |
| Ongoing scan or PRDB outage | Sidebar activity or status | Keep it visible while the condition applies. |
| File offline, playback failure or invalid field | At the affected video or field | Keep the explanation in context so the user can act on it. |
| Destructive decision | Native confirmation dialog | State what is affected and offer Cancel before changing the catalog. |

Inset notices 24 pt from the window edges and raise them above the player controls. Pair a short ease-out entrance with a thin countdown line. Use a pink heart for a saved favorite and a warning symbol for errors. A notice passes clicks through, preserves focus and announces its text to assistive technology. Reduce Motion removes travel and countdown movement. Reduce Transparency uses a solid system surface. Locking or changing libraries clears the current notice.

On the detail page, acknowledge a successful selection at the button. Three small pink hearts rise when saving a Favorite. Like lifts a mint thumb through four short rays. Dislike taps a violet thumb against a small impact line. Keep the button frame still. A filled symbol and tinted outline show the saved state. Clearing a selection restores its outline immediately. Reduce Motion keeps the state change instant. The [interactive reference](Design/reactions.html) demonstrates the three reactions.

Briefly show a checkmark on **Add to Playlist** when a video joins a playlist. Name the destination in the notice. In a video tile’s context menu, show a checkmark next to each playlist that already contains the video. Choosing a checked destination keeps the video in place and reports that it already belongs to that playlist.

Place the A and B markers just above the native timeline at their playback times. Setting A settles the start marker into position. Setting B briefly brightens the span, which stays visible until the loop clears. Reduce Motion shows the markers and span immediately.

## Review on a Mac

Exercise the 790 × 535 pt minimum and the 1080 × 720 pt default, plus native full screen. Check a long title, a library with one playable item, unavailable media and a repeated save while a notice is visible. Use synthetic videos to verify that selecting another title, leaving full screen and returning to the library preserve the intended playback and browsing state. Use keyboard-only navigation and check both system appearances before changing the visual hierarchy.
