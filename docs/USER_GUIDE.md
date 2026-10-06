# MusicStudio User Guide

This guide covers every panel, setting and shortcut in MusicStudio v0.1.0, plus step-by-step recipes. For installation see the [README](../README.md); for building from source see [BUILDING.md](BUILDING.md); for errors see [TROUBLESHOOTING.md](TROUBLESHOOTING.md). To script the engine directly, see [CLI.md](CLI.md).

## Contents

1. [First launch](#1-first-launch)
2. [Choosing and downloading models](#2-choosing-and-downloading-models)
3. [Interface tour](#3-interface-tour)
4. [Style library](#4-style-library)
5. [Prompts per model family](#5-prompts-per-model-family)
6. [Lyrics, structure tags and instrumentals](#6-lyrics-structure-tags-and-instrumentals)
7. [CoT mode and ABC scores (YuE2)](#7-cot-mode-and-abc-scores-yue2)
8. [Generation parameters](#8-generation-parameters)
9. [The queue](#9-the-queue)
10. [Output files](#10-output-files)
11. [Studio tab](#11-studio-tab)
12. [SongBench evaluation](#12-songbench-evaluation)
13. [Songwriter integration](#13-songwriter-integration)
14. [Settings reference](#14-settings-reference)
15. [Keyboard shortcuts and menus](#15-keyboard-shortcuts-and-menus)
16. [How-to recipes](#16-how-to-recipes)
17. [Where everything lives](#17-where-everything-lives)

---

## 1. First launch

v0.1.0 builds are ad-hoc signed and not notarized, so Gatekeeper blocks the first open. Either right-click the app and choose Open, or clear the quarantine flag:

```sh
xattr -dr com.apple.quarantine /Applications/MusicStudio.app
```

On launch the app checks for two things: the Python interpreter at `~/.MusicStudio/venv/bin/python3` and the database at `~/.MusicStudio/studio.db`. If either is missing, the setup screen appears. Otherwise you go straight to the studio.

### Setup screen

The setup screen has four parts.

Hardware Profile & Memory Tier shows what MusicStudio detected:

- Total RAM (from `hw.memsize`).
- GPU Budget: the memory MusicStudio assumes the GPU can use, computed as `max(1, min(0.85 × RAM, RAM − 4))` GB.
- Perf Cores: number of performance cores.
- A recommended quantization for each model family, based on total RAM:

| Total RAM | MiniMax Music 3 | YuE2-3B |
|---|---|---|
| under 14 GB | not supported (shows "RAM below 16 GB minimum") | 4bit |
| 14 to 22 GB | 4bit | 4bit |
| 22 to 30 GB | 6bit | 8bit |
| 30 to 44 GB | mxfp8 | 8bit |
| 44 to 60 GB | mxfp8 | bf16 |
| 60 to 90 GB | 8bit | bf16 |
| 90 GB and up | bf16 | bf16 |

The YuE2 catalog currently ships 8bit and bf16 only, so on machines where 4bit is recommended pick the 8bit build and keep durations short.

Storage Configuration lets you choose:

- Rendered Audio Output Folder (default `~/.MusicStudio/output`).
- Model Cache Directory (default `~/.MusicStudio/models`).

Both can be changed later in Settings > Storage.

Model Selection & HuggingFace lets you pick a Primary Initial Model and paste an optional HuggingFace User Access Token. The token is only needed for gated downloads or higher rate limits.

### What setup installs

When you start setup, MusicStudio:

1. Creates `~/.MusicStudio`, `~/.MusicStudio/bin`, `~/.MusicStudio/engines/yue2`, and your chosen output and models folders.
2. Copies the bundled style catalog (`studio.db`) and the AI Search index (`embeddings.npy`, `embedding_ids.npy`) into `~/.MusicStudio`. Existing files are not overwritten.
3. Finds `uv`: first the copy bundled inside the app, then `~/.MusicStudio/bin/uv`, then your `PATH`.
4. Creates a Python 3.12 virtual environment at `~/.MusicStudio/venv`.
5. Installs MLX, audio and model dependencies from the bundled `requirements.txt`.
6. Installs the YuE2 engine (the `lyra` package from mlx-Yue) from `engine-requirements.txt` with `--no-deps`, so it reuses the versions pinned in step 5.
7. Runs `studio.py init` to create the database schema and model table.

This takes 5 to 15 minutes depending on your connection. Model weights are not downloaded here; you do that in the Model Manager (next section). When the bar reaches 100%, click Continue to Studio.

If setup fails, the screen shows the reason (for example, `uv` not found or the Python 3.12 environment could not be created). See [TROUBLESHOOTING.md](TROUBLESHOOTING.md).

---

## 2. Choosing and downloading models

MusicStudio runs two model families locally on Apple Silicon through MLX.

| Model | Family | Quant | Download size | Min RAM | Sample rate |
|---|---|---|---|---|---|
| MiniMax-Music3-4bit | MiniMax Music 3 | 4bit | 9.21 GB | 16 GB | 44.1 kHz |
| MiniMax-Music3-6bit | MiniMax Music 3 | 6bit | 11.70 GB | 24 GB | 44.1 kHz |
| MiniMax-Music3-mxfp8 (recommended) | MiniMax Music 3 | mxfp8 | 13.87 GB | 32 GB | 44.1 kHz |
| MiniMax-Music3-8bit | MiniMax Music 3 | 8bit | 14.18 GB | 64 GB | 44.1 kHz |
| MiniMax-Music3-bf16 | MiniMax Music 3 | bf16 | 28.52 GB | 96 GB | 44.1 kHz |
| YuE2-3B-8bit (recommended) | YuE2-3B | 8bit | 5.58 GB | 24 GB | 48 kHz |
| YuE2-3B-bf16 | YuE2-3B | bf16 | 7.26 GB | 48 GB | 48 kHz |

MiniMax weights come from `mlx-community/MiniMax-Music3-*`. YuE2 weights come from `vanch007/mlx-Yue2-3B` and use the `m-a-p/YuE2-Vae` decoder. Both families support lyrics, instrumentals and up to 360 seconds of audio. Only YuE2 supports CoT planning and ABC scores.

How they differ in practice:

- MiniMax Music 3 takes a long, structured text prompt and lowercase section tags. It has a 4,500-token prompt budget.
- YuE2-3B takes a short comma-separated style tagline and capitalized section tags. It can plan a symbolic score (ABC notation) before rendering audio, and you can supply your own score.

### Model Manager

Open it from the model menu in the header (Manage Models in Settings…), from Help > Model Catalog & Downloads…, or from Settings > Models. The Standard Catalog tab lists each model with:

- Badges: RECOMMENDED, READY ON DISK or NOT DOWNLOADED, LAUNCH DEFAULT and ACTIVE.
- Min RAM.
- A Download button showing the size. While downloading, the row shows the current file and a file counter.
- A Folder button that opens the model's folder in Finder.
- A Show in Menu toggle that controls whether the model appears in the header's model menu.

The Hugging Face Hub tab searches the Hub (it starts with the query "mlx music") and shows downloads and likes for each result.

### HuggingFace token

Paste a token (`hf_...`) under Hugging Face User Token (Optional) and click Save; Clear removes it. It is stored in the app's preferences under the key `hfToken`. You only need it for gated repos or to avoid anonymous rate limits.

### Where weights live

Weights download to `<models folder>/<model path>`, by default under `~/.MusicStudio/models`. A model counts as installed when its folder has a `config.json` (and, for YuE2, the matching `ar-8bit.safetensors` or `ar-bf16.safetensors`). The engine also checks `~/Library/Application Support/YuE2Mac/Models` as a fallback location.

### Removing a model

There is no delete button in the app. To free space:

1. In the Model Manager, click the model's Folder button (or use File > Reveal Models Folder).
2. Quit MusicStudio.
3. Move the model's folder to the Trash in Finder.

On next launch the model shows NOT DOWNLOADED again.

---

## 3. Interface tour

The window has a header bar, the active tab (Create or Studio), and an optional console at the bottom that stays visible on both tabs.

### Header bar

From left to right:

| Item | What it does |
|---|---|
| Create / Studio | Switch tabs (⌘1 / ⌘2). A green dot on Studio means there are new tracks you haven't viewed. |
| Model menu | Pick the active model. Grouped by family; ★ marks recommended builds, (Ready) marks installed ones. Ends with Manage Models in Settings…. |
| Songwriter | Opens the Songwriter import popover. Shown only when Songwriter integration is enabled and "Show Songwriter Button in Header Bar" is on. Shows the imported song's title once linked. |
| ETA widget | Before you queue: `ETA ~…` for the current settings, plus "Queue done …" if work is pending. While generating: current stage, percent, time left, and when the next and last jobs will finish. When paused: "Queue paused" and the remaining queue time. Can be hidden in Settings > Layout. |
| Folder | Opens the output folder in Finder. |
| Gear | Opens Settings (⌘,). |
| Console | Toggles the console (⌘K). The badge shows how many log lines are buffered. |
| Queue (green) | Adds the current settings to the queue and starts processing (⌘↩). |
| Queue list (blue) | Opens the queue popover. The badge shows pending jobs. |

### Create tab

Left column: the Style & Preset Library, the prompt editor, and Generation Parameters.
Right column: the Lyrics editor, the ABC Symbolic Score editor (YuE2 with CoT Full or Melody only), and Generation History with the player bar.

### Studio tab

Left: Generation History with the player bar. Right: the Track Inspector (metadata, spectrogram, analysis, effect plugins). See [section 11](#11-studio-tab).

### Generation History and player bar

Each history row shows the file name, a model badge, an ABC badge if the track has a score sidecar, a SongBench pill, duration and steps, file size, the seed and the timestamp. Row actions:

- Play / pause.
- Click the seed to lock it in the Create tab and copy it to the clipboard.
- ABC badge: loads the generated score into the ABC editor.
- Reload (↺): restores model, caption, lyrics, duration, steps, guidance, format, seed (locked) and ABC score into the Create tab.
- Folder: reveals the file in Finder.
- Trash: deletes the track after confirmation. This removes the database row, the audio file and the `.abc` sidecar. The `_raw.wav` and spectrogram cache are left in place.

The player bar has play/pause, a seek slider, elapsed and total time, reveal-in-Finder for the playing track, and a button to open the output folder.

### Console

The console streams engine and app logs. Controls:

- Level filter: Trace, Debug, Info, Warn, Error.
- Component menu: Select All, Clear All, Pipeline Only (AR/NAR/Flow/VAE/CoT), Orchestration (Queue/Worker/App/Power), or individual components.
- Filter… text box.
- Copy and Clear buttons. View > Clear Console Logs also clears it.

Console height and whether it opens on launch are set in Settings > Layout.

---

## 4. Style library

The Style & Preset Library holds the bundled style presets plus any you create. The header shows "N of M presets" for the current filter.

### Search modes

The button at the right of the search field switches modes:

- AI Search (default): semantic search with the `Qwen3-Embedding-0.6B-4bit-DWQ` embedding model against a precomputed index. Type a description like "sad piano ballad" or "dark cyberpunk synth". Search runs as you type once the query has at least 3 characters, or when you press Return. Results take a moment because the embedding model runs locally.
- Text Match: exact multi-term keyword search over title, genre, subgenre, mood and instruments. Results update as you type.

The x button clears the query.

### Filters

The filter button (funnel icon) shows dropdowns:

| Filter | Options |
|---|---|
| Key | All, C through B |
| Scale | All, major, minor |
| Vocal | All, male, female, duet, choir, instrumental, unknown |
| Meter | All, 4/4, 3/4, 12/8, 6/8 |
| Register | All, tenor and other vocal registers, none |
| Lang | All, english, mandarin, cantonese, instrumental |

Reset All clears every filter.

### Keyword chips

Active keyword tags appear as chips above the table. Click a chip's x to remove one or Clear Tags to remove all. The table refilters as chips change.

### Presets table

Columns: TITLE, GENRE, BPM, KEY, VOCAL. Presets you created show a USER badge and can be deleted (with confirmation). Selecting a preset fills the prompt editor in the format the current model expects.

### New Preset and Save as Preset

New Preset (in the library header) and Save as Preset (above the prompt editor) open the New Style Preset sheet. Fields:

- PRESET TITLE (required), GENRE, SUBGENRE, BPM, KEY, SCALE, VOCAL, TIME SIG, LANGUAGE.
- INSTRUMENTS, MOODS and TAGS (comma-separated).
- PRODUCTION TIP / NOTES.
- STYLE PROMPT / CAPTION, with Copy from Studio Caption to pull in what's in the prompt editor.

Click Save Preset to add it to the library.

### Convert from Caption

With a YuE2 model active, the prompt editor shows Convert from Caption. If a preset is selected, it builds a tagline from the preset's fields (language, genre, subgenre and so on). Otherwise it collapses whatever is in the editor (for example a multi-line MiniMax prompt) into a comma-separated tagline by keeping the values after each `Field:` and dropping section headers.

---

## 5. Prompts per model family

The editor title tells you which format is expected: MUSIC PROMPT (MiniMax) or STYLE TAGLINE (YuE2). The editor shows a character count and has a Clear button.

MiniMax Music 3 uses a structured, multi-line prompt. Bundled presets render into sections such as Global Metadata, Vocal Details and Arrangement, with `Field: value` lines. Longer, specific prompts work well, within the token budget (section 6).

YuE2-3B uses a short tagline of comma-separated descriptors, for example genre, mood, instruments, vocal type and tempo. If you pass a structured prompt anyway, the engine extracts the short values from `Field: value` lines before sending it to YuE2.

Switching models re-renders the prompt automatically: to a tagline when you switch to YuE2, and back to the preset's structured prompt when you switch to MiniMax (if a preset is selected). Hand-typed text is left alone when switching to MiniMax, since a tagline is still valid MiniMax input.

---

## 6. Lyrics, structure tags and instrumentals

### Structure tags

The Lyrics editor has buttons that insert section tags. The case depends on the model:

| YuE2 (capitalized) | MiniMax (lowercase) |
|---|---|
| `[Intro]` | `[intro]` |
| `[Verse]` | `[verse]` |
| `[Pre-Chorus]` | `[pre-chorus]` |
| `[Chorus]` | `[chorus]` |
| `[Post-Chorus]` | `[post-chorus]` |
| `[Bridge]` | `[bridge]` |
| `[Instrumental]` | `[instrumental]` |
| `[Solo]` | `[solo]` |
| `[Outro]` | `[outro]` |

Put each tag on its own line, followed by that section's lines. The footer shows line and character counts.

### Instrumental

The Instrumental toggle in Generation Parameters collapses the Lyrics editor and shows "Instrumental — lyrics disabled". It also adjusts the input:

- MiniMax: lyrics become `[instrumental]`.
- YuE2: `, instrumental, no vocals` is appended to the tagline. If lyrics are empty, the engine sends `[Instrumental]` as the lyrics.

Turning it off clears `[instrumental]` from the lyrics. Clicking a tag button while instrumental is on also turns it off.

### Token budget and auto-trim (MiniMax)

MiniMax prompts are measured in tokens (prompt plus lyrics). The hard ceiling is 5,000 tokens; MusicStudio works to a 4,500-token budget. The Lyrics footer shows `Total: ~N / 4500 tokens (est)` and turns into a warning when you go over.

If you queue a prompt over budget, the engine removes lyric lines from the end, together with any trailing blank lines and section tags, until it fits. The console logs "Prompt exceeded budget (X tokens > 4500). Auto-trimmed N lyric line(s) to Y tokens." The exact tokenizer is used when available; otherwise it estimates about 3.5 characters per token plus 24 tokens of overhead. YuE2 has no such budget.

---

## 7. CoT mode and ABC scores (YuE2)

YuE2 can plan a song as sheet music before it renders audio. This plan is called chain-of-thought (CoT), and the score is written in ABC notation, a plain-text music format.

### The three modes

| Mode | What it does | Time cost |
|---|---|---|
| Full (Chords + Melody) | Writes a complete ABC score with melody and chord progression, then renders audio that follows it. | Highest. Adds the full planning phase. |
| Melody Only | Writes the main melodic line without chord annotations, then renders. | About half the planning time of Full. |
| Off (Direct Codec) | Skips planning and generates audio codec frames directly. | Lowest. No planning phase, no score. |

The planning phase is a small part of the total next to audio generation and decoding; run `studio.py estimate` (see [CLI.md](CLI.md)) to see the breakdown for your settings. Full gives the most structured, repeatable harmony. Off is fastest and leaves the most to the model.

CoT Mode appears under CFG Scale only when a YuE2 model is active. Selecting a YuE2 model resets CoT to Full, along with steps 32 and CFG 1.0. Reloading a track from history also selects its model, so CoT ends up at Full there too; set it again if the original used Melody or Off.

### When the ABC editor appears

The ABC Symbolic Score editor is shown only when YuE2 is selected and CoT is Full or Melody. With CoT Off, or with MiniMax, the editor is hidden and any score in it is not sent.

### Using your own score

If the editor contains text when you click Queue, MusicStudio saves a copy of it for that job under `~/.MusicStudio/queue-abc/` and passes it to YuE2, which plans around your score instead of writing one. The copy is kept on disk so paused jobs still have it after a relaunch. If the editor is empty, YuE2 writes its own score.

Editor buttons:

- Import: open an `.abc` file.
- Export: save the editor contents as `.abc`.
- Copy: copy to the clipboard.
- Clear: empty the editor, so YuE2 writes its own score next time.

### Loading a generated score

When YuE2 writes a score, it is saved next to the audio as `<name>.abc` and the history row shows an ABC badge. Click the badge to load the score into the editor, or use Reload to bring back the whole setup. Editing a generated score and re-queueing it is the simplest way to change a melody while keeping the arrangement.

---

## 8. Generation parameters

| Parameter | Range | Default | What it affects |
|---|---|---|---|
| Duration | 10 to 360 s, step 5. Presets 30, 60, 90, 120, 180, 240 s | from Settings > Defaults (factory 180 s) | Target length. Longer songs take proportionally longer. |
| Steps (DiT Flow), MiniMax | 1 to 30. Presets 10, 20, 25, 30 | 30 | Flow-matching refinement steps. Fewer is faster with less detail. |
| Steps (NAR Midpoint), YuE2 | 8 to 64, step 4. Presets 16, 24, 32, 48, 64 | 32 | Non-autoregressive refinement steps on the audio tokens. More steps cost more time. |
| Guidance (DiT CFG), MiniMax | 1.0 to 3.0, step 0.05. Presets 1.2, 1.5, 1.7, 2.0, 2.5 | 1.7 | How strictly audio follows the prompt. Higher is more literal and can sound harsher. |
| CFG Scale, YuE2 | 1.0 to 3.0, step 0.05. Presets 1.0, 1.05, 1.2, 1.5, 2.0 | 1.0 | Same idea for YuE2. 1.0 is the model's native setting. |
| CoT Mode, YuE2 | Full, Melody Only, Off | Full | See [section 7](#7-cot-mode-and-abc-scores-yue2). |
| Seed | Random, or a locked integer | Random | Starting noise. The same seed and settings reproduce the same track. |
| Format | WAV, MP3, M4A, FLAC | from Settings (factory MP3) | Delivered file format. See [section 10](#10-output-files). |
| Batch | 1x to 8x | from Settings (factory 1) | How many jobs one Queue click creates. |
| Instrumental | on/off | from Settings (factory off) | See [section 6](#6-lyrics-structure-tags-and-instrumentals). |

Choosing a model applies that family's steps and guidance defaults (MiniMax 30 / 1.7, YuE2 32 / 1.0, plus CoT Full).

### Seed lock

Click the lock next to Seed:

- Unlocked: shows "Random". Each track gets a fresh random seed.
- Locked: generates a random seed (100,000 to 999,999,999) into the field, which you can edit. Track 1 of a batch uses that seed exactly. Tracks 2 and later use `(seed + i × 7919) mod 1,000,000,000`, so a locked batch is reproducible as a set.

---

## 9. The queue

Every generation goes through the queue, which is stored in the database so it survives a relaunch.

- Add: the green Queue button or ⌘↩ captures the current model, prompt, lyrics, parameters and ABC score into one job per batch count. If the queue was paused, adding resumes it.
- Batch: 2x to 8x creates that many jobs from one click, grouped under one batch (the album tag uses the batch, see [section 10](#10-output-files)).
- Seed lock: see [section 8](#8-generation-parameters).
- Pause: Queue > Pause Queue or ⌘⇧P stops the running job and puts it back at the front of the queue. On resume it starts that song again from the beginning. The paused state is remembered across launches.
- Resume: Queue > Resume Queue or ⌘⇧P.
- Clear: Queue > Clear Queue, or the clear button in the queue popover, removes every pending job. This cannot be undone.

The queue popover (blue button) lists pending, running and failed jobs with status, model, title, duration and steps, a per-row ETA, and a progress bar for the running job. From there you can pause or resume, clear, remove individual jobs, and dismiss failed jobs. Removing the running job stops it; the rest continue.

If the worker process dies, the next worker start returns any job left in "running" to the queue.

### ETA calibration

The pre-click ETA starts from a formula per model and quantization: model load time, plus the autoregressive phase, plus steps cost, plus VAE decoding, plus CoT planning for YuE2. Once you have generated with a model, MusicStudio switches to your machine's measured speed: the median compute seconds per audio second across the last 20 generations with that model, clamped between 0.35× and 4× of the formula. ETAs get more accurate after a few songs. If a job runs past its estimate, the widget shows "Finishing…".

---

## 10. Output files

### Naming

Files go to the output folder (default `~/.MusicStudio/output`).

- Songs imported from Songwriter: `[Title]_[YYYYMMDD_HHMMSS].<ext>`. The title is cleaned by removing `/ \ : * ? " < > |` and control characters, collapsing spaces, and capping at 80 characters.
- Everything else: `song_[YYYYMMDD_HHMMSS].<ext>`.
- If a name already exists, `_02`, `_03` and so on are appended.

### Formats

| Format | Notes |
|---|---|
| WAV | 16-bit PCM, the file the engine renders and normalises. |
| MP3 | 320 kbps, encoded with `lameenc`. |
| M4A | AAC via macOS CoreAudio. |
| FLAC | Lossless. |

For non-WAV formats the WAV is converted and then removed.

### Loudness normalisation

Every render is normalised to −14 LUFS integrated loudness (ITU-R BS.1770) with a −1 dBTP peak ceiling. If the gain pushes peaks over −1 dBTP, a soft limiter is applied. The values are written into the file tags and shown in the inspector.

### Files per track

| File | When | Contents |
|---|---|---|
| `<name>.<ext>` | always | Normalised, tagged audio. |
| `<name>_raw.wav` | always (when normalisation runs) | The unprocessed render before normalisation. Keep it if you want to master yourself. |
| `<name>.abc` | YuE2 with CoT Full or Melody | The ABC score used or generated. |
| `.<name>.spectrogram.png` | after you inspect the track | Cached spectrogram (hidden file). |

### Metadata tags

Tags are written natively (ID3 for MP3, MP4 atoms for M4A, Vorbis comments for FLAC, RIFF for WAV):

- Standard: Title (preset title, or `MusicStudio YYYY-MM-DD`), Artist and Album Artist (`MusicStudio`), Album (`MusicStudio Batch <id>`, or `MusicStudio Generations YYYY-MM`), Genre, Composer (model id), Comment (prompt and production tip), Lyrics, BPM, Key, Duration.
- `GEN_*`: provenance, such as model, seed, steps, guidance and duration.
- `TARGET_*`: what the preset intended, such as BPM and key.
- `DSP_*`: measured analysis, such as Camelot key, onset rate and spectral centroid.
- `NORM_*`: loudness, such as LUFS, LRA, gain and pre/post peak.
- `SB_*`: SongBench scores, added after evaluation.

If the measured BPM is about double or half the preset's intended BPM, the intended value is used.

---

## 11. Studio tab

Select a track in the history list to load it into the Track Inspector.

### Inspector

The header shows format, size and duration. Below it:

- Spectrogram: a mel spectrogram rendered on first view and cached as `.<name>.spectrogram.png`.
- Metadata: standard tags.
- Generation: model, seed, steps, guidance, duration.
- Target (intended): the preset's BPM and key.
- Acoustic (DSP): measured analysis.
- Loudness / Dynamics: normalisation results.
- SongBench: scores, if evaluated.

If a track has no embedded tags yet, the inspector shows basic generation values and suggests running reconcile (`studio.py reconcile`, see [CLI.md](CLI.md)).

### What the analysis metrics mean

| Metric | Meaning |
|---|---|
| Tempo / BPM | Estimated beats per minute. |
| Beat count | Beats detected across the track. |
| Onset rate (Hz) | Note or hit onsets per second. A rough measure of rhythmic density. |
| Key / scale, Camelot | Estimated key from chroma, and its Camelot wheel code for harmonic mixing. |
| Spectral centroid (Hz) | The "center of mass" of the spectrum. Higher sounds brighter. |
| Spectral rolloff (Hz) | Frequency below which most of the energy sits. |
| Zero-crossing rate | How often the waveform crosses zero. Higher suggests noisier or more percussive content. |
| RMS energy | Average signal energy. |
| Mood descriptor | A coarse label combining energy (from RMS) and brightness (from the centroid). |
| Integrated LUFS | Overall loudness. About −14 after normalisation. |
| Gain (dB) | Gain applied during normalisation. |
| Pre / post peak (dB) | Highest sample peak before and after normalisation. Post peak is at most about −1 dBTP; if the gain would exceed that, a soft limiter is applied. |
| LRA (LU) | Loudness range: the spread between quiet and loud passages (95th minus 10th percentile). Higher means more dynamic contrast. |

### Effect plugins: AU realtime vs VST3 offline

The EFFECT PLUGIN (VST3 / AU) panel loads an effect onto the selected track. Click Load Plugin… and choose a `.component` (Audio Unit) or `.vst3` file.

- Audio Units run in real time. The plugin sits between the player and the output, so changes are heard instantly. Show Plugin Window opens the plugin's own editor.
- VST3 runs offline through Spotify's pedalboard, because the macOS audio engine can't host VST3 live. After you change a value, MusicStudio re-renders a preview shortly afterwards and plays it.

Parameters are listed with their real units when available. Some AUs only report raw 0 to 1 values; in that case those controls sit under Advanced (raw values) and you should use the plugin window. Instrument plugins are rejected ("is an instrument, not an effect"). The x button removes the plugin.

### Saving with effects

Save Audio… writes the track with the effect applied at the current settings. The save dialog offers a format choice and defaults to the original's format, its folder, and a name of `<original>_<PluginName>`. AU renders run offline through the audio engine; VST3 renders through pedalboard. Either way the original's tags are copied onto the new file. The original track is not changed.

### Mastering

The mastering chain (EQ, air lift, artifact reduction, re-normalisation) is not in the app UI in v0.1.0. Use `studio.py master` from the command line; see [CLI.md](CLI.md#master).

---

## 12. SongBench evaluation

SongBench is Tencent's music quality scorer. It rates a song from 0 to 10 on seven dimensions, Melody, Arrangement, Musicality, Vocal, Instrumental, Mixing and Structure, plus an Overall score.

SongBench is licensed by Tencent for academic use only. Do not use it for commercial or production purposes. Generating, mastering, tagging and exporting do not use SongBench. See [NOTICE.md](../NOTICE.md).

### Running it

Click the Eval pill on a history row. The pill shows Installing (with progress), Scoring, a star with the score when done, or Eval failed (hover for the reason, click to retry). Click a completed pill to see all seven scores. Only one evaluation runs at a time.

The queue worker also tries to score each finished track automatically. Scores are stored in the database, written into the file as `SB_*` tags, and shown in the inspector.

### Installation

The first evaluation installs everything automatically:

1. The SongBench and MuQ checkpoints, downloaded, checked and converted into the models folder.
2. A separate CPU runtime at `~/.MusicStudio/venvs/songbench-reference` with `torch 2.7.0`, `torchaudio 2.7.0`, `muq 0.1.0`, `librosa 0.11.0`, `hydra-core 1.3.2` and `safetensors 0.8.0`.

This is a large one-time download. Scoring runs on the CPU. Interrupted evaluations are marked failed and can be retried.

---

## 13. Songwriter integration

Songwriter is a separate song-writing service. MusicStudio can import finished songs from it and report results back. The API is described in [songwriter-api-contract.md](songwriter-api-contract.md).

### Setup

In Settings > API:

1. Turn on the Songwriter Integration toggle (on by default).
2. Set Server URL (default `http://127.0.0.1:8000`). Reset to Localhost restores it.
3. Set Bearer Token (default `musicstudio`). It is stored in the app's preferences.
4. Click Save Configuration. The status badge shows CONNECTED, ERROR, TESTING…, CONFIGURED or DISABLED.

"Show Songwriter Button in Header Bar" controls the header button.

### Importing a song

Click Songwriter in the header. The popover lists ready songs (search by title, summary or genre; refresh with the arrow). Clicking a song:

- Fills the prompt with the model-specific style (YuE2 `style`, MiniMax `caption`, falling back to the song's general caption).
- Fills lyrics, the instrumental flag and duration.
- Loads the song's YuE2 ABC score, if it has one.
- Links the song (title and revision) to the next jobs you queue.

Clear imported song (in the popover) or Clear Link (in Settings > API) unlinks it.

### File naming and reporting

Linked jobs are saved as `[Title]_[Timestamp]` (see [section 10](#10-output-files)). After each linked generation finishes and SongBench has run, MusicStudio posts the generation's settings (model, seed, duration, steps, guidance, CoT mode, format, elapsed time) and the SongBench result to `POST /v1/songs/{id}/generations`. No audio is uploaded. Each report has an idempotency key so retries don't create duplicates. Failed reports are retried when the worker next starts.

---

## 14. Settings reference

Open with ⌘, or the gear button. Settings has five sections. Values are stored in macOS user defaults for the app (bundle id `ai.opencode.mlx.musicstudio`); the preference key is listed in brackets.

### API

| Setting | Default | Notes |
|---|---|---|
| Songwriter Integration toggle [`songwriterAPIEnabled`] | on | Disables import and the header button when off. |
| Server URL [`songwriterAPIBaseURL`] | `http://127.0.0.1:8000` | Reset to Localhost restores it. |
| Bearer Token [`songwriterAPIToken`] | `musicstudio` | Stored locally. |
| Show Songwriter Button in Header Bar [`layoutShowSongwriterInHeader`] | on | |
| Linked Song / Clear Link | | Shows the currently imported song and revision. |

### Models

- Standard Catalog and Hugging Face Hub tabs (see [section 2](#2-choosing-and-downloading-models)), with your chip and memory shown, and Reveal Folder.
- TOP BAR MODEL MENU VISIBILITY [`displayedModelIds`]: which models appear in the header menu. Show All in Menu or Recommended Only.
- Hugging Face User Token [`hfToken`]: Save or Clear.

### Defaults

These apply to new sessions. Apply Defaults to Current Session copies them into the Create tab now; Reset Defaults to Factory restores the factory values.

| Setting | Factory default | Range or options |
|---|---|---|
| Startup Default Model [`defaultModelId`] | MiniMax-Music3-mxfp8 | any catalog model |
| Default Audio Format [`defaultOutputFormat`] | MP3 | WAV, MP3, M4A, FLAC |
| Instrumental Default [`defaultInstrumental`] | off | |
| Default Duration [`defaultDuration`] | 180 s | 10 to 360 s; presets up to 300 s |
| MiniMax Flow Steps [`defaultSteps`] | 30 | 1 to 30 |
| Guidance Scale (CFG) [`defaultGuidance`] | 1.7 | 1.0 to 4.0 here (the Create tab slider stops at 3.0) |
| YuE2 CoT Planning Mode [`defaultCotMode`] | Full | Full, Melody Only, Off |
| Default Batch Count [`defaultBatchCount`] | 1 | 1, 2 or 4 tracks |

Choosing a model in the header still applies that family's steps and guidance (section 8).

### Layout

| Setting | Default |
|---|---|
| Default Launch Tab [`defaultLaunchTab`] | Create |
| Show Live ETA Widget in Header Bar [`layoutShowEtaHeader`] | on |
| Open Console Automatically on Launch [`layoutShowConsoleOnLaunch`] | off |
| Console Panel Height [`layoutConsoleHeight`] | 180 pt (Compact 120, Expanded 240) |
| Style / Prompt Editor Height [`layoutPromptEditorHeight`] | 240 pt |
| Lyrics Editor Height [`layoutLyricsEditorHeight`] | 140 pt |
| ABC Score Editor Height (YuE2) [`layoutAbcEditorHeight`] | 60 pt |

Layout Presets set all three editor heights at once: Compact (180 / 100 / 45), Standard (240 / 140 / 60), Spacious (320 / 200 / 90). Reset Heights and Reset All Layout Preferences restore the defaults. You can also drag the editors to resize them.

### Storage

- FILE LOCATIONS: Audio Output Folder [`outputDirectory`] and Model Weights Folder [`modelsDirectory`], each with Choose…, a reveal button and Default.
- STUDIO DATABASE & ENGINE: Reveal Database in Finder; counts of Generations, Style Presets and Lyric Sets; database file size; the Python binary and database paths.
- HARDWARE SPECIFICATIONS: Unified Memory, GPU Budget, Performance Cores, MiniMax Tier and tier notes. Help > Hardware & System Profile… opens this section.
- Factory Reset Settings: Reset All Preferences… resets generation defaults, layout and endpoint settings. It does not delete audio files or the database.

The app also remembers the last model [`lastSelectedModel`], last tab [`selectedMainTab`] and whether the queue is paused [`queueProcessingPaused`].

---

## 15. Keyboard shortcuts and menus

| Menu | Item | Shortcut |
|---|---|---|
| MusicStudio | Settings… | ⌘, |
| File | Reveal Output Folder | ⌘⇧O |
| File | Reveal Models Folder | |
| View | Create | ⌘1 |
| View | Studio Library | ⌘2 |
| View | Show / Hide Console | ⌘K |
| View | Clear Console Logs | |
| Queue | Add to Queue | ⌘↩ |
| Queue | Pause Queue / Resume Queue | ⌘⇧P |
| Queue | Clear Queue | |
| Help | MusicStudio Help (opens the project README) | |
| Help | Model Catalog & Downloads… | |
| Help | Hardware & System Profile… | |

Pause/Resume and Clear Queue are disabled when nothing is pending.

---

## 16. How-to recipes

### Make an instrumental

1. Pick a preset or write a prompt.
2. Turn on Instrumental in Generation Parameters.
3. Click Queue (⌘↩).

With MiniMax the lyrics become `[instrumental]`. With YuE2 the tagline gets `instrumental, no vocals`. To add structure without vocals on YuE2, you can turn Instrumental off and write only tags such as `[Intro]`, `[Instrumental]`, `[Solo]`, `[Outro]`.

### Reproduce a track exactly with a locked seed

1. Find the track in Generation History and click Reload (↺). This restores the model, prompt, lyrics, duration, steps, guidance, format, ABC score and seed, with the seed locked.
2. For YuE2, set CoT Mode back to what the original used (reload sets it to Full).
3. Set Batch to 1x and queue.

The same model, prompt, lyrics, parameters and seed give the same result on the same model build. To only reuse the seed, click the seed number on the row.

### Write your own melody with ABC

1. Select a YuE2 model. Set CoT Mode to Full (chords and melody) or Melody Only.
2. Write or paste ABC notation in the ABC Symbolic Score editor, or click Import to load an `.abc` file. A minimal example:

   ```
   X:1
   M:4/4
   L:1/8
   K:C
   "C" E2 G2 c2 G2 | "F" A2 c2 "G" B2 G2 | "C" c8 |
   ```

3. Add lyrics with capitalized tags and a style tagline.
4. Queue. The score is saved with the job and the generated `.abc` sidecar keeps the plan used.

To iterate, click the ABC badge on the result, edit the score, and queue again.

### Batch variations

- Different takes of one idea: leave the seed on Random, set Batch to 4x or 8x, queue.
- Reproducible set: lock the seed, then batch. Track 1 uses your seed; the rest use derived seeds, so you can regenerate the same set later.
- Parameter sweep: lock the seed, queue once, change one parameter (for example guidance 1.5, then 2.0), queue again. Jobs run in order.

Each batch is tagged as its own album (`MusicStudio Batch <id>`), so music players group the takes together.

### Move output or models to an external drive

1. Quit any running generation, or pause the queue.
2. Copy `~/.MusicStudio/output` and/or `~/.MusicStudio/models` to the drive.
3. In Settings > Storage, click Choose… next to Audio Output Folder or Model Weights Folder and select the new location.
4. Relaunch MusicStudio so the engine picks up the new paths.
5. Check that models show READY ON DISK, then delete the old copies.

History entries store full file paths, so tracks created before the move point to the old location. Leave the old output folder in place if you need those to keep playing from history.

### Back up and restore your library

Everything is under `~/.MusicStudio` unless you moved the output or models folders:

- `studio.db`: presets, history, queue, SongBench scores.
- `output/`: audio, `_raw.wav`, `.abc` sidecars.
- `models/`: model weights (large; can be re-downloaded instead).
- `backups/`: automatic database backups (see below).

To back up, quit MusicStudio and copy `studio.db` and `output/` (or the whole `~/.MusicStudio`, excluding `venv/` and `models/` if you want to save space). To restore, quit the app and copy them back to the same paths. If you restore to different paths, set the folders in Settings > Storage.

Before every schema upgrade the engine saves `~/.MusicStudio/backups/studio-v<version>-<timestamp>.db` and keeps the five newest. You can make one on demand with `studio.py schema --backup` (see [CLI.md](CLI.md)).

---

## 17. Where everything lives

| Path | Contents |
|---|---|
| `~/.MusicStudio/venv/` | Python 3.12 environment for the engine |
| `~/.MusicStudio/studio.db` | Database |
| `~/.MusicStudio/embeddings.npy`, `embedding_ids.npy` | AI Search index |
| `~/.MusicStudio/output/` | Rendered audio (configurable) |
| `~/.MusicStudio/models/` | Model weights and SongBench checkpoints (configurable) |
| `~/.MusicStudio/engines/yue2/` | YuE2 engine staging |
| `~/.MusicStudio/queue-abc/` | ABC score snapshots for queued jobs |
| `~/.MusicStudio/backups/` | Database backups |
| `~/.MusicStudio/venvs/songbench-reference/` | SongBench CPU runtime |
| `~/.MusicStudio/bin/` | Optional local `uv` |

For problems, see [TROUBLESHOOTING.md](TROUBLESHOOTING.md). To report security issues, see [SECURITY.md](../SECURITY.md). Changes per version are in [CHANGELOG.md](../CHANGELOG.md).
