"""Pinned SongBench/MuQ artifact download and local installation."""

from __future__ import annotations

from collections.abc import Callable
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import shutil
import urllib.error
import urllib.request

import mlx.core as mx
import numpy as np
from safetensors import safe_open

from .model import SCORE_NAMES, SongBenchModel

FORMAT_VERSION = 1
EVALUATOR_VERSION = "songbench-reference-cpu-v1"
ARTIFACT_NAME = "songbench-reference-cpu"
SONGBENCH_REVISION = "9361b55ebff3fffcefbbc9a4653936ae6789c3c8"
SONGBENCH_URL = f"https://raw.githubusercontent.com/Tencent/SongBench/{SONGBENCH_REVISION}/ckpt/songbench.safetensors"
SONGBENCH_SIZE = 100_808_636
SONGBENCH_GIT_BLOB_SHA = "e9ed97f5b2972e1b946e6da770f02aeed42f66eb"
SONGBENCH_SHA256 = "ca27966a6d2b3312587b9e1d53ee3adf6bde8ac68a7d339e6f962206cbfde312"
MUQ_REPO = "OpenMuQ/MuQ-large-msd-iter"
MUQ_REVISION = "0562a57814f6f8bbd9fdea0a25921a2fce1a841a"
MUQ_FILE = "model.safetensors"
MUQ_URL = f"https://huggingface.co/{MUQ_REPO}/resolve/{MUQ_REVISION}/{MUQ_FILE}"
MUQ_SIZE = 1_333_825_096
MUQ_SHA256 = "273febab2be02872c37d2c37e48a9d6c52c1c9392f3eeeabd498efa281ccb7a6"
MUQ_CONFIG_FILE = "config.json"
MUQ_CONFIG_URL = f"https://huggingface.co/{MUQ_REPO}/resolve/{MUQ_REVISION}/{MUQ_CONFIG_FILE}"
MUQ_CONFIG_GIT_BLOB_SHA = "fec6c73f7b811281b440462fcf4d98c7953c3d94"
MUQ_LAYERS = [0, 1, 2, 3, 4, 5]
REQUIRED_FILES = {
    "model.safetensors",
    "songbench.safetensors",
    "config.json",
    "conversion.json",
    "SONGBENCH_LICENSE.txt",
    "MUQ_LICENSE.txt",
}
Progress = Callable[[dict[str, object]], None]


def artifact_directory(models_dir: Path) -> Path:
    return Path(models_dir).expanduser().resolve() / "evaluators" / ARTIFACT_NAME


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(8 * 1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def _git_blob_sha(data: bytes) -> str:
    return hashlib.sha1(b"blob " + str(len(data)).encode() + b"\0" + data).hexdigest()


def expected_metadata() -> dict[str, object]:
    return {
        "format_version": FORMAT_VERSION,
        "evaluator_version": EVALUATOR_VERSION,
        "songbench_revision": SONGBENCH_REVISION,
        "songbench_sha256": SONGBENCH_SHA256,
        "songbench_git_blob_sha": SONGBENCH_GIT_BLOB_SHA,
        "muq_repo": MUQ_REPO,
        "muq_revision": MUQ_REVISION,
        "muq_sha256": MUQ_SHA256,
        "dtype": "float32",
        "backend": "reference-cpu",
        "muq_layers": MUQ_LAYERS,
        "scores": list(SCORE_NAMES),
        "parity_status": "passed",
    }


def validate_artifact(path: Path, *, verify_checkpoint: bool = True) -> tuple[bool, str]:
    path = Path(path)
    missing = sorted(name for name in REQUIRED_FILES if not (path / name).is_file())
    if missing:
        return False, f"Missing evaluator file: {missing[0]}"
    try:
        metadata = json.loads((path / "conversion.json").read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return False, "Evaluator metadata is unreadable"
    for key, expected in expected_metadata().items():
        if metadata.get(key) != expected:
            return False, f"Evaluator metadata mismatch: {key}"
    if verify_checkpoint:
        if _sha256(path / "model.safetensors") != MUQ_SHA256:
            return False, "MuQ checkpoint digest mismatch"
        if _sha256(path / "songbench.safetensors") != SONGBENCH_SHA256:
            return False, "SongBench checkpoint digest mismatch"
    return True, "SongBench reference evaluator is ready"


def _emit(progress: Progress, stage: str, *, fraction: float, bytes_done: int = 0, bytes_total: int = 0) -> None:
    progress({
        "stage": stage,
        "fraction": max(0.0, min(1.0, fraction)),
        "bytes": bytes_done,
        "total_bytes": bytes_total,
    })


def _download(url: str, destination: Path, size: int, digest: str, stage: str, progress: Progress) -> Path:
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.is_file() and destination.stat().st_size == size and _sha256(destination) == digest:
        _emit(progress, stage, fraction=1.0, bytes_done=size, bytes_total=size)
        return destination
    if destination.is_file() and destination.stat().st_size == size:
        destination.unlink()
        existing = 0
    existing = destination.stat().st_size if destination.is_file() else 0
    if existing > size:
        destination.unlink()
        existing = 0
    headers = {"User-Agent": "MusicStudio-SongBench/1"}
    if existing:
        headers["Range"] = f"bytes={existing}-"
    try:
        response = urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=60)
        if existing and getattr(response, "status", 200) != 206:
            destination.unlink(missing_ok=True)
            existing = 0
        mode = "ab" if existing else "wb"
        with response, destination.open(mode) as output:
            completed = existing
            while True:
                block = response.read(4 * 1024 * 1024)
                if not block:
                    break
                output.write(block)
                completed += len(block)
                _emit(progress, stage, fraction=completed / size, bytes_done=completed, bytes_total=size)
    except (OSError, urllib.error.URLError) as error:
        raise RuntimeError(f"SongBench download failed during {stage}") from error
    if destination.stat().st_size != size or _sha256(destination) != digest:
        raise RuntimeError(f"SongBench download verification failed during {stage}")
    return destination


def _load_numpy(path: Path) -> dict[str, np.ndarray]:
    with safe_open(path, framework="numpy") as source:
        return {name: source.get_tensor(name) for name in source.keys()}


def _fold_batch_norm(
    weight: np.ndarray,
    bias: np.ndarray,
    gamma: np.ndarray,
    beta: np.ndarray,
    mean: np.ndarray,
    variance: np.ndarray,
    *,
    epsilon: float = 1e-5,
) -> tuple[np.ndarray, np.ndarray]:
    scale = gamma.astype(np.float32) / np.sqrt(variance.astype(np.float32) + epsilon)
    folded_weight = weight.astype(np.float32) * scale.reshape((-1,) + (1,) * (weight.ndim - 1))
    folded_bias = (bias.astype(np.float32) - mean.astype(np.float32)) * scale + beta.astype(np.float32)
    return folded_weight, folded_bias


def _as_bf16(value: np.ndarray) -> mx.array:
    return mx.array(np.ascontiguousarray(value)).astype(mx.bfloat16)


def _map_subsampler(source: dict[str, np.ndarray], output: dict[str, mx.array]) -> None:
    for block in range(2):
        prefix = f"model.conv.conv.{block}"
        target = f"subsampler.blocks.{block}"
        for conv_name, bn_name, target_name in (
            ("conv1", "bn1", "conv1"),
            ("conv2", "bn2", "conv2"),
            ("conv3", "bn3", "residual"),
        ):
            conv = f"{prefix}.{conv_name}"
            bn = f"{prefix}.{bn_name}"
            weight, bias = _fold_batch_norm(
                source[f"{conv}.weight"], source[f"{conv}.bias"],
                source[f"{bn}.weight"], source[f"{bn}.bias"],
                source[f"{bn}.running_mean"], source[f"{bn}.running_var"],
            )
            output[f"{target}.{target_name}.weight"] = _as_bf16(weight.transpose(0, 2, 3, 1))
            output[f"{target}.{target_name}.bias"] = _as_bf16(bias)
    output["subsampler.linear.weight"] = _as_bf16(source["model.conv.linear.weight"])
    output["subsampler.linear.bias"] = _as_bf16(source["model.conv.linear.bias"])


def _map_conformer_layer(layer: int, source: dict[str, np.ndarray], output: dict[str, mx.array]) -> None:
    source_prefix = f"model.conformer.layers.{layer}"
    target_prefix = f"conformer.{layer}"
    direct = (
        "ffn1_layer_norm.weight", "ffn1_layer_norm.bias",
        "ffn1.intermediate_dense.weight", "ffn1.intermediate_dense.bias",
        "ffn1.output_dense.weight", "ffn1.output_dense.bias",
        "self_attn_layer_norm.weight", "self_attn_layer_norm.bias",
        "self_attn.linear_q.weight", "self_attn.linear_q.bias",
        "self_attn.linear_k.weight", "self_attn.linear_k.bias",
        "self_attn.linear_v.weight", "self_attn.linear_v.bias",
        "self_attn.linear_out.weight", "self_attn.linear_out.bias",
        "conv_module.layer_norm.weight", "conv_module.layer_norm.bias",
        "ffn2_layer_norm.weight", "ffn2_layer_norm.bias",
        "ffn2.intermediate_dense.weight", "ffn2.intermediate_dense.bias",
        "ffn2.output_dense.weight", "ffn2.output_dense.bias",
        "final_layer_norm.weight", "final_layer_norm.bias",
    )
    for suffix in direct:
        output[f"{target_prefix}.{suffix}"] = _as_bf16(source[f"{source_prefix}.{suffix}"])
    for name in ("pointwise_conv1", "pointwise_conv2"):
        weight = source[f"{source_prefix}.conv_module.{name}.weight"]
        output[f"{target_prefix}.conv_module.{name}.weight"] = _as_bf16(weight[:, :, 0])
    conv = source[f"{source_prefix}.conv_module.depthwise_conv.weight"]
    zeros = np.zeros(conv.shape[0], dtype=np.float32)
    bn = f"{source_prefix}.conv_module.batch_norm"
    conv, bias = _fold_batch_norm(
        conv, zeros,
        source[f"{bn}.weight"], source[f"{bn}.bias"],
        source[f"{bn}.running_mean"], source[f"{bn}.running_var"],
    )
    output[f"{target_prefix}.conv_module.depthwise_conv.weight"] = _as_bf16(conv.transpose(0, 2, 1))
    output[f"{target_prefix}.conv_module.depthwise_conv.bias"] = _as_bf16(bias)


def _map_reward(source: dict[str, np.ndarray], output: dict[str, mx.array]) -> None:
    for source_index, target_index in ((0, 0), (2, 1)):
        output[f"reward_ffd.{target_index}.weight"] = _as_bf16(source[f"ffd.{source_index}.weight"])
        output[f"reward_ffd.{target_index}.bias"] = _as_bf16(source[f"ffd.{source_index}.bias"])
    for index in range(4):
        weights = np.split(source[f"attn.{index}.in_proj_weight"], 3, axis=0)
        biases = np.split(source[f"attn.{index}.in_proj_bias"], 3, axis=0)
        for name, weight, bias in zip(("query_proj", "key_proj", "value_proj"), weights, biases, strict=True):
            output[f"reward_attn.{index}.{name}.weight"] = _as_bf16(weight)
            output[f"reward_attn.{index}.{name}.bias"] = _as_bf16(bias)
        output[f"reward_attn.{index}.out_proj.weight"] = _as_bf16(source[f"attn.{index}.out_proj.weight"])
        output[f"reward_attn.{index}.out_proj.bias"] = _as_bf16(source[f"attn.{index}.out_proj.bias"])
    output["reward_fc.weight"] = _as_bf16(source["fc.weight"])
    output["reward_fc.bias"] = _as_bf16(source["fc.bias"])


def convert_checkpoints(muq_path: Path, songbench_path: Path, output_path: Path, progress: Progress) -> None:
    muq = _load_numpy(muq_path)
    reward = _load_numpy(songbench_path)
    converted: dict[str, mx.array] = {}
    _map_subsampler(muq, converted)
    _emit(progress, "convert_subsampler", fraction=1.0)
    for layer in MUQ_LAYERS:
        _map_conformer_layer(layer, muq, converted)
        _emit(progress, "convert_conformer", fraction=(layer + 1) / len(MUQ_LAYERS))
    _map_reward(reward, converted)
    _emit(progress, "convert_reward_head", fraction=1.0)
    mx.save_safetensors(str(output_path), converted, metadata={"dtype": "bfloat16", "format_version": "1"})
    mx.eval(*converted.values())


def install_evaluator(models_dir: Path, progress: Progress) -> Path:
    final = artifact_directory(models_dir)
    parent = final.parent
    temporary = parent / "install.tmp"
    downloads = temporary / "downloads"
    assembled = temporary / "assembled"
    parent.mkdir(parents=True, exist_ok=True)
    downloads.mkdir(parents=True, exist_ok=True)
    shutil.rmtree(assembled, ignore_errors=True)
    assembled.mkdir(parents=True)
    try:
        songbench = _download(
            SONGBENCH_URL, downloads / "songbench.safetensors",
            SONGBENCH_SIZE, SONGBENCH_SHA256, "download_songbench", progress,
        )
        muq = _download(
            MUQ_URL, downloads / MUQ_FILE,
            MUQ_SIZE, MUQ_SHA256, "download_muq", progress,
        )
        config_data = urllib.request.urlopen(MUQ_CONFIG_URL, timeout=60).read()
        if _git_blob_sha(config_data) != MUQ_CONFIG_GIT_BLOB_SHA:
            raise RuntimeError("MuQ config verification failed")
        shutil.copy2(muq, assembled / "model.safetensors")
        shutil.copy2(songbench, assembled / "songbench.safetensors")
        (assembled / "config.json").write_bytes(config_data)
        package = Path(__file__).resolve().parent
        shutil.copy2(package / "SONGBENCH_LICENSE.txt", assembled / "SONGBENCH_LICENSE.txt")
        shutil.copy2(package / "MUQ_LICENSE.txt", assembled / "MUQ_LICENSE.txt")
        metadata = expected_metadata() | {
            "installed_at": datetime.now(timezone.utc).isoformat(),
            "mlx_parity_status": "rejected",
            "mlx_max_final_score_error": 0.013214111328125,
        }
        (assembled / "conversion.json").write_text(
            json.dumps(metadata, indent=2, sort_keys=True) + "\n", encoding="utf-8"
        )
        _emit(progress, "validate", fraction=1.0)
        ready, message = validate_artifact(assembled)
        if not ready:
            raise RuntimeError(message)
        if final.exists():
            shutil.rmtree(final)
        os.replace(assembled, final)
        shutil.rmtree(downloads, ignore_errors=True)
        return final
    except Exception:
        shutil.rmtree(assembled, ignore_errors=True)
        raise
