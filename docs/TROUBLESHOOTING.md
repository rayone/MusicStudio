# Troubleshooting

Each entry lists the problem, the cause, and the fix. Text in `code` quotes is what the app or engine actually prints, so you can search the console for it. For how the pieces fit together see [ARCHITECTURE.md](ARCHITECTURE.md). For build problems see [BUILDING.md](BUILDING.md).

Paths below assume the app is in `/Applications` and your data is in the default `~/.MusicStudio`. Adjust them if you moved either one. Two shorthands used throughout:

```bash
PY=~/.MusicStudio/venv/bin/python3
APP=/Applications/MusicStudio.app/Contents/Resources
```

## Collecting logs

Most problems are easier to diagnose with the console open.

1. Press ⌘K (View > Show Console).
2. The Level menu defaults to Trace, which shows everything. Set it to Debug to hide the noisiest lines but keep engine output, or Warn to see only problems.
3. Use the filter menu to narrow components: "Pipeline Only (AR/NAR/Flow/VAE/CoT)" for generation, "Orchestration (Queue/Worker/App/Power)" for queue and worker problems, or tick `DB`, `EVAL`, `SEARCH` individually.
4. Click Copy. It copies the entries that match the current filters, so set Level to Trace and Select All first if you are attaching logs to a bug report.

The console is in memory only. It keeps roughly the last 5,000 entries and is cleared when you quit.

First-run setup prints its pip output to the app's standard output, not the console. To see it, launch the binary from Terminal:

```bash
/Applications/MusicStudio.app/Contents/MacOS/MusicStudio
```

Lines starting with `[Setup] Pip install result:`, `[Setup] Engine install result:` and `[Setup] Init db:` show what each step did.

## Install and first run

### macOS says the app "is damaged" or is from an "unidentified developer"

Cause: v0.1.0 is ad-hoc signed and not notarized, so Gatekeeper blocks the first launch of a downloaded copy. These are macOS dialogs, not MusicStudio errors.

Fix, any one of:

- Right-click (or Control-click) `MusicStudio.app` in Finder, choose Open, then Open again.
- System Settings > Privacy & Security, scroll to the blocked-app notice, click Open Anyway.
- Remove the quarantine flag:

  ```bash
  xattr -dr com.apple.quarantine /Applications/MusicStudio.app
  ```

The "damaged" wording usually means the quarantine flag is set on an ad-hoc signed app; the `xattr` command fixes it. If you built the app yourself it is not quarantined and this does not apply.

### `uv binary not found (looked in bundle bin/uv, ~/.MusicStudio/bin/uv, and PATH)`

Cause: setup could not find `uv` in any of its three locations. The release bundle ships `Contents/Resources/bin/uv`; this error means the bundle is incomplete (for example a build that skipped the copy step) or the file lost its execute bit.

Fix:

- Re-download the release zip, or rebuild with `./build.command`, which copies `bin/uv` into the bundle.
- Or install uv yourself so it is on `PATH` (`brew install uv`), or place a `uv` binary at `~/.MusicStudio/bin/uv`, then click **Start Setup** again.

### `Failed to create Python 3.12 virtualenv with uv: ...`

Cause: `uv venv ~/.MusicStudio/venv --python 3.12` did not produce `venv/bin/python3`. Common reasons:

- No Python 3.12 on the machine and no network, so uv cannot download its managed Python.
- A corporate proxy or firewall blocking uv's Python download.
- A half-created `~/.MusicStudio/venv` from an earlier attempt.

Fix: read the text after the colon; it is uv's own output. Then:

1. Make sure you are online (set `HTTPS_PROXY` if you are behind a proxy).
2. Delete the partial venv and retry:

   ```bash
   rm -rf ~/.MusicStudio/venv
   ```

   Relaunch and click **Start Setup**.

To test the step by hand:

```bash
"$APP/bin/uv" venv ~/.MusicStudio/venv --python 3.12
```

### `Installing Python dependencies failed ...` or `Installing the YuE2 engine failed ...`

Cause: `uv pip install` exited with an error, usually because PyPI or GitHub was unreachable, or the download was interrupted. The message shows the last lines of uv's output.

Fix: check your connection and click **Start Setup** again. Already-installed packages are reused, so a retry is quick. To see the full output, run the installs by hand:

```bash
"$APP/bin/uv" pip install --python ~/.MusicStudio/venv/bin/python3 -r "$APP/requirements.txt"
"$APP/bin/uv" pip install --python ~/.MusicStudio/venv/bin/python3 --no-deps -r "$APP/engine-requirements.txt"
"$PY" "$APP/studio.py" --db ~/.MusicStudio/studio.db init
```

### `Initializing the database failed: ...`

Cause: `studio.py init` failed. That's usually a missing module from an incomplete install, or a damaged `~/.MusicStudio/studio.db`.

Fix: run the `init` line above to see the full error. If the database is damaged, restore one from `~/.MusicStudio/backups/` (see [Database](#database)), or move `studio.db` aside so setup copies a fresh one.


### Re-running setup from scratch

Setup runs whenever `~/.MusicStudio/venv/bin/python3` or `~/.MusicStudio/studio.db` is missing. To rebuild only the Python environment and keep your database, tracks and models:

```bash
rm -rf ~/.MusicStudio/venv
```

Relaunch the app and click **Start Setup**. Setup skips copying the database and search index if they already exist.

## Models

### Model shows `Weights not yet downloaded to disk`

Cause: the picker checks for `<models folder>/<repo>/config.json` (and, for YuE2, `ar-<quant>.safetensors`). The weights are not there.

Fix: open Help > Model Catalog & Downloads… and click Download. If the button finishes but the model stays unavailable, the download failed. The Model Manager does not show download errors, so check:

- Network access to `huggingface.co`.
- Free disk space (MiniMax bf16 is 28.5 GB).
- Whether the models folder in Settings > Storage is the folder you expect. If you changed it, previously downloaded weights stay in the old folder.

Downloads skip files that already exist with the correct size, so clicking Download again resumes.

### Unavailable reason `Weights not found (checked ~/.MusicStudio/models/...)`

Cause: the Python engine's own check (`studio.py models`, run at every worker start) could not find the weights directory. It looks under the models folder passed by the app and `~/Library/Application Support/YuE2Mac/Models`.

Fix: same as above. To see what the engine sees:

```bash
MUSICSTUDIO_MODELS_DIR=~/.MusicStudio/models "$PY" "$APP/studio.py" --db ~/.MusicStudio/studio.db models
```

Each line is `OK` or `MISS` with the reason in parentheses.

### `YuE2 engine (mlx-yue) not installed in venv` or `YuE2 engine (mlx-yue or generate.py) not found. Please install vanch007/mlx-Yue.`

Cause: the `lyra` package from `mlx-yue` is not importable in the venv. Setup installs it from `Resources/engine-requirements.txt`; that step can fail silently on a network error, and venvs created before this step was added do not have it.

Fix: install it with the same command setup uses. `--no-deps` matters: without it, pip pulls upstream's older pins and downgrades `transformers`, `numpy` and `safetensors` for the whole app.

```bash
"$APP/bin/uv" pip install --python ~/.MusicStudio/venv/bin/python3 --no-deps -r "$APP/engine-requirements.txt"
```

That file pins one line:

```text
mlx-yue @ https://github.com/vanch007/mlx-Yue/archive/9253ed133343406947bde7b67d43c7a63fb39d99.tar.gz
```

Check it worked:

```bash
"$PY" -c "import lyra; print(lyra.__file__)"
```

Availability is refreshed the next time the worker starts, or right away with the `studio.py models` command above.

### `YuE2 8bit weights are not installed` (or `bf16`)

Cause: both YuE2 variants share one repo folder (`vanch007/mlx-Yue2-3B`), but each precision has its own `ar-<precision>.safetensors`. You have the folder but not the file for the precision you picked.

Fix: pick the variant you have, or download the other one from the Model Manager. The per-model folder button opens the directory so you can see which `ar-*.safetensors` files exist.

### `YuE2 model validation failed: ...`

Cause: the YuE2 folder's `conversion.json` is malformed or does not match the files on disk. The engine already drops entries for optional precisions whose files are missing, so this usually means a corrupt or partial download.

Fix: delete the `vanch007/mlx-Yue2-3B` folder in the models directory and download again.

### YuE2 fails right after starting with a VAE or "offline" error

Cause: YuE2 needs the VAE `m-a-p/YuE2-Vae`. The Model Manager does not download it. The engine searches the models folder and the Hugging Face cache, and if it finds nothing it passes the repo id with `--offline`, which fails unless the VAE is already cached. The job error starts with `YuE2 failed:` followed by the engine's last error line.

Fix: download the VAE into the models folder:

```bash
~/.MusicStudio/venv/bin/hf download m-a-p/YuE2-Vae --local-dir ~/.MusicStudio/models/m-a-p/YuE2-Vae
```

### Low RAM, swapping, or the RAM badge `⚠️ ... RAM below 16 GB minimum`

Cause: generation holds the whole model in unified memory. The MiniMax wrapper sets the MLX wired limit to 75% of RAM. If the variant is too large, macOS swaps heavily, generation slows to a crawl, or the process is killed.

Fix:

- Use the variant recommended for your RAM (shown in the Model Manager and in Help > Hardware & System Profile…). MiniMax: 4bit from 16 GB, 6bit from 24 GB, mxfp8 from 32 GB, 8bit from 64 GB, bf16 from 96 GB. YuE2: 8bit from 24 GB, bf16 from 48 GB.
- Quit other memory-heavy apps (browsers, DAWs, other ML tools) while generating.
- Shorter durations use less memory.
- Watch Memory Pressure and Swap Used in Activity Monitor. Sustained yellow or red pressure means the variant is too big.

Below 16 GB, MiniMax is not recommended at all.

## Generation

### Generation is slow, or the ETA is far off

Cause: the first generation per model has no history, so the ETA is a formula. After that it uses the median of your last 20 runs for that model. Real time also depends on duration, steps, quantization, CoT mode, and memory pressure. Every worker start reloads the model.

Fix:

- Expect the first few ETAs to be rough; they calibrate themselves.
- Check swapping (see above). Swapping is the most common cause of very slow runs.
- Lower steps. Flow/NAR cost scales with the step count. MiniMax defaults to 30 (the tuned quality setting); fewer steps is faster at some cost in quality. On the YuE2 lyra engine the step value is not passed through, so changing it does not affect speed there.
- YuE2: CoT Off skips the planning stage and is fastest. Melody Only is cheaper than Full.
- Queue several songs at once so they share one worker process.
- The app keeps the Mac awake while generating, but closing the lid on battery can still sleep it.

### The job fails with `MiniMax failed: ...` or `YuE2 failed: ...`

Cause: the engine process exited with an error. The text after the colon is the engine's last `ValueError`, `RuntimeError` or `FileNotFoundError` line, or its last output line.

Fix: read that message first. Out-of-memory crashes often show only a terse last line or an exit code; treat those as the low-RAM case. For more context, set the console to Debug and filter to `MODEL`: the engine's raw output is logged there line by line. The status bar shows `Queue finished with errors — open Queue for details`; the Queue popover lists the error per job and has a button to dismiss failed jobs.

### Prompt was shortened: `Prompt exceeded budget (N tokens > 4500). Auto-trimmed K lyric line(s) to M tokens.`

Cause: MiniMax has a 5,000 token prompt ceiling. MusicStudio keeps a working budget of 4,500. When caption plus lyrics exceed it, lyric lines are dropped from the end (along with trailing blank lines and section tags) until it fits. The caption is not trimmed.

Fix: shorten the lyrics or the caption, or split the song. To check a prompt before queueing:

```bash
"$PY" "$APP/studio.py" --db ~/.MusicStudio/studio.db tokens --caption "your caption" --lyrics "$(cat lyrics.txt)"
```

YuE2 does not use this budget.

### The ABC score editor disappeared, or my score was ignored

Cause: the ABC score only feeds YuE2's symbolic planning. The editor is shown, and the score sent, only when a YuE2 model is selected and CoT mode is Full or Melody. With CoT Off, or with a MiniMax model, the editor is hidden and the score is not sent with the job.

Also, selecting a YuE2 model resets CoT to Full (and steps to 32, guidance to 1.0). If you had chosen Off or Melody, set it again after switching models.

Fix: select a YuE2 model, set CoT to Full or Melody, and the editor comes back with your text intact.

### Output is silent, very short, or ends early

Causes and fixes:

- MiniMax stopped at an end-of-sequence token. The console shows `EOS at frame N` under `AR`. Frames run at 25 per second, so N/25 is the length in seconds. Try another seed, add more lyric structure, or use a longer duration.
- `No frames generated`: the model ended immediately. Change the seed or prompt.
- Lyrics were trimmed for the token budget (see above), so the song is shorter than intended.
- Instrumental is on, so no vocals are rendered. Check the toggle in the parameter header.
- Loudness normalisation failed (`Loudness normalisation skipped: ...`), leaving a quiet track. The pre-normalisation copy is kept as `<name>_raw.wav` next to every track so you can compare.

## Audio

### MP3 export fails: `lameenc is not installed in venv`

Cause: MP3 encoding uses the `lameenc` Python package. It is in `requirements.txt` but missing from the venv, usually because the first-run install failed partway. The track itself is kept: the worker logs `Conversion failed: lameenc is not installed in venv; keeping WAV`.

Fix:

```bash
"$APP/bin/uv" pip install --python ~/.MusicStudio/venv/bin/python3 -r "$APP/requirements.txt"
```

M4A and FLAC use macOS's built-in `afconvert` and do not need extra packages.

### Plugin: `<name> is an instrument, not an effect.`

Cause: you picked a synth or sampler. MusicStudio only processes audio through effect plugins.

Fix: choose an effect plugin. Some bundles contain several plugins; if an effect and an instrument share a bundle, the default one loaded may be the instrument.

### VST3 changes are not heard live

Cause: macOS's AVAudioEngine can host Audio Units but not VST3. VST3 plugins are rendered offline through Spotify's pedalboard. The preview re-renders shortly after you stop changing a value and plays the result. The inspector says so: "Load a VST3 or Audio Unit effect to hear it on this track. Audio Units preview live; VST3 updates when you pause."

Fix: if the plugin also ships an Audio Unit (`.component`), load that instead for live preview and the plugin's own editor window.

### `This plugin reports raw values only. Use its window for real controls.`

Cause: you loaded an Audio Unit with no matching VST3 build installed. Readable parameter names and units come from the VST3 sibling (same bundle name in `/Library/Audio/Plug-Ins/VST3` or `~/Library/Audio/Plug-Ins/VST3`). Without it, only normalized 0..1 values are available.

Fix: use the plugin's window (button in the inspector) for real controls, or install the plugin's VST3 build so the inspector can label its parameters.

### Plugin fails to load: `Could not load plugin: ...` or `pedalboard unavailable: ...`

Cause: pedalboard could not open the plugin (unsupported architecture, licence check, crash on load), or pedalboard is missing from the venv.

Fix: for the second message, rerun the `requirements.txt` install above. For the first, check that the plugin is a native Apple Silicon or universal build and opens in another host.

## SongBench evaluation

SongBench is licensed by Tencent for academic use only. Do not use it for commercial or production work. Generating, mastering and exporting music work without it. See [NOTICE.md](../NOTICE.md).

### `SongBench CPU runtime is not installed`

Cause: SongBench runs in its own environment at `~/.MusicStudio/venvs/songbench-reference` with PyTorch 2.7, torchaudio, MuQ, librosa, hydra-core and safetensors. It is installed on first evaluation, and this message appears while it is missing or was only partly installed.

Fix: click the evaluation pill again and let the install finish. It is a large download. If it keeps failing, you see `SongBench CPU environment creation failed` or `SongBench CPU dependency installation failed`; install by hand to see the error:

```bash
"$APP/bin/uv" venv --python ~/.MusicStudio/venv/bin/python3 ~/.MusicStudio/venvs/songbench-reference
"$APP/bin/uv" pip install --python ~/.MusicStudio/venvs/songbench-reference/bin/python3 -r "$APP/songbench-reference-requirements.txt"
```

### Evaluation shows failed or `Evaluation interrupted; retry available`

Cause: the evaluation was stopped (app quit, queue paused) or errored. A failed evaluation never deletes or fails the track; the status bar shows `Evaluation failed — track preserved`.

Fix: click the pill to retry. Filter the console to `EVAL` for the reason.

## Songwriter

Settings > API has the URL, token, enable toggle, and Test Connection.

| Message | Cause | Fix |
|---|---|---|
| `Enter a valid Songwriter API URL.` | URL is not plain `http` or `https` with a host, or contains a username, password, query string or fragment. | Use a base URL like `http://127.0.0.1:8000`. Nothing after the port. |
| `Enter a Songwriter Bearer token.` | Token is empty. | Enter the server's token. The local default is `musicstudio`; "Reset to Localhost" restores it. |
| `Songwriter API integration is disabled in Settings.` | The enable toggle is off. | Turn it on in Settings > API. |
| `Songwriter request failed (HTTP 401).` (or another status) | The server rejected the request. 401/403 usually means a wrong token. | Check the token and the server's logs. |
| `Songwriter returned an invalid response.` | The server replied but not with the JSON the [contract](songwriter-api-contract.md) describes. | Check the server version against the contract. |
| A system "could not connect" error | Nothing is listening at that address (connection refused), or a firewall blocks it. Requests time out after 8 to 15 seconds. | Start the Songwriter server and confirm with `curl -H "Authorization: Bearer <token>" "http://127.0.0.1:8000/v1/songs?status=ready&limit=1"`. |

Results reported back after generation are best-effort. If the server is unreachable, the worker logs `Songwriter report deferred` and retries up to 20 pending reports the next time the worker starts. The track is unaffected.

## AI Search returns nothing or seems to ignore my query

Causes:

- Queries shorter than 3 characters always use Text Match.
- The first AI Search downloads the embedding model `mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ` from Hugging Face. Offline, it fails.
- If the search process fails or returns no rows, the library falls back to Text Match without a message. Results then look like a plain keyword filter, and a query with no literal matches shows nothing.
- The search index is fixed at build time. Presets you create yourself are found by Text Match only.

Fix: go online for the first search, then check whether search works on its own:

```bash
"$PY" "$APP/studio.py" --db ~/.MusicStudio/studio.db search "warm lo-fi piano" --limit 5
```

It prints a JSON list, or an error explaining the failure. `[]` with exit code 1 means `~/.MusicStudio/embeddings.npy` or `embedding_ids.npy` is missing and the bundled copies could not be found either; delete `~/.MusicStudio/venv` and re-run setup to recopy them, or copy them from `$APP`.

## Database

### Where are the backups?

Before every schema migration the engine copies the database to:

```text
~/.MusicStudio/backups/studio-v<old version>-<YYYYmmdd_HHMMSS>.db
```

The 5 newest are kept. Make one by hand at any time:

```bash
"$PY" "$APP/studio.py" --db ~/.MusicStudio/studio.db schema --backup
```

`schema --status` shows the current and target versions and any pending migrations.

### Migration failed: `Migration vN -> vN+1 failed: ...`

Cause: a migration raised an error. Migrations run in a transaction, so the database is rolled back to version N and is not half-migrated. A backup was taken before the attempt.

Fix: copy the full message from the console (`DB` component) into a bug report. You can keep using the backup with an older app version in the meantime.

### Restoring a backup

1. Quit MusicStudio so nothing has the database open.
2. Keep the current database, just in case:

   ```bash
   cd ~/.MusicStudio
   mkdir -p restore-saved
   mv studio.db studio.db-wal studio.db-shm restore-saved/ 2>/dev/null
   ```

3. Copy the backup into place:

   ```bash
   cp backups/studio-v9-20261001_120000.db studio.db
   ```

4. Start the app. If the backup is an older version, the next worker run migrates it forward (and backs it up first).

Generations made after the backup was taken disappear from the history. Their audio files stay in the output folder and can be reopened from Finder.

## Reset everything

Data loss warning: these commands delete your generation history, queue, style presets you created, downloaded models (in the default location), and, if you never changed the output folder, every track you generated. They cannot be undone. Copy `~/.MusicStudio/output` somewhere safe first if you want to keep your music.

To reset preferences only, use Settings > Storage > Reset All Preferences…. That keeps audio, models and the database.

To reset everything:

1. Quit MusicStudio.
2. Delete the data folder:

   ```bash
   rm -rf ~/.MusicStudio
   ```

3. Delete preferences:

   ```bash
   defaults delete ai.opencode.mlx.musicstudio
   ```

4. Optional. Delete the cached embedding model and engine temp files:

   ```bash
   rm -rf ~/.cache/huggingface/hub/models--mlx-community--Qwen3-Embedding-0.6B-4bit-DWQ
   rm -rf "$TMPDIR/musicstudio" "$TMPDIR/musicstudio_yue2"
   ```

5. If you set a custom models or output folder, delete those folders separately. They are not inside `~/.MusicStudio`.

The next launch shows first-run setup again.
