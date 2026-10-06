# Command-line engine (`studio.py`)

Everything MusicStudio does to audio runs through one Python script, `studio.py`. The app starts it as a subprocess and reads its output. You can run it yourself to generate songs, convert and tag files, measure loudness, master, search the style library, or estimate render times from scripts.

For the app itself see the [User Guide](USER_GUIDE.md). For errors see [TROUBLESHOOTING.md](TROUBLESHOOTING.md).

## Running it

Use the Python environment that first-run setup created, so all dependencies (MLX, mlx-audio, the YuE2 `lyra` engine, pedalboard, librosa) are available:

```sh
PY=~/.MusicStudio/venv/bin/python
STUDIO=/Applications/MusicStudio.app/Contents/Resources/studio.py   # or Resources/studio.py in a source checkout

"$PY" "$STUDIO" models
```

The script must stay next to its bundled resources (`songbench/`, `catalog.json`, `embeddings.npy`), so run it from the app bundle or the repo's `Resources/` folder rather than copying it elsewhere.

Global flags go before the subcommand:

```sh
"$PY" "$STUDIO" [--db PATH] [--output-dir PATH] <command> [args...]
```

| Flag | Default | Notes |
|---|---|---|
| `--db PATH` | `$MUSICSTUDIO_DB`, else `~/.MusicStudio/studio.db` | SQLite database used by every command that touches history, presets or the queue. |
| `--output-dir PATH` | `$MUSICSTUDIO_OUTPUT_DIR`, else `~/.MusicStudio/output` | Where rendered audio goes. Only `generate` and `worker` use it. |

Exit status is 0 on success and non-zero on failure (1 for most errors; `songbench` returns 2 when its inputs don't match a generation).

## Environment variables

| Variable | Default | Used for |
|---|---|---|
| `MUSICSTUDIO_HOME` | `~/.MusicStudio` | Root for the defaults below, the AI Search index and `backups/`. |
| `MUSICSTUDIO_DB` | `$MUSICSTUDIO_HOME/studio.db` | Default for `--db`. |
| `MUSICSTUDIO_OUTPUT_DIR` | `$MUSICSTUDIO_HOME/output` | Default for `--output-dir`. |
| `MUSICSTUDIO_MODELS_DIR` | `$MUSICSTUDIO_HOME/models` | Model weights and SongBench checkpoints. Set this if you moved the models folder in Settings. |
| `MUSICSTUDIO_ENGINES_DIR` | `$MUSICSTUDIO_HOME/engines` | Location searched for a standalone YuE2 `generate.py`, used only when the `lyra` package is unavailable. |
| `MUSICSTUDIO_SONGBENCH_VENV` | `$MUSICSTUDIO_HOME/venvs/songbench-reference` | SongBench CPU runtime. |
| `SONGBENCH_MUQ_DIR` | `OpenMuQ/MuQ-large-msd-iter` | MuQ checkpoint path or Hub repo for SongBench. |
| `SONGWRITER_API_URL` | `http://127.0.0.1:8000` | Songwriter server for generation reports (worker). |
| `SONGWRITER_API_TOKEN` | `musicstudio` | Bearer token for those reports. |

The app sets `MUSICSTUDIO_HOME`, `MUSICSTUDIO_DB`, `MUSICSTUDIO_OUTPUT_DIR`, `MUSICSTUDIO_MODELS_DIR` and the Songwriter variables from your Settings when it launches the worker. When you run the script by hand, set them yourself if you changed any folder in Settings > Storage.

## Output format

Commands produce one of three kinds of stdout:

- Event stream (JSON Lines): long-running commands (`generate`, `worker`, `songbench`, and parts of `effect`, `master`, `loudness`) print one JSON object per line as they work.
- A JSON result: utility commands print a single JSON object or array when they finish.
- Plain text: `init`, `models`, `stats`, `schema`, `render` and `loudness` print human-readable tables or lines.

Errors from text commands go to stderr.

### Events

Every event has the same envelope:

```json
{"event": "log", "component": "loudness", "level": "info", "message": "Measured -18.42 LUFS (gain +4.42dB -> -14)", "detail": "lufs=-18.42 target=-14.0 gain_db=4.42"}
```

- `event`: the event type (below).
- `component`: the subsystem, such as `app`, `worker`, `queue`, `model`, `tokenizer`, `cot`, `ar`, `nar`, `vae`, `loudness`, `convert`, `analysis`, `db`, `tag`, `eval`, `effect`, `mastering`.
- `level`: `debug`, `info`, `warn` or `error`.
- Any other keys are event-specific.

| Event | Emitted when | Notable fields |
|---|---|---|
| `start` | A generation, effect or master begins | generate: `model`, `caption`, `duration`, `steps`, `seed`, `target_format`, `family`, `index`, `total` |
| `progress` | YuE2 pipeline stage updates | `stage` (`plan`, `semantic`, `nar`, `vae`), `step` and `total_steps` during `nar`, `message` |
| `log` | General progress and diagnostics | `message`, optional `detail` |
| `error` | A step failed | `message`, sometimes `job_id` |
| `complete` | A song is written and recorded | `output_file`, `format`, `size_mb`, `elapsed_sec`, `seed`, `sidecar_file`, `item` (full generation record) |
| `queue_idle` | The worker found no queued job | `processed` |
| `eval_install_start`, `eval_install_progress` | SongBench is installing | `generation_id`, `stage`, `fraction` |
| `eval_start`, `eval_complete`, `eval_failed` | SongBench scoring | `generation_id`; `evaluation` on complete; `error` on failure |
| `effect_done` | `effect` finished rendering | `input`, `output`, `plugin`, `params` |
| `mastered` | `master` finished | `input`, `output`, `lufs`, `peak_db`, `hf_repair`, `artifact_reduction`, `size_mb` |

MiniMax's own engine also emits JSON events; `studio.py` passes any child line that starts with `{"event"` through unchanged. Other child output is wrapped as `log` events at `debug` level.

A simple way to follow a run is to filter with `jq`:

```sh
"$PY" "$STUDIO" generate --caption "lofi hip hop, mellow keys" --duration 30 \
  | jq -r 'select(.level != "debug") | "\(.event)\t\(.message // .output_file // "")"'
```

## Commands

### init

```sh
studio.py init
```

Creates the database schema, seeds the model table from `catalog.json`, and applies pending migrations. Safe to run again. Prints `Database initialized at <path>`.

### models

```sh
studio.py models
```

Refreshes model availability from disk and prints a table of `STATUS` (`OK` or `MISS`, with a reason), `ID`, `FAMILY` and weights `PATH`. Use the IDs shown here with `--model`.

### stats

```sh
studio.py stats
```

Prints row counts: prompts, prompt segments, keywords, available/total models, generations and jobs.

### schema

```sh
studio.py schema [--status] [--migrate] [--backup]
```

| Option | Effect |
|---|---|
| `--status` | Shows the database path, current and target schema version (target is 10), and pending migrations. This is the default with no option. |
| `--migrate` | Applies pending migrations. A backup is taken first. |
| `--backup` | Copies the database to `backups/studio-v<version>-<YYYYMMDD_HHMMSS>.db` next to it without migrating. |

Backups live in a `backups/` folder beside the database; the five newest are kept.

### generate

Render one song directly, outside the queue.

```sh
studio.py generate [--model ID] [--caption TEXT | --style TEXT] [--lyrics TEXT]
                   [--duration SEC] [--steps N] [--guidance X | --cfg-scale X]
                   [--seed N] [--format wav|mp3|m4a|flac]
                   [--cot full|melody|off] [--abc-file PATH]
```

| Option | Default | Notes |
|---|---|---|
| `--model` | `minimax_music3:MiniMax-Music3-mxfp8` | A model ID from `models`. Partial matches on the weights path or name also work, as does a direct path to a weights folder. |
| `--caption` | | The prompt. MiniMax: structured prompt. YuE2: style tagline (structured prompts are reduced to a tagline automatically). |
| `--style` | | Used only when `--caption` is empty. If both are empty the prompt is `Indie pop acoustic`. |
| `--lyrics` | empty | Lyrics with section tags (lowercase for MiniMax, capitalized for YuE2). Empty means instrumental: `[instrumental]` for MiniMax, `[Instrumental]` for YuE2. |
| `--duration` | 60 | Seconds. |
| `--steps` | 30 for MiniMax, 32 for YuE2 | |
| `--guidance` | 1.7 for MiniMax, 1.0 for YuE2 | Takes priority over `--cfg-scale`. |
| `--cfg-scale` | | Alias used when `--guidance` is not given. |
| `--seed` | random below 1,000,000,000 | Fix this to reproduce a result. |
| `--format` | `mp3` | Delivered format. |
| `--cot` | `full` | YuE2 planning mode. Ignored by MiniMax. |
| `--abc-file` | | YuE2 only: an ABC score to plan around (use with `--cot full` or `melody`). Ignored if the file doesn't exist. |

What happens:

1. MiniMax prompts are checked against the 4,500-token budget and trailing lyric lines are trimmed if needed.
2. The model renders a WAV named `song_<YYYYMMDD_HHMMSS>.wav` in the output folder (`_02`, `_03`… on collisions). YuE2 also writes `<name>.abc` when it plans a score.
3. The WAV is normalised to −14 LUFS / −1 dBTP and the original kept as `<name>_raw.wav`.
4. The track is analysed (tempo, key, spectral and loudness metrics).
5. For non-WAV formats it is converted and the WAV removed.
6. Tags are written and the generation is added to the database, so it appears in the app's history.

`generate` does not run SongBench and does not report to Songwriter; the queue worker does both.

### worker

```sh
studio.py worker
```

Processes the database job queue, which is what the app runs when you click Queue. On start it applies migrations, retries failed Songwriter reports, marks interrupted SongBench runs as failed, and returns jobs stuck in `running` to the queue. It then takes `queued` jobs in order, runs `generate` for each, runs SongBench on the result, and reports linked songs to Songwriter. It exits after the queue has been empty for about a second.

Jobs are added by the app. Avoid running a second worker while the app is processing the queue.

### songbench

```sh
studio.py songbench AUDIO_PATH --generation-id ID
```

Scores one recorded generation with SongBench. `AUDIO_PATH` must match the file stored for that generation ID, otherwise it exits with status 2. The first run installs the evaluator and its CPU runtime (see the [User Guide](USER_GUIDE.md#12-songbench-evaluation)). Results are saved to the database and written into the file as `SB_*` tags; the `eval_complete` event carries the scores.

SongBench is licensed by Tencent for academic use only. Do not use this command for commercial or production purposes. See [NOTICE.md](../NOTICE.md).

### convert

```sh
studio.py convert INPUT {wav,mp3,m4a,flac} [--output PATH] [--tags-from FILE]
```

Converts audio. MP3 is 320 kbps via `lameenc`; M4A (AAC) and FLAC use macOS `afconvert`. Without `--output`, the result is written next to the input with the new extension. Tags are copied from the input, or from `--tags-from` if given. Prints JSON:

```json
{"status": "ok", "format": "mp3", "path": "/…/song.mp3", "size_bytes": 2304512, "elapsed_sec": 0.41}
```

On failure it prints `{"error": "..."}` and exits 1.

### tags

```sh
studio.py tags INPUT [--write JSON]
```

Without `--write`, prints the file's tags as JSON plus `path` and `mtime`. With `--write`, writes the JSON metadata into the file and prints `{"status": "ok", "path": ...}`. Supported keys include `title`, `artist`, `album`, `album_artist`, `genre`, `composer`, `comment`, `lyrics`, `bpm`, `key`, `scale`, and the groups `gen`, `target`, `dsp`, `norm` and `sb` (written as `GEN_*`, `TARGET_*`, `DSP_*`, `NORM_*`, `SB_*` custom tags).

### spectrogram

```sh
studio.py spectrogram INPUT [--output PNG] [--force]
```

Renders a mel spectrogram PNG, by default to `.<stem>.spectrogram.png` beside the audio. If the PNG is newer than the audio it is reused unless `--force` is given. Prints `{"status": "ok"|"cached", "path": ...}`.

### reconcile

```sh
studio.py reconcile
```

For each generation whose file changed since it was last analysed, re-reads the file's tags into the database (file tags win). Use it after editing tags in another program. Prints `{"status": "ok", "scanned": N, "updated": N, "missing": N}`.

### effect

```sh
studio.py effect INPUT --plugin PATH [--plugin-name NAME]
                 [--param NAME=VALUE ...] [--raw NAME=0..1 ...]
                 [--list-params] [--output PATH]
```

Runs audio through a VST3 (`.vst3`) or Audio Unit (`.component`) effect using pedalboard.

| Option | Notes |
|---|---|
| `--plugin` | Path to the plugin bundle. Required. |
| `--plugin-name` | Pick one plugin from a bundle that contains several. On load errors, the JSON lists `available_plugins`. |
| `--param NAME=VALUE` | Set a parameter in its own units (`150%`, `Off`, `true`). Repeatable. |
| `--raw NAME=VALUE` | Set a parameter by its normalised 0 to 1 position. Repeatable. |
| `--list-params` | Print the plugin's name, manufacturer, effect/instrument flags and every parameter (value, range, type, options, raw position, step labels) as JSON, then exit. |
| `--output` | Output file. Default `<stem>_fx.<ext>` beside the input. |

Instrument plugins are rejected. If the processed audio clips, it is scaled down to avoid clipping. Prints `{"status": "ok", "plugin", "input", "output", "applied_params", "size_bytes"}`.

### search

```sh
studio.py search QUERY [--limit N]
```

Semantic search over the style library using the `mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ` embedding model (downloaded from the Hub on first use) and the precomputed index. `--limit` defaults to 50. Prints a JSON array ranked by similarity:

```json
[{"id": "dark-synthwave-night-drive", "db_id": 412, "title": "Dark Synthwave Night Drive", "genre": "Electronic", "subgenre": "Synthwave", "bpm": 98, "key": "A", "scale": "minor", "vocal": "instrumental", "score": 0.6123}]
```

`id` is the preset slug, usable with `render --prompt-slug` and `tokens --prompt-slug`. If the index files are missing it prints `[]` and exits 1.

### tokens

```sh
studio.py tokens [--prompt-slug SLUG] [--caption TEXT] [--lyrics TEXT]
```

Counts MiniMax prompt tokens. With `--prompt-slug`, the preset's MiniMax prompt replaces `--caption`. Prints:

```json
{"tokens": 4820, "method": "exact", "budget": 4500, "limit": 5000, "remaining": 0, "will_trim": true,
 "caption_chars": 2110, "lyrics_chars": 9120, "trimmed_tokens": 4488, "dropped_lines": 14, "trimmed_lyrics": "..."}
```

`method` is `exact` when the MiniMax tokenizer is available and `estimate` otherwise. The `trimmed_*` and `dropped_lines` fields appear only when `will_trim` is true and show what `generate` would send.

### master

```sh
studio.py master INPUT [--output PATH] [--hf-repair] [--artifact-reduction]
                 [--eq-low DB] [--eq-mid DB] [--eq-high DB] [--target-lufs LUFS]
```

Applies a mastering chain and re-normalises. The input is never overwritten.

| Option | Default | Effect |
|---|---|---|
| `--hf-repair` | off | +1.5 dB air lift above 10 kHz. |
| `--artifact-reduction` | off | Bounded spectral artifact reduction. |
| `--eq-low` | 0.0 | Low shelf gain in dB, below 250 Hz. |
| `--eq-mid` | 0.0 | Mid peak gain in dB, 500 Hz to 4 kHz. |
| `--eq-high` | 0.0 | High shelf gain in dB, above 6 kHz. |
| `--target-lufs` | −14.0 | Final integrated loudness. |

MP3, M4A and FLAC inputs are decoded to WAV first and the result is encoded back to the same format, so the output is `<stem>_mastered.<ext>` beside the input. Tags are copied over with the new loudness and peak values. In v0.1.0 the output path is always `<stem>_mastered.<ext>`; `--output` is accepted but not used. Emits `start` and `mastered` events, then prints the chain's result as indented JSON including `output`, `lufs`, `peak_db` and `size_mb`.

### loudness

```sh
studio.py loudness INPUT.wav [--target-lufs LUFS] [--target-peak DBTP]
```

Measures integrated loudness (ITU-R BS.1770) and normalises the WAV in place to `--target-lufs` (default −14.0) with a peak ceiling of `--target-peak` (default −1.0 dBTP), applying a soft limiter if needed. The original is first copied to `<stem>_raw.wav` (only if that file doesn't already exist). The output is 16-bit PCM. Input must be WAV; convert other formats first. Prints the original LUFS and peak, applied gain, target, output peak and the raw backup name.

### render

```sh
studio.py render --prompt-slug SLUG [--model ID]
```

Prints a preset's prompt as the given model would receive it (default model `minimax_music3:MiniMax-Music3-mxfp8`), followed by its length in characters and words. Exits 1 if the slug isn't found.

### estimate

```sh
studio.py estimate [--model ID] [--duration SEC] [--steps N] [--cot full|melody|off]
```

Prints the formula-based time estimate in seconds, broken down by phase. Defaults: MiniMax mxfp8, 60 s, 30 steps for MiniMax or 32 for YuE2, CoT `full`. This is the uncalibrated formula; the app additionally calibrates against your past render times.

MiniMax fields: `total`, `load`, `ar`, `flow`, `vae`, `post`, `chunks`, `frames`, `steps`, `model`.
YuE2 fields: `total`, `load`, `cot`, `semantic`, `nar`, `vae`, `post`, `steps`, `tokens`, `model` (the calibration profile used, for example `yue2:8bit`).

The quantization is read from the model ID (`4bit`, `8bit`, `mxfp8`, otherwise `bf16`); unknown combinations fall back to the MiniMax mxfp8 profile.

## Worked examples

All examples assume:

```sh
PY=~/.MusicStudio/venv/bin/python
STUDIO=/Applications/MusicStudio.app/Contents/Resources/studio.py
```

### Generate a song

A 90-second YuE2 track with a fixed seed, saved as FLAC, printing only the final file path:

```sh
"$PY" "$STUDIO" generate \
  --model yue2:YuE2-3B-8bit \
  --caption "indie folk, acoustic guitar, warm female vocal, 92 bpm" \
  --lyrics $'[Verse]\nMorning light on the window\nCoffee cooling in my hand\n\n[Chorus]\nStay a little longer\nStay' \
  --duration 90 --cot full --seed 424242 --format flac \
  | jq -r 'select(.event == "complete") | .output_file'
```

Run it again with the same arguments to get the same song. The planned score is saved beside it as `.abc`; pass it back with `--abc-file` after editing to change the melody.

A MiniMax instrumental needs no lyrics:

```sh
"$PY" "$STUDIO" generate --caption "cinematic orchestral, slow build, strings and brass" --duration 120 --format wav
```

### Convert a folder to MP3

```sh
for f in ~/.MusicStudio/output/*.flac; do
  "$PY" "$STUDIO" convert "$f" mp3 | jq -r '.path // .error'
done
```

Tags are carried over to each MP3.

### Check and fix loudness

```sh
"$PY" "$STUDIO" loudness ~/Desktop/mixdown.wav --target-lufs -16 --target-peak -1.5
```

`mixdown.wav` is normalised in place and the original is kept as `mixdown_raw.wav`.

### Master a track

```sh
"$PY" "$STUDIO" master ~/.MusicStudio/output/song_20261006_101500.mp3 \
  --hf-repair --eq-low 1.5 --eq-high -1 --target-lufs -14 \
  | jq -r 'select(.event == "mastered") | "\(.output)  \(.lufs) LUFS  \(.peak_db) dB peak"'
```

This writes `song_20261006_101500_mastered.mp3` beside the original.

### Find a style with semantic search and render it

```sh
slug=$("$PY" "$STUDIO" search "melancholic piano ballad with strings" --limit 5 | jq -r '.[0].id')
"$PY" "$STUDIO" render --prompt-slug "$slug" --model yue2:YuE2-3B-8bit
"$PY" "$STUDIO" tokens --prompt-slug "$slug" --lyrics "$(cat lyrics.txt)" | jq '{tokens, will_trim}'
```

### Estimate render time before queueing

```sh
for d in 60 180 360; do
  printf '%s s: ' "$d"
  "$PY" "$STUDIO" estimate --model yue2:YuE2-3B-bf16 --duration "$d" --steps 48 --cot melody | jq -r '.total'
done
```
