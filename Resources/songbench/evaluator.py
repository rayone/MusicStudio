"""Artifact lifecycle and one-track SongBench evaluation API."""

from __future__ import annotations

from collections.abc import Callable
import json
import math
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import time

import numpy as np

from .convert import EVALUATOR_VERSION, artifact_directory, install_evaluator, validate_artifact
from .frontend import SongBenchEvaluationError
from .model import SCORE_NAMES

_REFERENCE_VENV = Path(os.environ.get(
    "MUSICSTUDIO_SONGBENCH_VENV",
    Path(os.environ.get("MUSICSTUDIO_HOME", Path.home() / ".MusicStudio"))
    / "venvs" / "songbench-reference",
)).expanduser().resolve()
_REFERENCE_REQUIREMENTS = Path(__file__).resolve().parent.parent / "songbench-reference-requirements.txt"
_REFERENCE_RUNTIME = Path(__file__).resolve().parent / "reference_runtime.py"
_ACTIVE_CHILD: subprocess.Popen[str] | None = None


def _terminate_active_child(signum: int, _frame: object) -> None:
    child = _ACTIVE_CHILD
    if child is not None and child.poll() is None:
        child.terminate()
    raise SystemExit(128 + signum)


signal.signal(signal.SIGTERM, _terminate_active_child)
signal.signal(signal.SIGINT, _terminate_active_child)


def _reference_python() -> Path:
    return _REFERENCE_VENV / "bin" / "python3"


def _find_uv() -> Path:
    package = Path(__file__).resolve()
    candidates = [
        package.parent.parent / "bin" / "uv",
        package.parent.parent.parent / "bin" / "uv",
        Path(os.environ.get("MUSICSTUDIO_HOME", Path.home() / ".MusicStudio")) / "bin" / "uv",
    ]
    executable = shutil.which("uv")
    if executable:
        candidates.append(Path(executable))
    for candidate in candidates:
        if candidate.is_file() and os.access(candidate, os.X_OK):
            return candidate
    raise SongBenchEvaluationError("Bundled package installer is missing")


def _runtime_ready() -> bool:
    python = _reference_python()
    if not python.is_file():
        return False
    check = subprocess.run(
        [str(python), "-c", "import torch, torchaudio, muq, librosa, hydra, safetensors"],
        capture_output=True,
        timeout=60,
    )
    return check.returncode == 0


def artifact_status(models_dir: Path) -> dict[str, object]:
    artifact = artifact_directory(models_dir)
    installing = artifact.parent / "install.tmp"
    if artifact.exists():
        ready, message = validate_artifact(artifact)
        if ready and _runtime_ready():
            return {"status": "ready", "message": message, "path": str(artifact)}
        if ready:
            return {"status": "installing", "message": "SongBench CPU runtime is not installed"}
        return {"status": "invalid", "message": message, "path": str(artifact)}
    if installing.exists():
        return {"status": "installing", "message": "SongBench evaluator installation is resumable"}
    return {"status": "missing", "message": "SongBench evaluator is not installed"}


def _ensure_reference_runtime(emit_progress: Callable[[dict[str, object]], None]) -> None:
    if _runtime_ready():
        return
    if not _REFERENCE_REQUIREMENTS.is_file():
        raise SongBenchEvaluationError("SongBench CPU requirements are missing")
    uv = _find_uv()
    _REFERENCE_VENV.parent.mkdir(parents=True, exist_ok=True)
    emit_progress({"stage": "install_reference", "fraction": 0.0, "bytes": 0, "total_bytes": 0})
    if not _reference_python().is_file():
        result = subprocess.run(
            [str(uv), "venv", "--python", sys.executable, str(_REFERENCE_VENV)],
            capture_output=True,
            text=True,
            timeout=300,
        )
        if result.returncode != 0:
            raise SongBenchEvaluationError("SongBench CPU environment creation failed")
    result = subprocess.run(
        [
            str(uv), "pip", "install", "--python", str(_reference_python()),
            "-r", str(_REFERENCE_REQUIREMENTS),
        ],
        capture_output=True,
        text=True,
        timeout=1800,
    )
    if result.returncode != 0 or not _runtime_ready():
        raise SongBenchEvaluationError("SongBench CPU dependency installation failed")
    emit_progress({"stage": "install_reference", "fraction": 1.0, "bytes": 0, "total_bytes": 0})


def ensure_evaluator(models_dir: Path, emit_progress: Callable[[dict[str, object]], None]) -> Path:
    artifact = artifact_directory(models_dir)
    if artifact.exists():
        ready, message = validate_artifact(artifact)
        if not ready:
            shutil.rmtree(artifact, ignore_errors=True)
            try:
                artifact = install_evaluator(models_dir, emit_progress)
            except Exception as error:
                detail = str(error).strip() or message
                raise SongBenchEvaluationError(detail[:240]) from error
    else:
        try:
            artifact = install_evaluator(models_dir, emit_progress)
        except SongBenchEvaluationError:
            raise
        except Exception as error:
            detail = str(error).strip() or "SongBench evaluator installation failed"
            raise SongBenchEvaluationError(detail[:240]) from error
    _ensure_reference_runtime(emit_progress)
    return artifact


def evaluate_song(audio_path: Path, models_dir: Path) -> dict[str, object]:
    global _ACTIVE_CHILD
    audio_path = Path(audio_path).expanduser().resolve()
    if not audio_path.is_file():
        raise SongBenchEvaluationError("Audio file is missing")
    artifact = artifact_directory(models_dir)
    ready, message = validate_artifact(artifact)
    if not ready or not _runtime_ready():
        raise SongBenchEvaluationError(message if not ready else "SongBench CPU runtime is not installed")
    started = time.monotonic()
    try:
        _ACTIVE_CHILD = subprocess.Popen(
            [str(_reference_python()), str(_REFERENCE_RUNTIME), str(audio_path), str(artifact)],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        stdout, stderr = _ACTIVE_CHILD.communicate(timeout=3600)
        result_code = _ACTIVE_CHILD.returncode
    except (OSError, subprocess.SubprocessError) as error:
        if _ACTIVE_CHILD is not None and _ACTIVE_CHILD.poll() is None:
            _ACTIVE_CHILD.kill()
        raise SongBenchEvaluationError("SongBench evaluation failed") from error
    finally:
        _ACTIVE_CHILD = None
    if result_code != 0:
        detail = stderr.strip().splitlines()
        error_message = detail[-1] if detail else "SongBench evaluation failed"
        raise SongBenchEvaluationError(error_message[:240])
    try:
        scores = json.loads(stdout.strip().splitlines()[-1])
        values = [float(scores[name]) for name in SCORE_NAMES]
    except (IndexError, KeyError, TypeError, ValueError, json.JSONDecodeError) as error:
        raise SongBenchEvaluationError("SongBench returned invalid scores") from error
    if any(not math.isfinite(value) or not (1.0 <= value <= 10.0) for value in values):
        raise SongBenchEvaluationError("SongBench produced an invalid score")
    return {name: value for name, value in zip(SCORE_NAMES, values, strict=True)} | {
        "overall": float(np.mean(values, dtype=np.float64)),
        "device": "cpu",
        "evaluator_version": EVALUATOR_VERSION,
        "elapsed_sec": time.monotonic() - started,
    }
