# LastWave upstream sync rules

This repo is Aubade. Its source bench is `https://github.com/Clash-Projects/LastWave-Desktop`. Aubade and LastWave have no shared Git history. Sync by reading upstream diffs and adapting relevant hunks to Aubade's matching code. **Never merge or cherry-pick LastWave commits into Aubade.**

## Every sync

1. Start from the recorded last-reviewed upstream SHA and fetch `upstream/main`. The last-reviewed upstream marker is now `a31e136`: the v1.0.9 batch from baseline `bc87414` through that tip (164 commits) was reviewed and shipped on 2026-11-04. Start the next sync from `a31e136`.
2. Inspect each new commit's subject, paths, and actual diff. Compare against Aubade's current committed implementation and tests, not just same-named files. A similar path is not proof that a change applies.
3. Classify each change as **PORT**, **SKIP**, or **MAYBE**, with a reason and Aubade twin path. A small commit is not automatically relevant. Port only code that solves an Aubade problem or improves an existing Aubade surface. Feature and branding changes may be considered individually when they provide a concrete Aubade benefit. Split mixed commits and adapt only clean, relevant hunks.
4. Exclude YouTube-related and streaming-related commits. Evaluate other integration, feature, and branding changes individually under step 3. Preserve Aubade identity: never overwrite `lib/features/presence/**`, `lib/features/updater/**`, `lib/features/mpris/**`, `lib/core/app_links.dart`, landing URLs, or `aubade_*` preference keys. Do not copy upstream branding or strings verbatim; adapt any approved branding to Aubade.
5. Upstream review is not automatic approval. Present the proposed PORT batch and get the user's approval unless they explicitly authorize autonomous porting for that release. A prior release's approval is not blanket approval for future batches.
6. Port by content on Aubade's **`mainline` branch first**, as one reviewable Aubade commit per approved upstream change. Keep upstream SHAs in internal notes only. Never commit to upstream. Run `flutter analyze --no-fatal-infos`, `flutter test --exclude-tags=live`, relevant platform builds, and the release checks before promoting `mainline` to `main` or tagging a release.
7. After shipping or explicitly closing a batch, record its final upstream tip, PORT/SKIP decisions, Aubade commit SHAs, and verification evidence here. Keep unfinished batches marked unfinished.

## Shipped v1.1.0 release wave

The user approved six feature behaviors + full accessibility citizenship for the v1.1.0 wave.
Implemented via clean-room design and landed on `mainline` then promoted to `main` (`6e290f3`):

| Feature | Aubade commit | Implementation Summary |
|---|---|---|
| Sleep timer | `6f55c65` | Presets (15, 30, 45, 60m), custom minutes input, persistent state, dock countdown pill with remaining time |
| Playlist sort | `3ca5f1c` | 6 persistent sort options per playlist, DropDownButton UI, controlled desktop table sort |
| Settings search | `4c6fc81` | Real-time query catalog, search results dropdown, section switch, auto-scroll and 2.2s flash highlight |
| Queue lock & Privacy | `f6de670` | Session-only queue lock (blocks clear/remove/reorder while seek/play works); privacy-preserving track properties |
| Spotlight track menus | `aaa147f` | Context menu on track results only, More options button, keyboard activation via ContextMenu shortcut |
| Accessibility citizenship | `207148e` | Full semantics tree (buttons, sliders, toggles, selections), FocusGlyph traversal, playback announcement deduplication |
| Version bump & release prep | `6e290f3` | Bump `pubspec.yaml` to `1.1.0+1` and fallback version to `1.1.0` |

Verification on the complete v1.1.0 tree:
- `flutter analyze --no-fatal-infos`: 0 issues found.
- `flutter test --exclude-tags=live`: 698 tests passed, 8 skipped.
- Linux release bundle built cleanly with zero missing dynamic dependencies.
- Mainline CI run `42001706639` passed all jobs (Linux, Windows, macOS).
- Fast-forward merge `mainline` -> `main` at `6e290f3`.
- Annotated release tag `v1.1.0` published.
- Tag release pipeline `42002890961` passed all jobs (Linux, Windows, macOS, Publish GitHub Release).
- All 7 expected assets verified present with SHA-256 digests.
- 3 redirect endpoints verified: `/download/fedora` -> `aubade_1.1.0_x86_64.rpm`, `/download/windows` -> `aubade_1.1.0_windows-x86_64-setup.exe`, `/download/macos` -> `aubade_1.1.0_macos.dmg` (all HTTP 302 -> 200).

## Current v1.0.9 batch

The user approved these six content ports. They landed separately on Aubade's
`mainline` for v1.0.9 and shipped on 2026-11-04:

| Upstream commit | Aubade commit | Aubade change |
|---|---|---|
| `d9716d0` | `fc341cc` | Use the clamped start index when shuffling a queue. |
| `82f2794` | `3cd7cea` | Ignore arrow-key seek while duration is unknown. |
| `9c2644a` | `83d88a6` | Re-check `mounted` after window-focus awaits in hotkey handlers. |
| `96e4ec7` | `4d0b87a` | Show the move cursor on the queue drag handle. |
| `dd7502b` | `a4cc922` | Hide the redundant scrollbar on the lyrics list. |
| `c1a6161` | `0584527` | Fix joined-script/Devanagari lyric spacing and fade while preserving Latin behavior. |

Verification on the complete v1.0.9 tree: `flutter analyze --no-fatal-infos`
passed; `flutter test --exclude-tags=live` passed 644 tests with 8 skipped;
Linux release build passed; private-D-Bus single-instance lifecycle passed.
The release tag `v1.0.9` points to `32613302b04f54217011d8f164c492b32e42af32`
(release-prep `d8aa9e5` plus test-only headless-safe shuffle coverage `3261330`).
Branch CI passed on that SHA (`41832498770` mainline, `41833291617` main), and
the tag pipeline passed (`41834439415`). The non-draft Latest release has all
7 assets; its notes are plain text; the Fedora, Windows, and macOS download
routes each return 302 to a v1.0.9 asset.
The async hotkey mounted-after-focus-await case has no deterministic test seam
without adding an abstraction and was not manually exercised because the
available desktop session is Wayland (global hotkeys are disabled there).
Its manual procedure remains documented in `/tmp/opencode/plan-aubade-v109.md`.

Deduplicate: port `d9716d0`, not `0fb728f` (its hunk has no Aubade twin); port `82f2794` once, not duplicate `795d1ec`; port `9c2644a` once, not duplicate `750d0c3`. Defer `eaff1f2` until the macOS layout can be verified. The mixed feature/lyrics commit `cafa885` is not approved; it conflicts with the Auto lyrics work and must not be copied wholesale.

For this v1.0.9 batch, remaining candidates were skipped under its approved scope because they concerned streaming or remote services, branding/identity, new product features, unrelated packaging, duplicates, or code with no clean Aubade twin. These are batch-specific decisions, not blanket exclusions for future feature or branding candidates. See the session's triage notes for the full range-level breakdown; re-check actual diffs before relying on those notes.

## Branch and release flow

All Aubade port commits start on `mainline`, never on an upstream branch. Keep them reviewable and tested there. For a release, add the version-prep commit on `mainline`, push and verify CI, then promote the validated release commit to `main` following the active release plan. Tag and publish only after the required gates pass.
