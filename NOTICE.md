# Third-party notices

MusicStudio's own source code is MIT-licensed (see [LICENSE](LICENSE)). The components below are bundled with or downloaded by MusicStudio and remain under their own licenses.

## Bundled in the repository and app

| Component | Path | License | Notes |
|---|---|---|---|
| **SongBench** evaluator (Tencent) | `Resources/songbench/` | License Terms of SongBench: **academic use only, no commercial or production use** | Full text: [`Resources/songbench/SONGBENCH_LICENSE.txt`](Resources/songbench/SONGBENCH_LICENSE.txt). MusicStudio's MIT License does **not** apply to this directory. |
| **MuQ** (Tencent AI Lab) | used by `Resources/songbench/` | MIT | [`Resources/songbench/MUQ_LICENSE.txt`](Resources/songbench/MUQ_LICENSE.txt). Model revision pinned in that file. |
| **uv** 0.12.9 (Astral) | `bin/uv` | MIT or Apache-2.0 | Unmodified binary. Used only to create the Python environment on first launch. https://github.com/astral-sh/uv |
| Style preset catalog and embeddings | `Resources/seed_studio.db`, `Resources/embeddings.npy`, `Resources/embedding_ids.npy` | MIT (part of MusicStudio) | Embeddings computed with Qwen3-Embedding-0.6B (Apache-2.0). |

### What the SongBench restriction means for you

- Generating, mastering, tagging and exporting music do not use SongBench.
- SongBench only runs when you click a track's evaluation pill or call `studio.py songbench`. It also needs a separate runtime (PyTorch, MuQ) installed into `~/.MusicStudio/venvs/songbench-reference`.
- If you use MusicStudio commercially, don't run SongBench evaluations. Alternatively, delete `Resources/songbench/` before building; the rest of the app is unaffected.

## Installed on first launch (Python engine)

Installed from PyPI by `uv` into `~/.MusicStudio/venv`, pinned in [`Resources/requirements.txt`](Resources/requirements.txt). Major packages:

| Package | License |
|---|---|
| mlx, mlx-lm | MIT |
| mlx-audio | MIT |
| transformers, huggingface-hub, safetensors, tokenizers | Apache-2.0 |
| numpy, scipy, scikit-learn, librosa, soundfile, matplotlib | BSD-style |
| pedalboard (Spotify) | GPL-3.0 |
| mutagen | GPL-2.0-or-later |
| lameenc | LGPL-3.0 (LAME) |

`pedalboard` and `mutagen` are GPL-licensed. MusicStudio does not bundle or link them. They are installed by the user into a separate Python environment and invoked as a separate process.

## Downloaded on demand (model weights)

Weights are fetched from Hugging Face when you click Download in the Model Manager. `catalog.json` records Apache-2.0 for all bundled catalog entries, but **the model card on Hugging Face is authoritative**. Review it before using generated audio commercially.

| Model | Hugging Face repo |
|---|---|
| MiniMax Music 3 (4bit, 6bit, mxfp8, 8bit, bf16) | `mlx-community/MiniMax-Music3-*` |
| YuE2-3B (8bit, bf16) | `vanch007/mlx-Yue2-3B`, VAE `m-a-p/YuE2-Vae` |
| Qwen3-Embedding-0.6B (AI Search) | `mlx-community/Qwen3-Embedding-0.6B-4bit-DWQ` |
| MuQ (SongBench only) | `OpenMuQ/MuQ-large-msd-iter` |
