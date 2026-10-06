# Building and releasing

MusicStudio has no Xcode project. `build.command` compiles every Swift file in `Sources/` with `swiftc` and assembles the `.app` bundle by hand, so the only prerequisite is the Swift compiler.

## Prerequisites

| Need | Why | Install |
|---|---|---|
| Apple Silicon Mac, macOS 14+ | MLX and the app's deployment target | — |
| Xcode Command Line Tools (Swift 6) | `swiftc`, `codesign`, `ditto` | `xcode-select --install` |
| Xcode (full) | Only for notarization (`notarytool`, `stapler`) | App Store |
| Developer ID certificate | Only for signed public releases | [developer.apple.com](https://developer.apple.com/account/resources/certificates) |

`bin/uv` (uv 0.12.9, arm64) is committed to the repo and copied into the bundle, so neither building nor first-run setup needs Homebrew or a system Python.

## Build commands

```bash
./build.command              # build MusicStudio.app (ad-hoc signed)
./run.command                # rebuild only if anything changed, then open the app
./build.command --release    # build + dist/MusicStudio-<version>.dmg + .sha256
```

`run.command` compares the modification time of every file in `Sources/`, `Resources/` and `build.command` against the built binary, and rebuilds only when something is newer.

### What `build.command` does

1. Compiles `Sources/**/*.swift` with `swiftc -parse-as-library -O` into a single arm64 binary.
2. Recreates `MusicStudio.app` from scratch, so stale files never linger.
3. Copies `Resources/` into `Contents/Resources/`, **excluding** `backups/` (local database backups contain personal history), `__pycache__/`, `*.pyc` and `.DS_Store`.
4. Writes `Info.plist` with the version, bundle id `ai.opencode.mlx.musicstudio`, icon, minimum macOS 14 and the local-network usage string.
5. Copies `bin/uv` into `Contents/Resources/bin/uv`.
6. Signs the bundle (see below) and runs `codesign --verify --deep --strict`.
7. With `--release`, stages the app and an `/Applications` symlink into a compressed UDZO `.dmg` via `hdiutil`, signs/notarizes it if configured, and writes a SHA-256 checksum.

### Build-time variables

| Variable | Default | Effect |
|---|---|---|
| `VERSION` | `0.1.0` | `CFBundleShortVersionString`, `CFBundleVersion`, and the DMG name |
| `CODESIGN_IDENTITY` | *(unset → ad-hoc)* | Sign with this identity under the hardened runtime |
| `NOTARY_PROFILE` | *(unset)* | `notarytool` keychain profile. Notarizes and staples the release. Requires `CODESIGN_IDENTITY`. |

## Signing and notarization

**Ad-hoc (default).** `codesign --sign -`. The app runs on the machine that built it. On other Macs, Gatekeeper blocks it until the user right-clicks → **Open**, or runs `xattr -dr com.apple.quarantine MusicStudio.app`. v0.1.0 ships this way.

**Developer ID + notarization (recommended for public releases).**

```bash
# One-time: store notarization credentials in the keychain
xcrun notarytool store-credentials musicstudio-notary \
  --apple-id you@example.com --team-id TEAMID --password <app-specific-password>

# Signed, notarized, stapled release
CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
NOTARY_PROFILE=musicstudio-notary \
VERSION=0.1.1 \
./build.command --release
```

With a Developer ID, the script signs `bin/uv` first, then the app, both with `--options runtime --timestamp`. The app gets one entitlement:

| Entitlement | Why |
|---|---|
| `com.apple.security.cs.disable-library-validation` | Audio Unit plugins from other vendors load into the app's process. Without this, the hardened runtime refuses any plugin not signed by your team. |

The app is not sandboxed. It writes to `~/.MusicStudio`, launches Python subprocesses and loads user plugins, none of which the App Sandbox allows without significant redesign.

## Publishing a release on GitHub

```bash
# 1. Bump the version in build.command (VERSION default) and add a CHANGELOG section
# 2. Build the release artifacts
./build.command --release

# 3. Tag and push
git tag -a v0.1.1 -m "MusicStudio 0.1.1"
git push origin v0.1.1

# 4. Create the release with the zip and checksum attached
gh release create v0.1.1 dist/MusicStudio-0.1.1.dmg dist/MusicStudio-0.1.1.dmg.sha256 \
  --title "MusicStudio 0.1.1" --notes-file <(sed -n '/## \[0.1.1\]/,/## \[/p' CHANGELOG.md | sed '$d')
```

Release checklist:

- [ ] `CHANGELOG.md` has a section for the version, and the compare/tag link at the bottom.
- [ ] `./build.command --release` finishes with no errors and `codesign --verify` passes.
- [ ] On a clean user account (or after moving `~/.MusicStudio` aside), the app completes first-run setup, downloads a model and renders a song.
- [ ] Mounted from `dist/`, the app opens and runs.
- [ ] `seed_studio.db` contains no personal data: `sqlite3 Resources/seed_studio.db "select count(*) from generations; select count(*) from jobs;"` both return `0`.

## Changing what gets installed on first launch

| File | Installed with | Notes |
|---|---|---|
| `Resources/requirements.txt` | `uv pip install -r` | All Python dependencies, pinned to exact versions |
| `Resources/engine-requirements.txt` | `uv pip install --no-deps -r` | The YuE2 engine (`mlx-yue`, imported as `lyra`), pinned to a commit. Its runtime deps live in `requirements.txt` because upstream's own pins would downgrade the shared stack. |
| `Resources/songbench-reference-requirements.txt` | Separate venv `~/.MusicStudio/venvs/songbench-reference` | Only for SongBench evaluation (academic use only) |

To check a dependency change before shipping, reproduce the bootstrap in a throwaway environment:

```bash
T=$(mktemp -d)
bin/uv venv "$T/venv" --python 3.12
bin/uv pip install --python "$T/venv/bin/python" -r Resources/requirements.txt
bin/uv pip install --python "$T/venv/bin/python" --no-deps -r Resources/engine-requirements.txt
"$T/venv/bin/python" -c "import lyra, mlx_audio, pedalboard, librosa; print('ok')"
cp Resources/seed_studio.db "$T/studio.db"
MUSICSTUDIO_HOME="$T" "$T/venv/bin/python" Resources/studio.py --db "$T/studio.db" init
rm -rf "$T"
```

Existing users don't re-run setup automatically. After changing requirements, tell them to delete `~/.MusicStudio/venv` and relaunch, or run the same `uv pip install` commands against `~/.MusicStudio/venv/bin/python`.

## Regenerating the app icon

`Resources/AppIcon.icns` was rendered programmatically with AppKit (a Tokyo Night palette waveform with sparkles) and packed with `iconutil`. To replace it, create a `MusicStudio.iconset` folder containing `icon_16x16.png` … `icon_512x512@2x.png`, then run:

```bash
iconutil -c icns MusicStudio.iconset -o Resources/AppIcon.icns
sips -s format png -z 256 256 Resources/AppIcon.icns --out docs/images/icon.png
```

## Continuous integration

`.github/workflows/build.yml` compiles the app on a macOS arm64 runner for every push and pull request. It checks that the Swift sources build and the bundle assembles. It doesn't install the Python engine or run models, because GitHub runners lack the RAM and GPU those need.
