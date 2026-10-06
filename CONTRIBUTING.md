# Contributing

Thanks for helping improve MusicStudio. Bug reports, fixes, docs and presets are all welcome.

## Reporting bugs

Open an [issue](https://github.com/rayone/MusicStudio/issues/new/choose) and include:

- MusicStudio version (Finder → Get Info on the app), macOS version, Mac model and RAM.
- The model and settings you used (family, quantisation, duration, steps, CoT mode).
- Console output: press ⌘K, set the level to Debug, reproduce the problem, then copy the relevant lines.

## Development setup

```bash
xcode-select --install
git clone https://github.com/rayone/MusicStudio.git && cd MusicStudio
./build.command && open MusicStudio.app
```

The app needs a completed first-run setup (`~/.MusicStudio/venv`) to render. See [docs/BUILDING.md](docs/BUILDING.md) for the full workflow and [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for how the pieces fit.

To iterate on the Python engine without rebuilding the app, run it with the app's environment:

```bash
~/.MusicStudio/venv/bin/python Resources/studio.py --help
```

## Pull requests

1. Branch from `main`. Keep each PR to one topic.
2. Match the existing style: SwiftUI views in `Sources/Views/`, state in `StudioViewModel`, colours and fonts from `Theme`. Python follows the conventions in `studio.py`.
3. **Database changes need a migration.** Bump `CURRENT_SCHEMA_VERSION` and add a `@register_migration(n)` function. Never change the meaning of an existing column. The rules are in the comment block at the top of the schema section in `studio.py`.
4. **Pin new Python dependencies** to exact versions in `Resources/requirements.txt`, with a short comment saying why they're needed.
5. Make sure `./build.command` succeeds without new errors. Exercise the changed feature in the running app and describe what you tested in the PR.
6. Add a line under `## [Unreleased]` in `CHANGELOG.md`.

By contributing you agree that your contributions are licensed under the MIT License. Changes to `Resources/songbench/` stay under Tencent's SongBench terms.
