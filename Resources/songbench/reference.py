"""Developer-only upstream PyTorch parity fixture generator.

Normal MusicStudio execution never imports this module. Use it only in an isolated
venv containing the pinned upstream SongBench requirements.
"""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path


def generate_reference(audio_path: Path, songbench_checkpoint: Path, output_dir: Path) -> None:
    import librosa
    import numpy as np
    import torch
    from torch import nn
    from muq import MuQ
    from safetensors.torch import load_file

    class Generator(nn.Module):
        def __init__(self) -> None:
            super().__init__()
            self.attn = nn.ModuleList([
                nn.MultiheadAttention(1_024, 8, dropout=0.2, batch_first=True)
                for _ in range(4)
            ])
            self.ffd = nn.Sequential(
                nn.Linear(1_024, 4_096),
                nn.ReLU(),
                nn.Linear(4_096, 1_024),
            )
            self.dropout = nn.Dropout(0.2)
            self.fc = nn.Linear(2_048, 7)

        def forward(self, features: torch.Tensor) -> torch.Tensor:
            features = self.ffd(features)
            attended = features
            for attention in self.attn:
                attended, _ = attention(attended, attended, attended)
            pooled = torch.cat([attended.mean(1), features.max(1).values], dim=1)
            return torch.tanh(self.fc(self.dropout(pooled))) * 4.5 + 5.5

    output_dir.mkdir(parents=True, exist_ok=True)
    waveform, _ = librosa.load(str(audio_path), sr=24_000, mono=True)
    audio = torch.tensor(waveform, dtype=torch.float32).unsqueeze(0)
    muq_source = os.environ.get("SONGBENCH_MUQ_DIR", "OpenMuQ/MuQ-large-msd-iter")
    muq = MuQ.from_pretrained(
        muq_source,
        revision=None if Path(muq_source).exists() else "0562a57814f6f8bbd9fdea0a25921a2fce1a841a",
    ).eval()
    muq.model.conformer.config._attn_implementation = "eager"
    reward = Generator().eval()
    reward.load_state_dict(load_file(str(songbench_checkpoint)), strict=False)

    captured: dict[str, torch.Tensor] = {}
    handles = [
        muq.model.conv.conv[0].register_forward_hook(lambda _m, _i, out: captured.__setitem__("subsampler_block_0", out.detach())),
        muq.model.conv.conv[1].register_forward_hook(lambda _m, _i, out: captured.__setitem__("subsampler_block_1", out.detach())),
        muq.model.conv.register_forward_hook(lambda _m, _i, out: captured.__setitem__("subsampler", out.detach())),
        reward.ffd.register_forward_hook(lambda _m, _i, out: captured.__setitem__("ffd", out.detach())),
    ]
    try:
        with torch.no_grad():
            mel = muq.model.normalize(muq.model.preprocessing(audio, ["melspec_2048"]))["melspec_2048"]
            hidden = muq.model.conv(mel)
            rotary = muq.model.conformer.embed_positions(hidden)
            for layer in muq.model.conformer.layers[:6]:
                hidden = layer(hidden, attention_mask=None, relative_position_embeddings=rotary)
                if isinstance(hidden, tuple):
                    hidden = hidden[0]
            scores = reward(hidden)
            attended = captured["ffd"]
            for attention in reward.attn:
                attended, _ = attention(attended, attended, attended)
            pooled = torch.cat([attended.mean(1), captured["ffd"].max(1).values], dim=1)
    finally:
        for handle in handles:
            handle.remove()

    arrays = {
        "mel": mel,
        "subsampler": captured["subsampler"],
        "subsampler_block_0": captured["subsampler_block_0"],
        "subsampler_block_1": captured["subsampler_block_1"],
        "hidden_state_6": hidden,
        "reward_pooled": pooled,
    }
    for name, value in arrays.items():
        np.save(output_dir / f"{name}.npy", value.cpu().float().numpy())
    names = ["Melody", "Arrangement", "Musicality", "Vocal", "Instrumental", "Mixing", "Structure"]
    (output_dir / "scores.json").write_text(
        json.dumps(dict(zip(names, scores[0].cpu().tolist(), strict=True)), indent=2),
        encoding="utf-8",
    )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("audio", type=Path)
    parser.add_argument("checkpoint", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    generate_reference(args.audio, args.checkpoint, args.output)


if __name__ == "__main__":
    main()
