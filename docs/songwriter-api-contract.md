# MusicStudio–Songwriter API Contract

Contract-Version: 6
Updated-At: 2026-11-12T07:15:00Z
Status: Confirmed & Implemented
Updated-By: Songwriter & MusicStudio Collaboration

## Scope

Songwriter supplies song content. MusicStudio imports that content, generates locally using user-selected settings, evaluates locally with SongBench, and reports generation metadata and scores.

MusicStudio does **not** upload audio. No upload ticket, binary transfer, remote storage, or remote playback API is required.

## Ownership

- Songwriter owns title, summary, creative direction, lyrics, instrumental state, musical metadata, model-ready prompts, and optional YuE2 ABC notation.
- MusicStudio owns model selection, output format, duration, steps, guidance/CFG, seed, batch count, CoT mode, local generation, local audio files, and SongBench evaluation.
- Songwriter does not need to know the model or output format before MusicStudio generates the song.
- MusicStudio retains the selected Songwriter song ID and revision through queueing and result reporting.

## Required API surface

```text
GET  /v1/songs
GET  /v1/songs/{song_id}
POST /v1/songs/{song_id}/generations
```

Base URL:

```text
http://127.0.0.1:8000
```

Authentication:

```http
Authorization: Bearer <token>
```

In local development, any non-empty token is accepted when `SONGWRITER_API_KEY` is unset.

## 1. List available songs

```http
GET /v1/songs?status=all&limit=50&cursor=<optional>
Authorization: Bearer <token>
Accept: application/json
```

Returns one row per song (the current take of each). A **song** is a creative work; a
**take** is one generated version of it. Takes of the same song are distinct records that
share a `take_group`:

- `song_id` (or `id`) — unique identifier for this take record.
- `take_group` — stable id shared by every take of one song (the first take's id).
- `take_number` — 1..N, this take's position within its group.
- `take_count` — number of takes in the group.
- `brief` (or `summary`) — story/brief synopsis.
- `moods` — list of dominant mood keywords (e.g. `["dark", "somber", "hypnotic"]`).
- `instruments` — list of key instrumentation descriptors.
- A standalone song is a group of one: `take_group == song_id`, `take_number == 1`, `take_count == 1`.
- `take_id` (`"<song_id>:<revision>"`) stays a stable per-row identity for client list selection.

MusicStudio groups rows by `take_group`, labels them `"<title> (Take <take_number> of
<take_count>)"` (omitting the suffix when `take_count == 1`), and offers "Queue all N takes" (one group)
and "Queue all N" (the entire list).

Response:

```json
{
  "songs": [
    {
      "song_id": "song_test_01",
      "revision": 1,
      "take_id": "song_test_01:1",
      "take_group": "song_test_01",
      "take_number": 1,
      "take_count": 3,
      "title": "Neon Horizon",
      "brief": "Story about cybernetic neon nights",
      "genre": "Synth-pop",
      "subgenre": "Darkwave",
      "moods": ["nocturnal", "melancholic"],
      "instruments": ["analog synthesizer", "drum machine"],
      "language": "English",
      "instrumental": false,
      "duration_hint_sec": 180,
      "bpm": 120,
      "key": "F#",
      "scale": "minor",
      "time_signature": "4/4",
      "has_abc": true,
      "updated_at": "2026-11-12T05:00:00Z"
    }
  ],
  "next_cursor": null
}
```

MusicStudio presents these songs in a searchable popover. Selecting a row fetches its details but does not start generation.

## 2. Get selected song details

```http
GET /v1/songs/{song_id}
Authorization: Bearer <token>
Accept: application/json
```

Response (v6 flat format, with legacy creative / model_inputs fallback):

```json
{
  "song_id": "song_test_01",
  "revision": 1,
  "title": "Neon Horizon",
  "brief": "Story about cybernetic neon nights",
  "status": "finalized",
  "lyrics": "[verse 1]\nNeon flickering in the rain\n\n[chorus]\nWe are burning through the pain",
  "abc_score": "X:1\nT:Neon Horizon\nM:4/4\nL:1/16\nQ:1/4=120\n...",
  "engine_prompts": {
    "minimax": "Global Metadata\nBasic Attributes: bpm is 120. key is F#, and scale is minor. Synth-pop (Darkwave).\nGlobal Emotional Progression: ...\n\nVocal Details: ...\n\nArrangement: ...",
    "yue2": "English, 120 BPM, Synth-pop, Darkwave, intimate female lead vocals, F# minor",
    "songbench": "Synth-pop / Darkwave, Analog Synthesizer, Drum Machine, Nocturnal, Melancholic, Intimate Female Lead, 120 BPM"
  },
  "genre": "Synth-pop",
  "subgenre": "Darkwave",
  "moods": ["nocturnal", "melancholic"],
  "instruments": ["analog synthesizer", "drum machine"],
  "vocal": "intimate female lead",
  "instrumental": false,
  "language": "English",
  "bpm": 120,
  "key": "F#",
  "scale": "minor",
  "time_signature": "4/4",
  "duration_hint_sec": 180,
  "created_at": "2026-11-12T05:00:00Z",
  "updated_at": "2026-11-12T05:00:00Z"
}
```

MusicStudio selection behavior:

- Store `song_id` and `revision` with the queued generation.
- Keep MusicStudio's current model, output format, steps, guidance, seed, batch, and CoT settings.
- For MiniMax, populate caption and lyrics from `engine_prompts.minimax` (falling back to `model_inputs.minimax.caption` or `creative.caption`).
- For YuE2, populate style and lyrics from `engine_prompts.yue2` (falling back to `model_inputs.yue2.style` or `creative.caption`).
- For YuE2, populate the ABC editor from `abc_score` (falling back to `model_inputs.yue2.abc_score`).
- Set Instrumental from `instrumental` (falling back to `creative.instrumental`).
- Apply `duration_hint_sec` only as an imported suggestion; the user may change it.
- Allow the user to edit imported fields before queueing.

## 3. Report generation completion and SongBench scores

After local generation and evaluation finish:

```http
POST /v1/songs/{song_id}/generations
Authorization: Bearer <token>
Content-Type: application/json
Idempotency-Key: <MusicStudio-generation-UUID>
```

Request:

```json
{
  "source": {
    "song_id": "song_test_01",
    "song_revision": 1
  },
  "client": {
    "generation_id": "101",
    "generation_uuid": "0199-uuid-generation-001",
    "app_version": "2.0"
  },
  "status": "completed",
  "completed_at": "2026-09-23T12:05:00Z",
  "generation": {
    "model_id": "minimax_music3:MiniMax-Music3-mxfp8",
    "model_family": "minimax_music3",
    "seed": 483729104,
    "duration_requested_sec": 180.0,
    "duration_actual_sec": 180.05,
    "steps": 30,
    "guidance": 1.7,
    "cot_mode": null,
    "output_format": "mp3",
    "elapsed_sec": 45.2
  },
  "evaluation": {
    "status": "completed",
    "evaluator_version": "songbench-reference-cpu-v1",
    "device": "cpu",
    "elapsed_sec": 12.3,
    "scores": {
      "melody": 7.5,
      "arrangement": 7.2,
      "musicality": 7.8,
      "vocal": 6.9,
      "instrumental": 8.0,
      "mixing": 7.4,
      "structure": 7.6
    },
    "overall": 7.485714285714286
  }
}
```

No audio bytes, local paths, upload IDs, storage URLs, or checksums are sent.

Evaluation rules:

- Completed evaluation contains all seven SongBench scores.
- Scores are finite and within `[1.0, 10.0]`.
- `overall` is the arithmetic mean of all seven scores, including Vocal for instrumental tracks.
- Server validates the mean with tolerance, not strict floating-point equality.
- A completed generation may report `evaluation.status: "failed"` with a concise error and `retryable: true`; generation success remains intact.

Response:

```json
{
  "generation_id": "gen_9a8b7c6d5e4f",
  "song_id": "song_test_01",
  "song_revision": 1,
  "status": "completed",
  "evaluation_status": "completed",
  "overall_score": 7.485714285714286,
  "created_at": "2026-09-23T12:05:01Z"
}
```

Historical revisions must remain valid completion targets. If Songwriter changes revision 1 to revision 2 while MusicStudio is generating revision 1, the completion is linked to revision 1 rather than rejected.

## Minimal reliability requirements

- Song-list and song-detail failures do not block local MusicStudio generation.
- Completion POST uses a stable idempotency key so retry cannot create duplicate results.
- MusicStudio retains failed completion delivery locally for retry.
- Never send local filesystem paths, stack traces, credentials, or audio data.
- Maximum supported content: lyrics 20,000 characters; ABC 50,000 characters.

## Explicitly out of scope

- Audio uploads.
- Upload tickets or signed URLs.
- Remote audio storage and playback.
- HTTP range streaming.
- Evaluation-only update endpoint for the initial integration.
- Generic synchronization framework.
- Background polling.
- Complex client-side error taxonomy.

## Songwriter Developer Confirmation & Implementation Sign-Off

Confirmed and approved. All three endpoints and exact requested payloads are implemented, verified, and test-covered in Songwriter (`src/songwriter/web/musicstudio_v1.py`):

1. **`GET /v1/songs`**:
   - Implemented and verified.
   - Returns the exact list shape: `id`, `revision`, `title`, `summary`, `genre`, `subgenre`, `language`, `instrumental`, `duration_hint_sec`, `bpm`, `key`, `scale`, `time_signature`, `has_abc`, `updated_at`.
   - Supports popover keyset pagination via `cursor` / `next_cursor` and ETag caching (`304 Not Modified`).

2. **`GET /v1/songs/{song_id}`**:
   - Implemented and verified.
   - Returns full `creative` metadata and pre-formatted `model_inputs`:
     - `model_inputs.minimax`: Layout-conforming `caption` (`[Global Metadata]`, `[Vocal Details]`, `[Arrangement]`) and normalized `lyrics`.
     - `model_inputs.yue2`: Atomic `style` tags, normalized `lyrics`, and syntactically valid `abc_score` generated deterministically via `generate_abc_score` (dual-track vocal melody and chord accompaniment conforming to YuE2's CoT format).
   - Returns `ETag: "{song_id}:{revision}"` and honors `If-None-Match`.

3. **`POST /v1/songs/{song_id}/generations`**:
   - Implemented and verified with the exact metadata-only payload specified in Section 3.
   - **Requirement for `audio` and `upload_id` has been completely removed:** no audio binary, upload ticket, or local file path is required.
   - **Floating-point tolerance:** Server validates arithmetic mean with tolerance (`abs(overall - computed_mean) <= 0.05`), preventing IEEE-754 precision mismatches between Swift and Python.
   - **Historical revision support:** Generations completing for earlier valid revisions are accepted and bound to that revision snapshot, preventing compute loss if lyrics were edited during generation.
   - **Idempotency:** Protected by `Idempotency-Key` header with 24-hour DuckDB retention.

### Verification Proof
- **Automated Tests:** All 9 integration tests in `tests/test_musicstudio_v1.py` passing (`test_generation_report_metadata_only_contract_v3` verifies the exact Section 3 payload).
- **OpenAPI Docs:** Schema actively registered and served at `http://127.0.0.1:8000/openapi.json` and interactive UI at `http://127.0.0.1:8000/docs`.

```text
Contract-Version: 3 (Agreed & Confirmed)
Status: Confirmed & Implemented
Updated-By: Songwriter API Developer
Verified-At: 2026-09-23T12:30:00Z
```
