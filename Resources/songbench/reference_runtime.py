"""Pinned upstream SongBench CPU runtime for the parity fallback."""

from __future__ import annotations

import argparse
import json
from pathlib import Path

SCORE_NAMES = (
    "Melody", "Arrangement", "Musicality", "Vocal",
    "Instrumental", "Mixing", "Structure",
)


def evaluate(audio_path: Path, artifact: Path) -> dict[str, float]:
    import librosa
    import torch
    from torch import nn
    from muq import MuQ
    from safetensors.torch import load_file

    class RewardModel(nn.Module):
        def __init__(self) -> None:
            super().__init__()
            self.attn = nn.ModuleList([
                nn.MultiheadAttention(1_024, 8, dropout=0.2, batch_first=True)
                for _ in range(4)
            ])
            self.ffd = nn.Sequential(
                nn.Linear(1_024, 4_096), nn.ReLU(), nn.Linear(4_096, 1_024)
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

    waveform, _ = librosa.load(str(audio_path), sr=24_000, mono=True)
    if waveform.size == 0:
        raise ValueError("Audio is empty")
    audio = torch.tensor(waveform, dtype=torch.float32).unsqueeze(0)
    muq = MuQ.from_pretrained(str(artifact)).eval()
    muq.model.conformer.config._attn_implementation = "eager"
    reward = RewardModel().eval()
    reward.load_state_dict(load_file(str(artifact / "songbench.safetensors")), strict=True)
    with torch.inference_mode():
        mel = muq.model.normalize(
            muq.model.preprocessing(audio, ["melspec_2048"])
        )["melspec_2048"]
        hidden = muq.model.conv(mel)
        rotary = muq.model.conformer.embed_positions(hidden)
        for layer in muq.model.conformer.layers[:6]:
            hidden = layer(hidden, attention_mask=None, relative_position_embeddings=rotary)
            if isinstance(hidden, tuple):
                hidden = hidden[0]
        scores = reward(hidden)[0].cpu().tolist()
    return dict(zip(SCORE_NAMES, (float(value) for value in scores), strict=True))


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("audio", type=Path)
    parser.add_argument("artifact", type=Path)
    args = parser.parse_args()
    print(json.dumps(evaluate(args.audio, args.artifact)))


if __name__ == "__main__":
    main()
