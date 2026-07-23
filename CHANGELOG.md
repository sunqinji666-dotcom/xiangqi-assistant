# Changelog

## v1.3.2 — 2026-07-23

- Rebased the public project on the current local source snapshot and rebuilt
  the Apple-Silicon macOS package.
- Updated the Qwen advice flow to choose from locally screened engine
  candidates and add a short practical plan.
- Restored the public credential boundary: API keys are read only from the app
  sandbox, never from a machine-specific absolute path.

## v1.3.1 — 2026-07-22

- Rebuilt and repackaged the current verified Qwen-independent-advice build.
- Kept the public credential boundary and the v1.3.0 local-verification flow.

## v1.3.0 — 2026-07-22

- Added independent Qwen advice: Qwen proposes up to three styles before a
  separate low-resource Pikafish instance verifies legality and tactical safety.
- Added one independent retry when every proposal fails local verification;
  engine scores and the green recommendation are never sent to Qwen first.
- Added purple proposal presentation with style, confidence, rationale, plan,
  candidate order, and a guarded comparison against the green move.
- Added stale-arrow protection so a purple move disappears when the board or
  side to move changes.
- Added manual-correction rebasing through unique one- or two-ply transitions,
  so a corrected piece can move or be captured without staying pinned to its
  original coordinate.
- Added configurable Pikafish threads and hash size for the secondary verifier.
- Added manual visual board review with a sandbox credential location and no
  machine-specific absolute credential path in the public build.

## v1.2.0 — 2026-07-23

- Added durable per-application board geometry, with a legacy recovery copy and
  independent calibration for every selected chess client.
- Added multi-display board selection with an explicit confirmation step and
  safer clipping when a piece edge sits slightly outside the visible window.
- Added five-frame, per-square temporal voting so a moving highlight or one
  flickering cell cannot block an otherwise stable board.
- Added session-locked board orientation, manual board flipping, per-square
  piece correction, automatic-restore controls, turn synchronization, and a
  deliberate position-resync action.
- Added per-source persistence for the most recent trusted board, while keeping
  Pause → Start as a hard fresh-scan boundary.
- Decoupled recognition status from engine retries so a slow or recovering
  Pikafish search no longer looks like a board-recognition failure.
- Improved saved-crop recovery when responsive chess clients resize their board,
  and added regression coverage for temporal consensus.

## v1.1.0 — 2026-07-23

- Added an adaptive Ultra search pipeline: a 2-second answer, 6-second normal
  deepening, and up to 15 seconds for unstable, tactical, or forced-mate positions.
- Kept screen capture and board recognition responsive while Pikafish searches in
  the background; stale results from an earlier position can no longer overwrite
  a newer board.
- Added a fully offline, legality-checked opening book whose candidates must be
  independently verified by unrestricted Pikafish analysis.
- Added single-engine opponent-turn response precomputation, stable near-equal
  recommendations, repetition recovery, correct Red/Black score perspective, and
  mate-distance presentation.
- Added wall-clock UCI timeouts, EOF/process-exit recovery, clean search draining,
  and explicit handling for terminal `bestmove (none)` positions.
- Improved selectable-window filtering, window rebinding, multi-display board geometry,
  reverse-view canonicalization, and recognition diagnostics.
- Retained the same app identity and signing requirement, and added no runtime
  update check or automatic mouse-control behavior.

## v1.0.0 — 2026-07-22

- First public release of 象棋助手-TheOne.
- Added ScreenCaptureKit window selection and board-region calibration.
- Added TheOne1006 ONNX board localization and 10×9 position recognition.
- Added local Pikafish UCI analysis with candidate moves, evaluation, depth, and principal variation.
- Added recognition stability checks and a menu-bar floating-panel experience.
- Published an Apple-Silicon macOS application package with a SHA-256 checksum.
