"""Deterministic 24 kHz audio decoding and MuQ mel preprocessing."""

from __future__ import annotations

import math
import subprocess
import tempfile
import wave
from pathlib import Path

import numpy as np
from scipy.signal import resample_poly

SAMPLE_RATE = 24_000
N_FFT = 2_048
HOP_LENGTH = 240
N_MELS = 128
MEL_MEAN = 6.768444971712967
MEL_STD = 18.417922652295623
_SUPPORTED = {".wav", ".mp3", ".m4a", ".flac"}


class SongBenchEvaluationError(RuntimeError):
    """A concise evaluation error that is safe to display in the UI."""


def _decode_pcm_wav(path: Path) -> tuple[np.ndarray, int]:
    try:
        with wave.open(str(path), "rb") as source:
            channels = source.getnchannels()
            sample_rate = source.getframerate()
            sample_width = source.getsampwidth()
            frames = source.getnframes()
            raw = source.readframes(frames)
    except (OSError, EOFError, wave.Error) as error:
        raise SongBenchEvaluationError("Audio could not be decoded") from error

    if frames <= 0 or channels <= 0 or sample_rate <= 0:
        raise SongBenchEvaluationError("Audio is empty")
    if sample_width == 1:
        audio = (np.frombuffer(raw, dtype=np.uint8).astype(np.float32) - 128.0) / 128.0
    elif sample_width == 2:
        audio = np.frombuffer(raw, dtype="<i2").astype(np.float32) / 32768.0
    elif sample_width == 3:
        packed = np.frombuffer(raw, dtype=np.uint8).reshape(-1, 3)
        values = (
            packed[:, 0].astype(np.int32)
            | (packed[:, 1].astype(np.int32) << 8)
            | (packed[:, 2].astype(np.int32) << 16)
        )
        values = (values ^ 0x800000) - 0x800000
        audio = values.astype(np.float32) / 8388608.0
    elif sample_width == 4:
        audio = np.frombuffer(raw, dtype="<i4").astype(np.float32) / 2147483648.0
    else:
        raise SongBenchEvaluationError("Audio uses an unsupported PCM format")

    try:
        audio = audio.reshape(-1, channels).mean(axis=1, dtype=np.float32)
    except ValueError as error:
        raise SongBenchEvaluationError("Audio data is malformed") from error
    return np.ascontiguousarray(audio, dtype=np.float32), sample_rate


def decode_audio(path: Path) -> np.ndarray:
    """Decode supported audio to finite mono float32 samples at exactly 24 kHz."""
    path = Path(path).expanduser().resolve()
    if not path.is_file():
        raise SongBenchEvaluationError("Audio file is missing")
    if path.suffix.lower() not in _SUPPORTED:
        raise SongBenchEvaluationError("Audio format is not supported")
    if path.stat().st_size == 0:
        raise SongBenchEvaluationError("Audio is empty")

    scratch: Path | None = None
    try:
        source = path
        if path.suffix.lower() != ".wav":
            handle, scratch_name = tempfile.mkstemp(prefix="musicstudio-songbench-", suffix=".wav")
            Path(scratch_name).unlink(missing_ok=True)
            scratch = Path(scratch_name)
            try:
                result = subprocess.run(
                    [
                        "/usr/bin/afconvert",
                        "-f", "WAVE",
                        "-d", "LEI16@24000",
                        "-c", "1",
                        str(path),
                        str(scratch),
                    ],
                    capture_output=True,
                    text=True,
                    timeout=300,
                )
            finally:
                try:
                    import os
                    os.close(handle)
                except OSError:
                    pass
            if result.returncode != 0 or not scratch.is_file():
                raise SongBenchEvaluationError("Audio could not be decoded")
            source = scratch

        audio, sample_rate = _decode_pcm_wav(source)
        if sample_rate != SAMPLE_RATE:
            divisor = math.gcd(sample_rate, SAMPLE_RATE)
            audio = resample_poly(
                audio,
                SAMPLE_RATE // divisor,
                sample_rate // divisor,
            ).astype(np.float32, copy=False)
        if audio.size == 0:
            raise SongBenchEvaluationError("Audio is empty")
        if not np.isfinite(audio).all():
            raise SongBenchEvaluationError("Audio contains non-finite samples")
        return np.ascontiguousarray(audio, dtype=np.float32)
    except SongBenchEvaluationError:
        raise
    except (OSError, subprocess.SubprocessError, ValueError) as error:
        raise SongBenchEvaluationError("Audio could not be decoded") from error
    finally:
        if scratch is not None:
            scratch.unlink(missing_ok=True)


def _hz_to_mel(frequency: np.ndarray | float) -> np.ndarray:
    return 2595.0 * np.log10(1.0 + np.asarray(frequency) / 700.0)


def _mel_to_hz(mel: np.ndarray | float) -> np.ndarray:
    return 700.0 * (np.power(10.0, np.asarray(mel) / 2595.0) - 1.0)


def _mel_filterbank() -> np.ndarray:
    fft_frequencies = np.linspace(0.0, SAMPLE_RATE / 2.0, N_FFT // 2 + 1)
    mel_points = np.linspace(_hz_to_mel(0.0), _hz_to_mel(SAMPLE_RATE / 2.0), N_MELS + 2)
    frequency_points = _mel_to_hz(mel_points)
    lower = frequency_points[:-2, None]
    center = frequency_points[1:-1, None]
    upper = frequency_points[2:, None]
    rising = (fft_frequencies[None, :] - lower) / (center - lower)
    falling = (upper - fft_frequencies[None, :]) / (upper - center)
    return np.maximum(0.0, np.minimum(rising, falling)).astype(np.float32)


_MEL_FILTER = _mel_filterbank()
_HANN_WINDOW = np.hanning(N_FFT + 1)[:-1].astype(np.float32)


def muq_mel_frontend(audio: np.ndarray) -> np.ndarray:
    """Return MuQ's normalized `[1, 128, frames-1]` mel tensor."""
    samples = np.asarray(audio, dtype=np.float32)
    if samples.ndim != 1 or samples.size == 0:
        raise SongBenchEvaluationError("Audio is empty")
    if not np.isfinite(samples).all():
        raise SongBenchEvaluationError("Audio contains non-finite samples")

    try:
        padded = np.pad(samples, N_FFT // 2, mode="reflect")
    except ValueError as error:
        raise SongBenchEvaluationError("Audio is too short to evaluate") from error
    frame_count = 1 + (padded.size - N_FFT) // HOP_LENGTH
    if frame_count < 2:
        raise SongBenchEvaluationError("Audio is too short to evaluate")
    frames = np.lib.stride_tricks.as_strided(
        padded,
        shape=(frame_count, N_FFT),
        strides=(padded.strides[0] * HOP_LENGTH, padded.strides[0]),
        writeable=False,
    )
    spectrum = np.fft.rfft(frames * _HANN_WINDOW[None, :], n=N_FFT, axis=1)
    power = (spectrum.real * spectrum.real + spectrum.imag * spectrum.imag).astype(np.float32)
    mel_power = np.maximum(power @ _MEL_FILTER.T, np.float32(1e-10))
    decibels = 10.0 * np.log10(mel_power)
    normalized = ((decibels[:-1].T - MEL_MEAN) / MEL_STD).astype(np.float32)
    if not np.isfinite(normalized).all():
        raise SongBenchEvaluationError("Audio preprocessing produced non-finite values")
    return np.ascontiguousarray(normalized[None, :, :])


def load_muq_features(path: Path) -> np.ndarray:
    return muq_mel_frontend(decode_audio(path))
