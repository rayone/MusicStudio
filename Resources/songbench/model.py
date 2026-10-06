"""Pure MLX MuQ prefix and SongBench reward head."""

from __future__ import annotations

from collections.abc import Mapping

import mlx.core as mx
import mlx.nn as nn

SCORE_NAMES = (
    "Melody",
    "Arrangement",
    "Musicality",
    "Vocal",
    "Instrumental",
    "Mixing",
    "Structure",
)


def _swish(value: mx.array) -> mx.array:
    return value * mx.sigmoid(value)


class Res2dModule(nn.Module):
    def __init__(self, input_channels: int, output_channels: int, stride: tuple[int, int]):
        super().__init__()
        self.conv1 = nn.Conv2d(input_channels, output_channels, 3, stride=stride, padding=1)
        self.conv2 = nn.Conv2d(output_channels, output_channels, 3, padding=1)
        self.residual = nn.Conv2d(input_channels, output_channels, 3, stride=stride, padding=1)

    def __call__(self, value: mx.array) -> mx.array:
        residual = self.residual(value)
        value = self.conv1(value)
        value = nn.relu(value)
        value = self.conv2(value)
        return nn.relu(value + residual)


class Conv2dSubsampling(nn.Module):
    def __init__(self):
        super().__init__()
        self.blocks = [
            Res2dModule(1, 512, (2, 2)),
            Res2dModule(512, 512, (2, 2)),
        ]
        self.linear = nn.Linear(16_384, 1_024)

    def __call__(self, mel: mx.array) -> mx.array:
        value = mx.transpose(mel, (0, 2, 3, 1))
        for block in self.blocks:
            value = block(value)
        batch, frequency, time, channels = value.shape
        value = mx.transpose(value, (0, 2, 3, 1)).reshape(batch, time, channels * frequency)
        return self.linear(value)


class FeedForward(nn.Module):
    def __init__(self):
        super().__init__()
        self.intermediate_dense = nn.Linear(1_024, 4_096)
        self.output_dense = nn.Linear(4_096, 1_024)

    def __call__(self, value: mx.array) -> mx.array:
        return self.output_dense(_swish(self.intermediate_dense(value)))


class RotarySelfAttention(nn.Module):
    def __init__(self):
        super().__init__()
        self.linear_q = nn.Linear(1_024, 1_024)
        self.linear_k = nn.Linear(1_024, 1_024)
        self.linear_v = nn.Linear(1_024, 1_024)
        self.linear_out = nn.Linear(1_024, 1_024)
        self.heads = 16
        self.head_size = 64
        self.scale = self.head_size**-0.5

    def _rotary(self, value: mx.array) -> mx.array:
        sequence = value.shape[1]
        inv_frequency = 1.0 / (10_000.0 ** (mx.arange(0, self.head_size, 2, dtype=mx.float32) / self.head_size))
        frequencies = mx.arange(sequence, dtype=mx.float32)[:, None] * inv_frequency[None, :]
        embedding = mx.concatenate([frequencies, frequencies], axis=-1).astype(value.dtype)
        cosine = mx.cos(embedding)[None, :, None, :]
        sine = mx.sin(embedding)[None, :, None, :]
        shaped = value.reshape(value.shape[0], sequence, self.heads, self.head_size)
        first, second = mx.split(shaped, 2, axis=-1)
        rotated = mx.concatenate([-second, first], axis=-1)
        return (shaped * cosine + rotated * sine).reshape(value.shape)

    def __call__(self, value: mx.array) -> mx.array:
        query_key = self._rotary(value)
        batch, sequence, _ = value.shape
        query = self.linear_q(query_key).reshape(batch, sequence, self.heads, self.head_size).transpose(0, 2, 1, 3)
        key = self.linear_k(query_key).reshape(batch, sequence, self.heads, self.head_size).transpose(0, 2, 1, 3)
        projected_value = self.linear_v(value).reshape(batch, sequence, self.heads, self.head_size).transpose(0, 2, 1, 3)
        weights = mx.softmax((query @ key.transpose(0, 1, 3, 2)) * self.scale, axis=-1)
        attended = (weights @ projected_value).transpose(0, 2, 1, 3).reshape(batch, sequence, 1_024)
        return self.linear_out(attended)


class ConvolutionModule(nn.Module):
    def __init__(self):
        super().__init__()
        self.layer_norm = nn.LayerNorm(1_024, eps=1e-5)
        self.pointwise_conv1 = nn.Linear(1_024, 2_048, bias=False)
        self.depthwise_conv = nn.Conv1d(1_024, 1_024, 31, padding=15, groups=1_024)
        self.pointwise_conv2 = nn.Linear(1_024, 1_024, bias=False)

    def __call__(self, value: mx.array) -> mx.array:
        value = self.pointwise_conv1(self.layer_norm(value))
        gate, activation = mx.split(value, 2, axis=-1)
        value = gate * mx.sigmoid(activation)
        value = self.depthwise_conv(value)
        value = _swish(value)
        return self.pointwise_conv2(value)


class ConformerBlock(nn.Module):
    def __init__(self):
        super().__init__()
        self.ffn1_layer_norm = nn.LayerNorm(1_024, eps=1e-5)
        self.ffn1 = FeedForward()
        self.self_attn_layer_norm = nn.LayerNorm(1_024, eps=1e-5)
        self.self_attn = RotarySelfAttention()
        self.conv_module = ConvolutionModule()
        self.ffn2_layer_norm = nn.LayerNorm(1_024, eps=1e-5)
        self.ffn2 = FeedForward()
        self.final_layer_norm = nn.LayerNorm(1_024, eps=1e-5)

    def __call__(self, value: mx.array) -> mx.array:
        value = value + 0.5 * self.ffn1(self.ffn1_layer_norm(value))
        value = value + self.self_attn(self.self_attn_layer_norm(value))
        value = value + self.conv_module(value)
        value = value + 0.5 * self.ffn2(self.ffn2_layer_norm(value))
        return self.final_layer_norm(value)


class RewardAttention(nn.Module):
    def __init__(self):
        super().__init__()
        self.query_proj = nn.Linear(1_024, 1_024)
        self.key_proj = nn.Linear(1_024, 1_024)
        self.value_proj = nn.Linear(1_024, 1_024)
        self.out_proj = nn.Linear(1_024, 1_024)
        self.heads = 8
        self.head_size = 128

    def __call__(self, value: mx.array) -> mx.array:
        batch, sequence, _ = value.shape
        query = self.query_proj(value).reshape(batch, sequence, self.heads, self.head_size).transpose(0, 2, 1, 3)
        key = self.key_proj(value).reshape(batch, sequence, self.heads, self.head_size).transpose(0, 2, 1, 3)
        projected_value = self.value_proj(value).reshape(batch, sequence, self.heads, self.head_size).transpose(0, 2, 1, 3)
        weights = mx.softmax((query @ key.transpose(0, 1, 3, 2)) * (self.head_size**-0.5), axis=-1)
        attended = (weights @ projected_value).transpose(0, 2, 1, 3).reshape(batch, sequence, 1_024)
        return self.out_proj(attended)


class SongBenchModel(nn.Module):
    def __init__(self):
        super().__init__()
        self.subsampler = Conv2dSubsampling()
        self.conformer = [ConformerBlock() for _ in range(6)]
        self.reward_ffd = [nn.Linear(1_024, 4_096), nn.Linear(4_096, 1_024)]
        self.reward_attn = [RewardAttention() for _ in range(4)]
        self.reward_fc = nn.Linear(2_048, 7)

    def encode(self, mel: mx.array) -> mx.array:
        value = self.subsampler(mel)
        for block in self.conformer:
            value = block(value)
        return value

    def pooled(self, hidden_state: mx.array) -> mx.array:
        ffd = self.reward_ffd[1](nn.relu(self.reward_ffd[0](hidden_state)))
        attended = ffd
        for layer in self.reward_attn:
            attended = layer(attended)
        return mx.concatenate([mx.mean(attended, axis=1), mx.max(ffd, axis=1)], axis=-1)

    def __call__(self, mel: mx.array) -> mx.array:
        return mx.tanh(self.reward_fc(self.pooled(self.encode(mel)))) * 4.5 + 5.5

    def score(self, mel: mx.array) -> dict[str, float]:
        values = self(mel).astype(mx.float32)
        mx.eval(values)
        result = [float(value) for value in values[0].tolist()]
        if len(result) != len(SCORE_NAMES) or any(not (1.0 <= value <= 10.0) for value in result):
            raise ValueError("SongBench produced an invalid score")
        return dict(zip(SCORE_NAMES, result, strict=True))


def load_model(weights: Mapping[str, mx.array]) -> SongBenchModel:
    model = SongBenchModel()
    model.load_weights(list(weights.items()), strict=True)
    model.eval()
    return model
