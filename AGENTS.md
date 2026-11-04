# LastWave upstream sync rules

This repo is Aubade. Its source bench is `https://github.com/Clash-Projects/LastWave-Desktop`. Aubade and LastWave have no shared Git history. Sync by reading upstream diffs and adapting relevant hunks to Aubade's matching code. **Never merge or cherry-pick LastWave commits into Aubade.**

## Every sync

1. Start from the recorded last-reviewed upstream SHA and fetch `upstream/main`. Current v1.0.9 batch: baseline `bc87414`, fetched tip `a31e136` on 2026-11-04 (164 commits). Do not advance this marker until the batch is either shipped or explicitly closed.
2. Inspect each new commit's subject, paths, and actual diff. Compare against Aubade's current committed implementation and tests, not just same-named files. A similar path is not proof that a change applies.
3. Classify each change as **PORT**, **SKIP**, or **MAYBE**, with a reason and Aubade twin path. A small commit is not automatically relevant. Port only code that solves an Aubade problem or improves an existing Aubade surface. Split mixed commits and adapt only clean, relevant hunks.
4. Skip YouTube, streaming, remote-catalog, Spotify/Jam/Canvas, LastWave branding, and unrelated new product surfaces. Never overwrite Aubade identity or integration files: `lib/features/presence/**`, `lib/features/updater/**`, `lib/features/mpris/**`, `lib/core/app_links.dart`, landing URLs, or `aubade_*` preference keys. Do not copy upstream branding or strings into Aubade.
5. Upstream review is not automatic approval. Present the proposed PORT batch and get the user's approval unless they explicitly authorize autonomous porting for that release. A prior release's approval is not blanket approval for future batches.
6. Port by content on Aubade's **`mainline` branch first**, as one reviewable Aubade commit per approved upstream change. Keep upstream SHAs in internal notes only. Never commit to upstream. Run `flutter analyze --no-fatal-infos`, `flutter test --exclude-tags=live`, relevant platform builds, and the release checks before promoting `mainline` to `main` or tagging a release.
7. After shipping or explicitly closing a batch, record its final upstream tip, PORT/SKIP decisions, Aubade commit SHAs, and verification evidence here. Keep unfinished batches marked unfinished.

## Current v1.0.9 batch

The user approved these six content ports. They landed separately on Aubade's
`mainline` for v1.0.9. Release publication is still pending:

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
The async hotkey mounted-after-focus-await case has no deterministic test seam
without adding an abstraction and was not manually exercised because the
available desktop session is Wayland (global hotkeys are disabled there).
Its manual procedure remains documented in `/tmp/opencode/plan-aubade-v109.md`.

Deduplicate: port `d9716d0`, not `0fb728f` (its hunk has no Aubade twin); port `82f2794` once, not duplicate `795d1ec`; port `9c2644a` once, not duplicate `750d0c3`. Defer `eaff1f2` until the macOS layout can be verified. The mixed feature/lyrics commit `cafa885` is not approved; it conflicts with the Auto lyrics work and must not be copied wholesale.

Other commits in this range were skipped because they concern streaming or remote services, branding/identity, new product features, unrelated packaging, duplicates, or code with no clean Aubade twin. See the session's triage notes for the full range-level breakdown; re-check the actual diffs before relying on those notes.

## Branch and release flow

All Aubade port commits start on `mainline`, never on an upstream branch. Keep them reviewable and tested there. For a release, add the version-prep commit on `mainline`, push and verify CI, then promote the validated release commit to `main` following the active release plan. Tag and publish only after the required gates pass.
