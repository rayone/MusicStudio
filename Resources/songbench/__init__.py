"""Benchmark-faithful SongBench evaluation for MusicStudio."""

from .evaluator import artifact_status, ensure_evaluator, evaluate_song
from .frontend import SongBenchEvaluationError

__all__ = [
    "SongBenchEvaluationError",
    "artifact_status",
    "ensure_evaluator",
    "evaluate_song",
]
