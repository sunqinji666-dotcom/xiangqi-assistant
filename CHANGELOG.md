# Changelog

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
