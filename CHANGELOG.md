# Changelog

All notable changes to MusicStudio are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the project uses [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.1.0] - 2026-10-06

### Added
- Native SwiftUI macOS app for Apple Silicon with Create and Studio tabs.
- MiniMax Music 3 (4bit, 6bit, mxfp8, 8bit, bf16) and YuE2-3B (8bit, bf16) generation through MLX.
- First-run setup: hardware profiling, an isolated Python 3.12 environment via the bundled `uv`, and a seeded preset catalog.
- Model Manager with RAM-aware recommendations and Hugging Face downloads.
- Style library of ~5,700 presets with semantic AI Search (default) and FTS5 keyword search, filters and keyword chips.
- Lyrics editor with structure tags and a token budget. ABC score editor for YuE2 CoT planning.
- Persistent render queue with batches, seed locking, pause/resume and calibrated ETAs.
- Loudness normalisation (−14 LUFS / −1 dBTP), WAV/MP3/M4A/FLAC export, and rich ID3/MP4/Vorbis tags.
- Studio tab: spectrogram, DSP analysis, realtime Audio Unit and offline VST3 effects.
- Mastering chain (EQ, air lift, artifact reduction) via the `studio.py master` command.
- SongBench quality evaluation (academic use only).
- Songwriter API integration: import songs and report generations.
- App icon.
- `build.command --release` packaging with optional Developer ID signing and notarization.

### Changed
- AI Search is the default search mode in the style library.
- The ABC score editor is shown only when the selected model and CoT mode use a score (YuE2 with Full or Melody). With CoT Off, the score is no longer sent to the engine.
- Create tab layout fills the full window height.
- Songs imported from Songwriter are saved as `[Title]_[Timestamp]` instead of `song_[Timestamp]`.
- First-run setup now installs the YuE2 engine (`mlx-yue`, pinned commit) from `Resources/engine-requirements.txt`. Previously it had to be installed by hand.
- Local database backups are no longer copied into the app bundle.

[0.1.0]: https://github.com/rayone/MusicStudio/releases/tag/v0.1.0
