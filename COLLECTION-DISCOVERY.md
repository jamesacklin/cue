# Finding the next record in Sleeve

## Product requirements · proposed

A collector with over a terabyte of music can remember a scene, a label logo, or the artist on the adjacent record long after forgetting an album title. Sleeve should let them start with any of those clues and finish with an album they own. Keep the cover shelf as the opening view. Give it three entrances visible without typing a search query: decades, record labels, and artists.

**First listening session.** Choose the 1990s, narrow to Warp, and recognize a cover. Open it, then ask which other artists in this collection released music on Warp around that time. Start a record, follow one of those artists into another decade, and use Back to return to the same spot on the original shelf. The album keeps playing throughout.

## What the first release needs

| Requirement | Expected behavior |
| --- | --- |
| R1 · Browse by decade | Show decades with album counts. Selecting one reveals its covers and a year breakdown. Use the album year reported by Plex and offer an Unknown year shelf. Display the year basis on detail, particularly for reissues. |
| R2 · Dig through a label | Offer a searchable record-label index and make the imprint on an album clickable. On a label shelf, show releases by year with the credited artist and cover. Every distinct Plex album remains selectable, including a second edition. Preserve display spelling. Normalize case and surrounding whitespace for lookup. Merge aliases or parent imprints only with confirmed identity. |
| R3 · Combine clues | Decade, label, and text search narrow the same shelf by intersection. Show the active choices and matching count. Clearing one choice preserves the others. Support keyboard selection and Back, restoring sort, scroll position, and focus to the initiating cover. Use accessible labels with names and counts. |
| R4 · Follow a related artist | From an artist, offer another artist with albums in this library and a reason for the connection. Prefer a resolved Plex similar-artist link. Where that is absent, offer a separate path through a shared imprint, showing the record on each side that establishes it. Explicitly choosing a related artist opens their owned albums across decades. Back restores the original filters. |
| R5 · Recommend an album | From an album, offer up to three other records in the selected library. Prefer a related artist with a release on the same imprint and in the same decade, then a related artist, then another artist on the imprint. Show the actual matching evidence on each pick. Exclude the seed, rotate among tied candidates on request, and show fewer picks when evidence runs out. Only Play or a queue action changes playback. |
| R6 · Browse at collection scale | Index album metadata independently of audio size. Reuse the last complete index for the same account, server, and section during refresh. Distinguish partial first-load counts from complete counts. Fetch visible artwork on demand. Opening a facet must not require a request per matching album. Switching libraries discards late results from the previous one. |
| R7 · Handle sparse collections | A record with a missing imprint remains in the decade shelf and an Unknown label group. Where similarity data is sparse, show the available route or a way back to the artist index. Keep the six sample albums playable with the same navigation rules. |

## What to build next

| Priority | Collector request | Acceptance condition |
| --- | --- | --- |
| Next | Save a shelf such as “1970s ECM” for a future session. | Save the filter choices against this library. After a refresh, a newly added matching album appears when the shelf reopens. |
| Next | Pull a neglected record from the shelf I am already browsing. | Offer one album within the active filters. Show the last recorded play date and its source when known. Treat missing history as unknown. Permit another draw without repeating a record until the eligible shelf is exhausted. |
| Experiment | Find a record that sounds familiar but comes from another scene. | When Plex returns sonic album neighbors, offer one owned record from a different known imprint. Show both imprints and attribute the sound match to Plex. Suppress this option when the server has no qualifying result. |
| Experiment | Follow the people in the liner notes. | With verified credits, show a named person, role, and the two owned releases or tracks they connect. Clicking a track credit opens the relevant album at that track. Test demand before adding an external metadata dependency. |

## Research behind the designs

- **Browse the intersections.** Radiooooo organizes music by country and decade. Sleeve can use the collector’s own coordinates instead. Prototype a label-by-decade grid with album counts. A row reveals the label’s history and a cell opens its covers. Compare it with two sequential filters by asking the listener to find the earliest decade where they own a Warp release. [Radiooooo’s description of its service](https://radiooooo.com/termsofuse.pdf)
- **Walk a label’s catalogue.** Discogs gives labels a discography and groups editions on a label page using catalogue numbers. Try a “previous / next on this label” action on an album sleeve. Use release-year order by default and offer catalogue order only when identifiers have been verified. A gap in numbering need not imply a missing record. [Discogs label glossary](https://support.discogs.com/hc/en-us/articles/360004017694-Database-Glossary) · [Discogs master release guidelines](https://support.discogs.com/hc/en-us/articles/360005055493-Database-Guidelines-16-Master-Release)
- **Change one thing about the next record.** Plex documents sonically similar albums from a listener’s library. Give the listener a more specific question such as “same sound, different label.” Compare that pick with a same-label suggestion and ask which connection makes them curious enough to play the album. Sonic analysis requires the server administrator’s Plex Pass and completed analysis for relevant material. [Plex sonic analysis](https://support.plex.tv/articles/sonic-analysis-music/)
- **Read a credit as a route.** MusicBrainz models recording-level performance and remix credits. An album-level recommendation could say “the remixer on track 4 also appears on this EP,” with both credits inspectable. Test this with compilations, where the album artist alone often leads back to Various Artists. [MusicBrainz artist relationship guide](https://musicbrainz.org/doc/Artist_Relationship_Guide_for_Artists)

## Plex feasibility and first live check

Sleeve currently loads paginated albums with a Plex item ID, title, artist display name, optional year, added date, and thumbnail. Those fields already support decade browsing. Record labels, stable artist identity, play history, and relationship evidence require additional decoding or requests. The Python PlexAPI project documents candidate fields for its client. Verify their presence and meaning on the selected server before estimating coverage. [PlexAPI audio models](https://python-plexapi.readthedocs.io/en/latest/modules/audio.html)

| Question on the real library | Decision driven by the answer |
| --- | --- |
| Does album studio match the record label on several known releases, including a reissue and a compilation? Is it returned on list pages or only in detail? | Use verified imprint data. Keep Plex label tags separate. If bulk coverage is poor, ship decade browsing first and measure the cost of filling label data in the background. |
| Which years does Plex report for a known original and a later reissue? | Default to “Plex album year.” Introduce original-release and edition-year views only if the two dates can be distinguished reliably. Never substitute the library-added date for a release year. |
| Can artist metadata and similar-artist results be joined to owned albums using stable identifiers? What happens with namesakes? | Prefer server-scoped artist IDs. Skip ambiguous matches. Record the share of sampled artists with at least one resolvable owned neighbor. |
| Does this account expose reliable play dates, and does a play in Sleeve update Plex history? Does the server return sonic neighbors? | Enable each history or sonic feature independently after confirming its inputs. If only local plays are available, label the evidence “played in Sleeve.” |

During the live session, record album and artist counts, year and imprint coverage, page request counts, and warm filtering latency. Redact tokens and playback URLs. As a proposed scale target, exercise a 10,000-album metadata fixture and aim for p95 under 200 ms from a warm filter change to updated titles and counts on the test Mac. Record the actual machine, corpus, and results. The fixture size is a benchmark choice. The collector’s disk usage alone cannot determine the number of albums.

## User stories and acceptance examples

| ID | As a collector, I want to… | I know it works when… |
| --- | --- | --- |
| S1 · R1 | Start with “the ’90s” because I cannot remember a title. | A 1990 album and a 1999 album both appear. A 2000 album appears in the next decade. An undated album is reachable under Unknown year. |
| S2 · R2–3 | See the Warp records I own from that decade. | Choosing Warp then 1990s yields the same albums and count as choosing them in reverse. Removing Warp restores all my ’90s records. |
| S3 · R2 | Pick the exact edition whose artwork I remember. | Two Plex releases with the same artist and title both open their own track lists, and playing either selects that edition. |
| S4 · R4 | Use a familiar artist to find another one I own. | A Plex-linked artist opens to at least one owned album. A shared-label suggestion names the imprint and shows a release by each artist. A namesake with ambiguous identity is skipped. |
| S5 · R5 | Find one more album for tonight without losing the record already playing. | Each suggestion explains its connection. Inspecting it leaves the current track and queue intact. Choosing Play starts the selected album in disc order. |
| S6 · R3 | Retrace my steps after a few interesting detours. | From a filtered shelf, I open a record, follow an artist, then go back twice using the keyboard. Focus returns to the original cover at its previous scroll position. |
| S7 · R6–7 | Keep exploring while my large library refreshes. | A slow or failed refresh preserves the last complete shelf. On first load, I can distinguish incomplete counts from an empty library. Changing servers mid-refresh never mixes their albums. |
| S8 · Next | Reopen a favorite label-and-decade shelf next month. | My saved shelf survives relaunch and includes a matching record added since I saved it. |
| S9 · Next | Rediscover music buried behind the same handful of favorites. | A draw stays within my shelf, explains its history evidence, and gives me a different eligible album on the next draw. |
| S10 · Experiments | Choose what kind of connection to follow. | On a qualifying record I can distinguish a Plex sound match from a shared musician, inspect the evidence, and open the recommended album. |

**Release check.** Have the collector find a remembered record by decade and imprint, then choose an unfamiliar owned album through an artist connection. Record time to first play, any wrong turns, and whether the listener can explain why the second album appeared. Repeat with a sparsely tagged album. Use those observations to decide whether the grid, deeper label catalogues, or richer artist links deserve the next iteration.
