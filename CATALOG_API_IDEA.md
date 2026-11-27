# Local catalog API

Use the API to organize videos in Vieweroo from another app on the same Mac. In **Vieweroo → Settings…** (⌘,), turn on **Local catalog API** and choose **Copy Key**. The endpoint is `http://127.0.0.1:47832/v1`. One key covers metadata and file renames in every current and future library, regardless of the library open in the window.

Send the key with each request in the `Authorization: Bearer <key>` header. Vieweroo accepts connections while it is open and unlocked. Unlocking or relaunching restores access with the same key. Turning the API off revokes it. Turning the API back on creates a fresh key.

For POST and PATCH requests use `Content-Type: application/json` and a body with a known content length.

## Discover libraries and videos

| Method | Path relative to `/v1` | Result |
| --- | --- | --- |
| GET | `/libraries` | Array of libraries with numeric `id` and `name`. Repeat to discover new libraries. |
| GET | `/libraries/{libraryID}/entries?limit=100&after=0` | Object with an `entries` array in ascending entry ID order. If `nextAfter` is present, use it as the next page’s `after`. The default limit is 100 and the maximum is 200. |
| GET | `/libraries/{libraryID}/entries?osHash={hash}&fileSize={bytes}` | Entries in that library with the given OSHash and optional exact byte count. Supports the same pagination. |
| GET | `/libraries/{libraryID}/entries/{entryID}` | One entry, including its current metadata revision. |
| GET | `/libraries/{libraryID}/studios` | Array of studio choices with `name`, `isCustom` and, where available, `siteID`. |
| POST | `/libraries/{libraryID}/studios` | Send `{"name":"Meadow Studio"}` to create an unassigned custom studio. Returns the new studio and HTTP 201. |
| GET | `/libraries/{libraryID}/tags` | Array of tags with numeric `id` and `name`, including unassigned tags. |
| POST | `/libraries/{libraryID}/tags` | Send `{"name":"Field study"}` to create an unassigned tag. Returns the new tag and HTTP 201. |
| PATCH | `/libraries/{libraryID}/entries/{entryID}` | Applies the requested changes together and returns the updated entry and revision. |
| POST | `/libraries/{libraryID}/entries/{entryID}/rename` | Renames the file on disk and returns the updated entry and revision. |

Every entry includes `libraryID`, `id`, `filename`, display `title`, `tags` and an opaque `revision`. Optional fields are omitted when empty. These include `localTitle`, `description`, resolved `studio`, `manualStudio`, `siteID`, `prdbTitleID` and `posterRevision`. Offline and missing videos remain discoverable and editable. Use the title and PRDB ID for research and the library and entry IDs to address updates.

### Match a renamed file

Both entry GET endpoints return `fileSize` as an integer number of bytes. When the catalog has an OSHash, they also return `osHash` as a 16-character lowercase hexadecimal string, including leading zeros (for example, `"000000000001ffff"`). If the hash is unavailable, the response omits `osHash` and still includes `fileSize`. Both values come from the catalog, including when the source drive is offline.

To match a renamed file, request `GET /v1/libraries/3/entries?osHash=000000000001ffff&fileSize=131072`. Supply exactly 16 hexadecimal digits in either case. You can omit `fileSize` to search by hash alone. When supplied, `fileSize` requires `osHash` and must be a nonnegative integer byte count. Invalid filters return HTTP 400.

The search uses the cached hash and size, including for offline files. A successful lookup returns HTTP 200 with an empty `entries` array when nothing matches. If several entries match, present the choices by `libraryID` and `id`. Keep the same filters when following `nextAfter`. Both file identity fields are read-only. Use the selected entry’s revision for metadata edits and file renames.

## Rename a file

Read the entry to get its current `revision`, then send a separate JSON request to `POST /v1/libraries/3/entries/42/rename`.

```json
{
  "revision": "<revision from the entry>",
  "basename": "Spring in the Meadow"
}
```

Send the new name without the extension. Vieweroo keeps the existing folder and extension, so `Spring.mov` becomes `Spring in the Meadow.mov`. It updates references in all libraries that contain the file and preserves each entry’s identity and viewing history. The response has the same fields as `GET` for a single entry, including the new `filename` and `revision`.

## Enrich an entry

After reading entry 42 in library 3, send the following body to `PATCH /v1/libraries/3/entries/42`. Substitute the revision returned by the read.

```json
{
  "revision": "<revision from the entry>",
  "title": "Spring in the Meadow",
  "description": "A field study filmed in early spring.",
  "addTags": ["Spring", "Field study"],
  "studio": "Meadow Studio"
}
```

| Patch field | Behavior |
| --- | --- |
| `title` | Sets the local display and search title. JSON `null` restores the PRDB title or filename fallback. The filename and PRDB association stay intact. |
| `description` | Sets the text in the details panel. Use `null` to clear it. |
| `addTags` | Assigns up to 200 tags by name and creates any missing tags in the entry’s library. Name matching ignores case. Repeated assignments preserve existing tags. |
| `studio` | Assigns a studio by name, creating it in the target library if needed. Use `null` to resume automatic studio selection. |
| `siteID` | Assigns a listed PRDB studio by its site ID. Use this for studios that share a name. Supply at most one of `siteID` and `studio` per request. |
| `poster` | Accepts a base64-encoded JPEG or PNG of up to 5 MiB and 40 megapixels, with each dimension at most 16,384 pixels. Vieweroo stores a local JPEG up to 1,600 pixels on its longest edge. Use `null` to restore the usual poster. |

Omitted fields retain their values. For a later poster-only update, send just `revision` and `poster`. Local edits survive rescans.

## Handling failures

A stale revision returns HTTP 409. Re-read the entry, compare the current fields with the intended changes and decide which still apply. An invalid field or image returns 400 and rolls back the entire patch. Duplicate tag or studio creation returns 409. A file rename returns 400 for an invalid name and 409 if the destination is occupied, the source is unavailable or changed on disk, or a scan or another rename is in progress. Unknown libraries, entries and mismatched library/entry IDs return 404. An invalid or missing catalog key returns 401. Requests exceeding the 7 MiB body limit return 413. Error responses contain an `error` string.
