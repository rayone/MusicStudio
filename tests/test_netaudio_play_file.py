"""Regression tests for the cast-after-sleep fix in Resources/netaudio.py.

When a renderer sleeps and a new track is played, the existing backend session is
stale: a plain ``start_stream`` throws. ``Controller.play_file`` must reactivate the
pipeline (release -> connect -> start_stream) once, ending in ``streaming`` on recovery
or ``error`` (with an emitted event) if the retry also fails.

Stdlib-only (``python3 -m unittest discover tests``); no pytest, no live renderer.
"""

import asyncio
import importlib.util
import os
import sys
import unittest

_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def _load_netaudio():
    """Import Resources/netaudio.py without running its asyncio main()."""
    path = os.path.join(_ROOT, "Resources", "netaudio.py")
    spec = importlib.util.spec_from_file_location("netaudio", path)
    module = importlib.util.module_from_spec(spec)
    # Register before exec so module-level @dataclass can resolve its own module.
    sys.modules["netaudio"] = module
    spec.loader.exec_module(module)
    return module


na = _load_netaudio()


class _FakeBackend:
    """A backend whose first start_stream fails `fail_times` times (simulating a dead
    session), tracking the exact call order so the recovery sequence can be asserted."""

    protocol = "cast"

    def __init__(self, fail_times: int):
        self.fail_times = fail_times
        self.starts = 0
        self.connected = True  # an existing (but about-to-be-stale) session
        self.calls: list[str] = []

    async def start_stream(self, receiver):
        self.calls.append("start")
        self.starts += 1
        if self.starts <= self.fail_times:
            raise RuntimeError("session dead (renderer slept)")

    async def release(self, receiver):
        self.calls.append("release")
        self.connected = False

    async def connect(self, receiver):
        self.calls.append("connect")
        self.connected = True


class _FakeReceiver:
    protocol = "cast"
    name = "Living Room"
    host = "10.0.0.5"


class _FakeStream:
    _file_path = "/tmp/x.wav"

    def set_file(self, path):
        self._file_path = path

    def playback_url(self):
        return "http://host/x.wav"


def _make_controller(backend):
    c = na.Controller.__new__(na.Controller)  # bypass process/socket plumbing
    c.active = _FakeReceiver()
    c.active_backend = backend
    c.current_title = ""
    c.stream = _FakeStream()
    c.states: list[str] = []
    c.set_state = lambda state, detail="": c.states.append(state)
    return c


class PlayFileReactivationTests(unittest.TestCase):
    def test_slept_renderer_reconnects_and_streams(self):
        """First start fails (stale), then release->connect->start recovers to streaming."""
        backend = _FakeBackend(fail_times=1)
        c = _make_controller(backend)
        asyncio.run(c.play_file("/tmp/x.wav", "Song A"))

        self.assertEqual(backend.calls, ["start", "release", "connect", "start"])
        self.assertEqual(backend.starts, 2)
        self.assertTrue(backend.connected)
        self.assertEqual(c.states[-1], "streaming")

    def test_reconnect_failure_ends_in_error_and_emits(self):
        """Both attempts fail -> state ends 'error' and an error event is emitted."""
        backend = _FakeBackend(fail_times=2)
        c = _make_controller(backend)

        emitted: list[tuple] = []
        orig_emit = na.emit
        na.emit = lambda event, **kw: emitted.append((event, kw))
        try:
            asyncio.run(c.play_file("/tmp/x.wav", "Song A"))
        finally:
            na.emit = orig_emit

        self.assertEqual(backend.calls, ["start", "release", "connect", "start"])
        self.assertEqual(c.states[-1], "error")
        self.assertTrue(
            any(ev == "error" for ev, _ in emitted),
            f"expected an error event, got {emitted}",
        )

    def test_healthy_session_single_start_no_churn(self):
        """A live session plays with one start_stream and no reconnect churn."""
        backend = _FakeBackend(fail_times=0)
        c = _make_controller(backend)
        asyncio.run(c.play_file("/tmp/y.wav", "Song B"))

        self.assertEqual(backend.calls, ["start"])
        self.assertEqual(c.states, ["streaming"])


if __name__ == "__main__":
    unittest.main()
