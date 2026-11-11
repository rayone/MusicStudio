#!/usr/bin/env python3
"""MusicStudio network audio output sidecar.

A long-lived process that discovers AirPlay / DLNA / Google Cast receivers on the
local network, streams the app's audio to a selected receiver, and exposes volume
and transport control. It speaks the same newline-delimited JSON protocol as
``studio.py``: one JSON object per line on stdout (see ``emit``), and it reads one
JSON command per line on stdin.

Why a separate module rather than a ``studio.py`` subcommand:

* The three backends (``pyatv``, ``async-upnp-client``, ``pychromecast``) are async
  and want a persistent asyncio loop plus a persistent HTTP stream server. That is a
  different lifecycle from the subprocess-per-task generation engine.
* The casting dependency tree (``zeroconf``, ``aiohttp``, ``protobuf``, ...) is large
  and unrelated to MLX generation. Keeping it in its own module isolates failures the
  same way SongBench is isolated.

Protocol
--------
Commands in (stdin, one JSON object per line)::

    {"cmd": "discover"}                          start/refresh discovery
    {"cmd": "select", "id": "<receiver id>"}     connect and begin streaming
    {"cmd": "stop"}                              stop streaming, release receiver
    {"cmd": "set_volume", "level": 0.0..1.0}     set volume where supported
    {"cmd": "feed_format", "sample_rate": 48000, "channels": 2}
                                                 announce the PCM format the app taps
    {"cmd": "shutdown"}                          exit cleanly

Events out (stdout, one JSON object per line, component ``netaudio``)::

    {"event": "ready", "stream_port": 8009}
    {"event": "receivers", "receivers": [ {id,name,model,protocol,available,volume}... ]}
    {"event": "status", "state": "idle|connecting|streaming|reconnecting|stopped|error",
             "receiver_id": "...", "detail": "...", "volume": 0.37}
    {"event": "log", "message": "...", "detail": "..."}
    {"event": "error", "message": "..."}

Audio ingress
-------------
The Swift ``AudioEngine`` installs a tap on its main mixer and writes raw interleaved
float32 (or int16) PCM frames to the sidecar over a loopback TCP socket on
``feed_port``. The sidecar converts/encodes as each backend requires and either hands
the stream to the backend (AirPlay) or serves it over HTTP (DLNA / Cast).
"""

from __future__ import annotations

import argparse
import asyncio
import ipaddress
import json
import logging
import os
import re
import socket
import sys
import threading
import time
from dataclasses import dataclass, field, asdict
from typing import Optional

COMPONENT = "netaudio"

# stdout is the JSON event channel the Swift side parses line by line. The casting
# libraries (pychromecast, zeroconf, async-upnp-client) and some of their deps log via
# the logging module. A stray log line on stdout would corrupt a JSON event, so we
# pin every library logger (and their descendants, e.g. pychromecast.dial) to CRITICAL
# and force all logging output to stderr. Our own diagnostics go through emit().
logging.basicConfig(level=logging.CRITICAL, stream=sys.stderr, force=True)
logging.disable(logging.ERROR)  # drop anything below CRITICAL, logger-tree-wide
for _noisy in ("pychromecast", "zeroconf", "async_upnp_client", "pyatv",
               "aiohttp", "charset_normalizer", "asyncio"):
    _lg = logging.getLogger(_noisy)
    _lg.setLevel(logging.CRITICAL)


def emit(event: str, level: str = "info", **kw) -> None:
    """Emit one JSON event on stdout, matching the studio.py worker protocol."""
    payload = {"event": event, "component": COMPONENT, "level": level}
    payload.update(kw)
    try:
        print(json.dumps(payload), flush=True)
    except (BrokenPipeError, ValueError):
        # Swift side went away; nothing we can do.
        pass


def log(message: str, level: str = "info", detail: str = "") -> None:
    emit("log", level=level, message=message, detail=detail)


# ===========================================================================
# IP range parsing (cross-VLAN unicast discovery)
# ===========================================================================

# Receivers on a different VLAN/subnet are invisible to multicast mDNS/SSDP unless the
# network runs an mDNS reflector. To reach them we probe an explicit list of hosts the
# user supplies, in addition to the normal multicast scan.

MAX_SCAN_HOSTS = 1024  # safety cap so a /16 typo can't launch 65k probes


def parse_ip_ranges(spec: str) -> list[str]:
    """Expand a user scan spec into a de-duplicated list of host IP strings.

    Accepts comma/space/newline-separated entries, each of which may be:
      * a single address        192.168.20.42
      * a CIDR block            192.168.20.0/24   (network/broadcast excluded)
      * an inclusive range      192.168.20.10-192.168.20.60
      * a short range           192.168.20.10-60  (last octet only)

    Invalid entries are skipped with a warning. The result is capped at
    ``MAX_SCAN_HOSTS`` so a wide mask cannot blow up the scan.
    """
    if not spec or not spec.strip():
        return []
    hosts: list[str] = []
    seen: set[str] = set()

    def _add(ip: str) -> None:
        if ip not in seen:
            seen.add(ip)
            hosts.append(ip)

    tokens = [t for t in spec.replace("\n", ",").replace(" ", ",").split(",") if t]
    for token in tokens:
        if len(hosts) >= MAX_SCAN_HOSTS:
            break
        try:
            if "/" in token:
                net = ipaddress.ip_network(token, strict=False)
                for addr in net.hosts():
                    if len(hosts) >= MAX_SCAN_HOSTS:
                        break
                    _add(str(addr))
            elif "-" in token:
                lo_s, hi_s = token.split("-", 1)
                lo = ipaddress.ip_address(lo_s.strip())
                if "." in hi_s:
                    hi = ipaddress.ip_address(hi_s.strip())
                else:
                    # short form: reuse the low address's first three octets
                    prefix = lo_s.strip().rsplit(".", 1)[0]
                    hi = ipaddress.ip_address(f"{prefix}.{int(hi_s.strip())}")
                if int(hi) < int(lo):
                    lo, hi = hi, lo
                for i in range(int(lo), int(hi) + 1):
                    if len(hosts) >= MAX_SCAN_HOSTS:
                        break
                    _add(str(ipaddress.ip_address(i)))
            else:
                _add(str(ipaddress.ip_address(token.strip())))
        except ValueError:
            log(f"Ignoring invalid scan range entry: {token!r}", level="warn")
    if len(hosts) >= MAX_SCAN_HOSTS:
        log(f"Scan range capped at {MAX_SCAN_HOSTS} hosts", level="warn")
    return hosts


async def _port_open(host: str, port: int, timeout: float = 0.6) -> bool:
    """Fast TCP reachability probe used to pre-filter hosts before an expensive
    protocol handshake."""
    try:
        fut = asyncio.open_connection(host, port)
        reader, writer = await asyncio.wait_for(fut, timeout=timeout)
        writer.close()
        try:
            await writer.wait_closed()
        except Exception:
            pass
        return True
    except Exception:
        return False


# ===========================================================================
# Receiver model
# ===========================================================================

AIRPLAY = "airplay"
DLNA = "dlna"
CAST = "cast"
HEOS = "heos"

PROTOCOL_LABELS = {AIRPLAY: "AirPlay", DLNA: "DLNA", CAST: "Google Cast",
                   HEOS: "HEOS"}


@dataclass
class Receiver:
    """A discovered network output. ``available`` means discovered and reachable;
    it does NOT by itself mean streaming will succeed — that is only known once a
    ``select`` actually connects and the backend validates playback support."""

    id: str                      # stable per-protocol identity (uuid / identifier / host)
    name: str
    protocol: str                # AIRPLAY | DLNA | CAST
    model: Optional[str] = None
    host: Optional[str] = None
    port: Optional[int] = None
    available: bool = True
    volume: Optional[float] = None       # 0..1, None if unknown/unsupported
    volume_supported: bool = False
    # Backend-specific handle kept out of the wire payload.
    handle: object = field(default=None, repr=False, compare=False)

    def wire(self) -> dict:
        d = asdict(self)
        d.pop("handle", None)
        d["protocol_label"] = PROTOCOL_LABELS.get(self.protocol, self.protocol)
        return d


# ===========================================================================
# Backend interface
# ===========================================================================

class OutputBackend:
    """Shared interface every protocol backend implements. Adding a new output
    (e.g. Sonos) means implementing this and registering it in ``BACKENDS``."""

    protocol = "base"

    def __init__(self, stream: "StreamServer") -> None:
        self.stream = stream

    async def discover(self, timeout: float, hosts: Optional[list[str]] = None) -> list[Receiver]:
        """Return receivers found within ``timeout`` seconds.

        ``hosts`` is an optional list of explicit IP addresses to probe directly
        (unicast), used to reach receivers on other VLANs/subnets that multicast
        discovery cannot see. Backends combine multicast results with unicast probes.
        """
        raise NotImplementedError

    async def connect(self, receiver: Receiver) -> None:
        """Establish a connection to the receiver. Raise on failure."""
        raise NotImplementedError

    async def start_stream(self, receiver: Receiver) -> None:
        """Begin continuous playback of the app's audio on the receiver."""
        raise NotImplementedError

    async def set_volume(self, receiver: Receiver, level: float) -> None:
        """Set volume 0..1 where supported; no-op otherwise."""
        return None

    async def seek(self, receiver: Receiver, position: float) -> None:
        """Seek to ``position`` seconds where the protocol supports it; no-op else."""
        return None

    async def transport(self, receiver: Receiver, action: str) -> None:
        """pause / resume / stop on the receiver where supported."""
        return None

    async def position(self, receiver: Receiver) -> Optional[tuple[float, float]]:
        """Return (current_seconds, duration_seconds) where supported, else None."""
        return None

    async def release(self, receiver: Receiver) -> None:
        """Stop playback and release the connection. Must be idempotent."""
        return None


# ---------------------------------------------------------------------------
# AirPlay (pyatv)
# ---------------------------------------------------------------------------

class AirPlayBackend(OutputBackend):
    protocol = AIRPLAY

    def __init__(self, stream: "StreamServer") -> None:
        super().__init__(stream)
        self._atv = None  # connected pyatv interface

    async def discover(self, timeout: float, hosts: Optional[list[str]] = None) -> list[Receiver]:
        try:
            import pyatv
            import ipaddress as _ipaddr
        except ImportError:
            log("pyatv not installed; AirPlay discovery skipped", level="warn")
            return []
        loop = asyncio.get_running_loop()
        configs = {}

        # Multicast scan for same-subnet devices.
        try:
            for conf in await pyatv.scan(loop, timeout=timeout):
                configs[conf.identifier] = conf
        except Exception as exc:
            log(f"AirPlay multicast scan error: {exc}", level="warn")

        # Unicast scan for explicit hosts (other VLANs). pyatv.scan accepts a hosts
        # list, but its unicast path relies on the device answering unicast mDNS on
        # UDP 5353. Many AirPlay receivers (e.g. Marantz/Denon AVRs) do NOT answer
        # unicast mDNS, so pyatv.scan returns nothing even though AirPlay is up. We run
        # pyatv's scan first, then fall back to a direct /info probe on the AirPlay
        # port for any host pyatv missed.
        probe_identifiers: dict[str, Receiver] = {}
        if hosts:
            try:
                addrs = [_ipaddr.ip_address(h) for h in hosts]
                for conf in await pyatv.scan(loop, hosts=addrs, timeout=timeout):
                    configs[conf.identifier] = conf
            except Exception as exc:
                log(f"AirPlay unicast scan error: {exc}", level="warn")

            scanned_hosts = {str(c.address) for c in configs.values() if c.address}
            missing = [h for h in hosts if h not in scanned_hosts]
            probes = await asyncio.gather(
                *[self._probe_info(h) for h in missing], return_exceptions=True)
            for res in probes:
                if isinstance(res, Receiver):
                    probe_identifiers[res.id] = res

        receivers: list[Receiver] = []
        for conf in configs.values():
            # Only surface devices that actually expose an audio-streaming service.
            services = {s.protocol for s in conf.services}
            try:
                from pyatv.const import Protocol
                has_stream = Protocol.AirPlay in services or Protocol.RAOP in services
            except Exception:
                has_stream = True
            if not has_stream:
                continue
            model = None
            try:
                model = conf.device_info.model_str or (
                    conf.device_info.model.name if conf.device_info.model else None)
            except Exception:
                pass
            receivers.append(Receiver(
                id=f"airplay:{conf.identifier}",
                name=conf.name,
                protocol=AIRPLAY,
                model=model,
                host=str(conf.address) if conf.address else None,
                available=True,
                volume_supported=True,
                handle=conf,
            ))
        # Add probe-only receivers that pyatv didn't surface, de-duped by device id.
        known = {r.id for r in receivers}
        for recv in probe_identifiers.values():
            if recv.id not in known:
                receivers.append(recv)
        return receivers

    # AirPlay receiver ports, in priority order. 7000 is the modern AirPlay 2 port.
    _AIRPLAY_PORTS = [7000, 7100, 5000]

    async def _probe_info(self, host: str) -> Optional[Receiver]:
        """Directly query an AirPlay receiver's ``GET /info`` endpoint to identify it
        without relying on mDNS. Returns a Receiver if the host speaks AirPlay."""
        import plistlib
        for port in self._AIRPLAY_PORTS:
            if not await _port_open(host, port, timeout=0.5):
                continue
            try:
                reader, writer = await asyncio.wait_for(
                    asyncio.open_connection(host, port), timeout=3.0)
            except Exception:
                continue
            try:
                req = (f"GET /info HTTP/1.1\r\nHost: {host}\r\n"
                       f"User-Agent: AirPlay/1\r\nConnection: close\r\n\r\n")
                writer.write(req.encode())
                await writer.drain()
                data = b""
                while len(data) < 65536:
                    chunk = await asyncio.wait_for(reader.read(8192), timeout=3.0)
                    if not chunk:
                        break
                    data += chunk
            except Exception:
                try:
                    writer.close()
                except Exception:
                    pass
                continue
            try:
                writer.close()
            except Exception:
                pass
            if b"AirTunes" not in data and b"application/x-apple-binary-plist" not in data:
                continue
            try:
                body = data.split(b"\r\n\r\n", 1)[1]
                pl = plistlib.loads(body)
            except Exception:
                continue
            # A stable id: prefer the device's own pi/deviceID over the host address so
            # the selection survives a DHCP lease change.
            ident = pl.get("pi") or pl.get("deviceID") or f"host-{host}"
            return Receiver(
                id=f"airplay:{ident}",
                name=pl.get("name") or f"AirPlay {host}",
                protocol=AIRPLAY,
                model=pl.get("model"),
                host=host,
                port=port,
                available=True,
                volume_supported=True,
                handle=None,  # forces connect() to resolve via pyatv using host
            )
        return None

    async def connect(self, receiver: Receiver) -> None:
        import pyatv
        import ipaddress as _ipaddr
        loop = asyncio.get_running_loop()
        conf = receiver.handle
        if conf is None:
            # Resolve a fresh config. Prefer a host-targeted scan (works for devices
            # that don't answer unicast mDNS, which is how we found them via /info);
            # fall back to an identifier scan for mDNS-discovered devices.
            results = []
            if receiver.host:
                try:
                    results = await pyatv.scan(
                        loop, hosts=[_ipaddr.ip_address(receiver.host)], timeout=5.0)
                except Exception:
                    results = []
            if not results:
                ident = receiver.id.split(":", 1)[1]
                results = await pyatv.scan(loop, identifier=ident, timeout=5.0)
            if not results:
                raise RuntimeError("AirPlay device no longer reachable")
            conf = results[0]
            receiver.handle = conf
        self._atv = await pyatv.connect(conf, loop)

    async def start_stream(self, receiver: Receiver) -> None:
        if self._atv is None:
            await self.connect(receiver)
        # Point pyatv at the selected file (full-rate) or the live tap stream.
        url = self.stream.playback_url()
        await self._atv.stream.stream_file(url)

    async def set_volume(self, receiver: Receiver, level: float) -> None:
        if self._atv is None:
            return
        try:
            await self._atv.audio.set_volume(max(0.0, min(1.0, level)) * 100.0)
            receiver.volume = level
        except Exception as exc:
            log(f"AirPlay volume not supported: {exc}", level="warn")

    async def release(self, receiver: Receiver) -> None:
        atv, self._atv = self._atv, None
        if atv is not None:
            try:
                atv.close()
            except Exception:
                pass


# ---------------------------------------------------------------------------
# DLNA / UPnP (async-upnp-client)
# ---------------------------------------------------------------------------

class DlnaBackend(OutputBackend):
    protocol = DLNA

    MEDIA_RENDERER = "urn:schemas-upnp-org:device:MediaRenderer:1"

    def __init__(self, stream: "StreamServer") -> None:
        super().__init__(stream)
        self._device = None
        self._profile = None

    async def discover(self, timeout: float, hosts: Optional[list[str]] = None) -> list[Receiver]:
        try:
            from async_upnp_client.search import async_search
            from async_upnp_client.utils import CaseInsensitiveDict  # noqa: F401
        except ImportError:
            log("async-upnp-client not installed; DLNA discovery skipped", level="warn")
            return []

        receivers: dict[str, Receiver] = {}

        async def _on_response(headers) -> None:
            location = headers.get("location") or headers.get("LOCATION")
            usn = headers.get("usn") or headers.get("USN") or location
            if not location or not usn:
                return
            udn = usn.split("::", 1)[0]
            if udn in receivers:
                return
            name, model, host, udn_desc = await self._describe(location)
            key = udn_desc or udn
            receivers[key] = Receiver(
                id=f"dlna:{key}",
                name=name or "DLNA Renderer",
                protocol=DLNA,
                model=model,
                host=host,
                available=True,
                volume_supported=True,
                handle=location,
            )

        # Multicast SSDP search for same-subnet renderers.
        try:
            await async_search(
                async_callback=_on_response,
                timeout=int(max(2, timeout)),
                search_target=self.MEDIA_RENDERER,
            )
        except Exception as exc:
            log(f"DLNA search error: {exc}", level="warn")

        # Unicast probing of explicit hosts (other VLANs). SSDP is multicast-only, so we
        # fetch the device description directly from the common UPnP description ports.
        if hosts:
            unicast = await self._probe_hosts(hosts, timeout)
            for recv in unicast:
                receivers.setdefault(recv.id, recv)

        return list(receivers.values())

    # Ports/paths commonly used to serve the UPnP root device description.
    # Ports commonly used to serve the UPnP root device description. 60006 and 8080 are
    # the Denon/Marantz HEOS description ports; AVRs nest a MediaRenderer under an
    # AiosDevice root served there.
    _DESC_PORTS = [60006, 8080, 8008, 49152, 49153, 49154, 1400, 80, 2869, 5000, 7676]
    _DESC_PATHS = [
        "/description.xml", "/dmr.xml", "/MediaRenderer.xml",
        "/upnp/desc/aios_device/aios_device.xml", "/rootDesc.xml",
        "/device/description.xml", "/",
    ]

    async def _probe_hosts(self, hosts: list[str], timeout: float) -> list[Receiver]:
        sem = asyncio.Semaphore(64)

        async def _probe(host: str) -> Optional[Receiver]:
            async with sem:
                # Quick TCP pre-filter so we don't attempt HTTP on dead ports.
                open_ports = []
                for port in self._DESC_PORTS:
                    if await _port_open(host, port, timeout=0.4):
                        open_ports.append(port)
                for port in open_ports:
                    for path in self._DESC_PATHS:
                        location = f"http://{host}:{port}{path}"
                        name, model, dev_host, udn = await self._describe(
                            location, want_renderer=True)
                        if name:
                            return Receiver(
                                id=f"dlna:{udn or host}",
                                name=name,
                                protocol=DLNA,
                                model=model,
                                host=host,
                                available=True,
                                volume_supported=True,
                                handle=location,
                            )
                return None

        results = await asyncio.gather(*[_probe(h) for h in hosts],
                                       return_exceptions=True)
        out = []
        for res in results:
            if isinstance(res, Receiver):
                out.append(res)
        return out

    async def _describe(self, location: str, want_renderer: bool = False):
        """Fetch the device description to get name, model, host, and UDN. When
        ``want_renderer`` is set, only return a device that is (or embeds) a
        MediaRenderer, so a unicast probe does not surface routers, printers, or media
        servers. HEOS/Denon/Marantz AVRs expose the renderer as an embedded sub-device
        under an AiosDevice root, so we check embedded devices too."""
        try:
            from async_upnp_client.aiohttp import AiohttpRequester
            from async_upnp_client.client_factory import UpnpFactory
            requester = AiohttpRequester(timeout=4)
            factory = UpnpFactory(requester)
            device = await factory.async_create_device(location)
            if want_renderer and not self._has_media_renderer(device):
                return None, None, None, None
            host = None
            try:
                from urllib.parse import urlparse
                host = urlparse(location).hostname
            except Exception:
                pass
            udn = getattr(device, "udn", None)
            return device.friendly_name, device.model_name, host, udn
        except Exception:
            return None, None, None, None

    @staticmethod
    def _has_media_renderer(device) -> bool:
        """True if the device itself is a MediaRenderer or embeds one (recursively)."""
        if "MediaRenderer" in (getattr(device, "device_type", "") or ""):
            return True
        # Some stacks expose AVTransport/RenderingControl as services directly.
        try:
            for svc in getattr(device, "services", {}) or {}:
                if "AVTransport" in svc or "RenderingControl" in svc:
                    return True
        except Exception:
            pass
        for embedded in getattr(device, "embedded_devices", {}).values() \
                if isinstance(getattr(device, "embedded_devices", None), dict) \
                else (getattr(device, "embedded_devices", []) or []):
            if DlnaBackend._has_media_renderer(embedded):
                return True
        return False

    async def connect(self, receiver: Receiver) -> None:
        from async_upnp_client.aiohttp import AiohttpRequester
        from async_upnp_client.client_factory import UpnpFactory
        from async_upnp_client.profiles.dlna import DmrDevice

        requester = AiohttpRequester()
        factory = UpnpFactory(requester)
        device = await factory.async_create_device(receiver.handle)
        self._device = device
        # The description root may be a container (e.g. HEOS AiosDevice) that embeds the
        # MediaRenderer. DmrDevice must wrap the actual renderer, so drill into it.
        renderer = self._find_renderer(device)
        if renderer is None:
            raise RuntimeError("No MediaRenderer in device description")
        self._profile = DmrDevice(renderer, event_handler=None)

    @staticmethod
    def _find_renderer(device):
        if "MediaRenderer" in (getattr(device, "device_type", "") or ""):
            return device
        emb = getattr(device, "embedded_devices", None)
        items = emb.values() if isinstance(emb, dict) else (emb or [])
        for child in items:
            found = DlnaBackend._find_renderer(child)
            if found is not None:
                return found
        return None

    async def start_stream(self, receiver: Receiver) -> None:
        if self._profile is None:
            await self.connect(receiver)
        url = self.stream.playback_url()
        # Set the transport URI to the selected file (or live stream) and play.
        await self._profile.async_set_transport_uri(
            url, "MusicStudio", meta_data=self.stream.playback_didl())
        await self._profile.async_play()

    async def set_volume(self, receiver: Receiver, level: float) -> None:
        if self._profile is None:
            return
        level = max(0.0, min(1.0, level))
        try:
            await self._profile.async_set_volume_level(level)
            receiver.volume = level
        except Exception as exc:
            # HEOS/Marantz drops idle HTTP keep-alive connections, so the requester's
            # socket may be stale between actions (ClientOSError/Connection reset).
            # Rebuild the device and retry once before treating volume as unsupported.
            if self._is_connection_error(exc):
                try:
                    await self.connect(receiver)
                    await self._profile.async_set_volume_level(level)
                    receiver.volume = level
                    return
                except Exception as exc2:
                    exc = exc2
            log(f"DLNA volume not supported: {exc}", level="warn")

    @staticmethod
    def _is_connection_error(exc: Exception) -> bool:
        text = f"{type(exc).__name__} {exc}".lower()
        return any(s in text for s in (
            "reset by peer", "clientoserror", "connection", "disconnected",
            "server disconnected", "timeout"))

    async def seek(self, receiver: Receiver, position: float) -> None:
        if self._profile is None:
            return
        # DLNA AVTransport Seek with REL_TIME in HH:MM:SS.
        h = int(position // 3600); m = int((position % 3600) // 60); s = int(position % 60)
        target = f"{h:02d}:{m:02d}:{s:02d}"
        try:
            await self._profile.async_seek_rel_time(
                __import__("datetime").timedelta(seconds=int(position)))
        except Exception:
            try:
                # Fall back to the raw Seek action if the helper isn't available.
                svc = self._profile._action("AVT", "Seek") if hasattr(self._profile, "_action") else None
                if svc:
                    await svc.async_call(InstanceID=0, Unit="REL_TIME", Target=target)
            except Exception as exc:
                log(f"DLNA seek not supported: {exc}", level="warn")

    async def transport(self, receiver: Receiver, action: str) -> None:
        if self._profile is None:
            return
        try:
            if action == "pause":
                await self._profile.async_pause()
            elif action == "resume":
                await self._profile.async_play()
            elif action == "stop":
                await self._profile.async_stop()
        except Exception as exc:
            log(f"DLNA transport {action} failed: {exc}", level="warn")

    async def position(self, receiver: Receiver):
        if self._profile is None:
            return None
        try:
            await self._profile.async_update()
            cur = self._profile.media_position
            dur = self._profile.media_duration
            if dur:
                return float(cur or 0), float(dur)
        except Exception:
            pass
        return None

    async def release(self, receiver: Receiver) -> None:
        profile, self._profile = self._profile, None
        self._device = None
        if profile is not None:
            try:
                await profile.async_stop()
            except Exception:
                pass


# ---------------------------------------------------------------------------
# Google Cast (pychromecast)
# ---------------------------------------------------------------------------

class CastBackend(OutputBackend):
    protocol = CAST

    def __init__(self, stream: "StreamServer") -> None:
        super().__init__(stream)
        self._cast = None
        self._browser = None

    async def discover(self, timeout: float, hosts: Optional[list[str]] = None) -> list[Receiver]:
        try:
            import pychromecast
        except ImportError:
            log("pychromecast not installed; Cast discovery skipped", level="warn")
            return []
        loop = asyncio.get_running_loop()

        def _blocking_scan():
            services, browser = pychromecast.discovery.discover_chromecasts(
                timeout=timeout)
            try:
                browser.stop_discovery()
            except Exception:
                pass
            return services

        found: dict[str, Receiver] = {}

        # Multicast mDNS scan for same-subnet Cast devices.
        try:
            for svc in await loop.run_in_executor(None, _blocking_scan):
                recv = self._receiver_from_service(svc)
                if recv:
                    found[recv.id] = recv
        except Exception as exc:
            log(f"Cast multicast scan error: {exc}", level="warn")

        # Unicast: connect directly to explicit hosts on the Cast port (8009) to reach
        # devices on other VLANs. Skip any host already found via multicast so we don't
        # re-probe a known device into a second, half-populated entry.
        if hosts:
            known_hosts = {r.host for r in found.values() if r.host}
            to_probe = [h for h in hosts if h not in known_hosts]
            unicast = await self._probe_hosts(to_probe)
            for recv in unicast:
                found.setdefault(recv.id, recv)

        return list(found.values())

    @staticmethod
    def _receiver_from_service(svc) -> Optional[Receiver]:
        try:
            if not svc.uuid:
                return None
            return Receiver(
                id=f"cast:{svc.uuid}",
                name=svc.friendly_name or f"Cast device ({svc.host})",
                protocol=CAST,
                model=svc.model_name,
                host=svc.host,
                port=svc.port,
                available=True,
                volume_supported=True,
                handle=str(svc.uuid),
            )
        except AttributeError:
            return None

    async def _probe_hosts(self, hosts: list[str]) -> list[Receiver]:
        import pychromecast
        loop = asyncio.get_running_loop()
        sem = asyncio.Semaphore(32)
        CAST_PORT = 8009

        async def _probe(host: str) -> Optional[Receiver]:
            async with sem:
                if not await _port_open(host, CAST_PORT, timeout=0.6):
                    return None

                def _blocking():
                    # get_chromecast_from_host wants (host, port, uuid, model, name).
                    # We don't know those yet, so use the lower-level host connection
                    # which fills them in from the device.
                    try:
                        from pychromecast import get_chromecast_from_host
                        cc = get_chromecast_from_host(
                            (host, CAST_PORT, None, None, None))
                        cc.wait(timeout=8)
                        info = cc.cast_info
                        cc.disconnect(timeout=3)
                        return info
                    except Exception:
                        return None

                info = await loop.run_in_executor(None, _blocking)
                if info is None:
                    return None
                # Require a real UUID; a connection that came up but couldn't report
                # its identity (e.g. a device that refused the Cast app) is not a
                # usable receiver and must not surface as a phantom entry.
                uuid = getattr(info, "uuid", None)
                if not uuid:
                    return None
                return Receiver(
                    id=f"cast:{uuid}",
                    name=getattr(info, "friendly_name", None) or f"Cast device ({host})",
                    protocol=CAST,
                    model=getattr(info, "model_name", None),
                    host=host,
                    port=CAST_PORT,
                    available=True,
                    volume_supported=True,
                    handle=str(uuid),
                )

        results = await asyncio.gather(*[_probe(h) for h in hosts],
                                       return_exceptions=True)
        return [r for r in results if isinstance(r, Receiver)]

    async def connect(self, receiver: Receiver) -> None:
        import pychromecast
        loop = asyncio.get_running_loop()
        uuid = receiver.id.split(":", 1)[1]

        def _blocking_connect():
            import uuid as uuidlib
            # Prefer a direct host connection when we know the host (works across VLANs
            # where mDNS-based get_listed_chromecasts would find nothing).
            if receiver.host:
                try:
                    from pychromecast import get_chromecast_from_host
                    cc = get_chromecast_from_host(
                        (receiver.host, receiver.port or 8009,
                         uuidlib.UUID(uuid), receiver.model, receiver.name))
                    cc.wait(timeout=10)
                    return cc, None
                except Exception as exc:
                    log(f"Cast direct connect failed, trying mDNS: {exc}", level="warn")
            chromecasts, browser = pychromecast.get_listed_chromecasts(
                uuids=[uuidlib.UUID(uuid)])
            if not chromecasts:
                browser.stop_discovery()
                raise RuntimeError("Cast device no longer reachable")
            cc = chromecasts[0]
            cc.wait(timeout=10)
            return cc, browser

        self._cast, self._browser = await loop.run_in_executor(None, _blocking_connect)

    async def start_stream(self, receiver: Receiver) -> None:
        if self._cast is None:
            await self.connect(receiver)
        loop = asyncio.get_running_loop()
        url = self.stream.playback_url()
        mime = self.stream.playback_mime()
        is_file = self.stream._file_path is not None

        def _blocking_play():
            mc = self._cast.media_controller
            # A selected file is a normal (seekable) track; the live tap is a LIVE
            # stream the receiver keeps pulling.
            mc.play_media(url, mime,
                          stream_type="BUFFERED" if is_file else "LIVE")
            mc.block_until_active(timeout=10)

        await loop.run_in_executor(None, _blocking_play)

    async def set_volume(self, receiver: Receiver, level: float) -> None:
        if self._cast is None:
            return
        loop = asyncio.get_running_loop()
        lvl = max(0.0, min(1.0, level))
        await loop.run_in_executor(None, self._cast.set_volume, lvl)
        receiver.volume = lvl

    async def seek(self, receiver: Receiver, position: float) -> None:
        if self._cast is None:
            return
        loop = asyncio.get_running_loop()
        await loop.run_in_executor(None, self._cast.media_controller.seek,
                                   max(0.0, position))

    async def transport(self, receiver: Receiver, action: str) -> None:
        if self._cast is None:
            return
        loop = asyncio.get_running_loop()
        mc = self._cast.media_controller
        fn = {"pause": mc.pause, "resume": mc.play, "stop": mc.stop}.get(action)
        if fn:
            await loop.run_in_executor(None, fn)

    async def position(self, receiver: Receiver):
        if self._cast is None:
            return None
        try:
            st = self._cast.media_controller.status
            if st and st.duration:
                return float(st.adjusted_current_time or st.current_time or 0), \
                    float(st.duration)
        except Exception:
            pass
        return None

    async def release(self, receiver: Receiver) -> None:
        cast, self._cast = self._cast, None
        browser, self._browser = self._browser, None
        loop = asyncio.get_running_loop()

        def _blocking_release():
            if cast is not None:
                try:
                    cast.media_controller.stop()
                except Exception:
                    pass
                try:
                    cast.quit_app()
                except Exception:
                    pass
                try:
                    cast.disconnect(timeout=5)
                except Exception:
                    pass
            if browser is not None:
                try:
                    browser.stop_discovery()
                except Exception:
                    pass

        await loop.run_in_executor(None, _blocking_release)


# ---------------------------------------------------------------------------
# Denon / Marantz HEOS (raw HEOS CLI over TCP 1255)
# ---------------------------------------------------------------------------

class HeosBackend(OutputBackend):
    """Denon/Marantz AVRs via the HEOS CLI protocol (newline-delimited JSON over
    TCP 1255). This is the reliable control path for these AVRs: AirPlay 2 to them
    needs ALAC (pyatv is PCM-only) and their DLNA MediaRenderer serves intermittently,
    but HEOS 'browse/play_stream' with our HTTP stream URL plays reliably and exposes
    volume/mute. Verified end to end against a Marantz SR6014 and CINEMA 50."""

    protocol = HEOS
    HEOS_PORT = 1255

    def __init__(self, stream: "StreamServer") -> None:
        super().__init__(stream)
        self._pid: Optional[int] = None

    async def _command(self, host: str, command: str, timeout: float = 5.0) -> str:
        """Open a short-lived HEOS CLI connection, send one command, return the reply."""
        reader, writer = await asyncio.wait_for(
            asyncio.open_connection(host, self.HEOS_PORT), timeout=timeout)
        try:
            writer.write((command + "\r\n").encode())
            await writer.drain()
            out = b""
            while b'"result"' not in out and b'"command"' not in out[:0]:
                try:
                    chunk = await asyncio.wait_for(reader.read(4096), timeout=timeout)
                except asyncio.TimeoutError:
                    break
                if not chunk:
                    break
                out += chunk
                if b'"result"' in out:
                    break
            return out.decode("utf-8", "replace")
        finally:
            writer.close()
            try:
                await writer.wait_closed()
            except Exception:
                pass

    async def discover(self, timeout: float, hosts: Optional[list[str]] = None) -> list[Receiver]:
        """Find HEOS players. We only probe explicit hosts (the HEOS CLI has no
        multicast discovery of its own); any HEOS AVR on the scan range is enumerated
        via one of its own get_players replies, which lists every player on the system."""
        if not hosts:
            return []
        # Probe hosts for an open HEOS port, then ask the first responsive one for the
        # full player list (HEOS returns all players on the network, not just itself).
        async def _probe(host: str) -> Optional[str]:
            if not await _port_open(host, self.HEOS_PORT, timeout=0.6):
                return None
            return host
        live = [h for h in await asyncio.gather(*[_probe(h) for h in hosts])
                if h is not None]
        if not live:
            return []
        players_json = ""
        for host in live:
            try:
                players_json = await self._command(
                    host, "heos://player/get_players", timeout=timeout)
                if '"result": "success"' in players_json:
                    break
            except Exception as exc:
                log(f"HEOS get_players {host} failed: {exc}", level="warn")
        receivers: list[Receiver] = []
        try:
            payload = json.loads(players_json).get("payload", [])
        except Exception:
            payload = []
        for p in payload:
            pid = p.get("pid")
            ip = p.get("ip")
            if pid is None or not ip:
                continue
            receivers.append(Receiver(
                id=f"heos:{pid}",
                name=p.get("name") or "HEOS player",
                protocol=HEOS,
                model=p.get("model"),
                host=ip,
                port=self.HEOS_PORT,
                available=True,
                volume_supported=True,
                handle=pid,
            ))
        return receivers

    async def connect(self, receiver: Receiver) -> None:
        self._pid = receiver.handle if isinstance(receiver.handle, int) \
            else int(receiver.id.split(":", 1)[1])
        # Verify the AVR is reachable and register for events (keeps the player
        # responsive). A failure here surfaces as a connect error to the UI.
        await self._command(receiver.host,
                             "heos://system/register_for_change_events?enable=on")

    async def start_stream(self, receiver: Receiver) -> None:
        if self._pid is None:
            await self.connect(receiver)
        url = self.stream.playback_url()
        resp = await self._command(
            receiver.host,
            f"heos://browse/play_stream?pid={self._pid}&url={url}")
        if '"result": "success"' not in resp:
            raise RuntimeError(f"HEOS refused the stream: {resp[:160]}")

    async def set_volume(self, receiver: Receiver, level: float) -> None:
        if self._pid is None:
            return
        lvl = int(round(max(0.0, min(1.0, level)) * 100))
        try:
            await self._command(
                receiver.host, f"heos://player/set_volume?pid={self._pid}&level={lvl}")
            receiver.volume = lvl / 100.0
        except Exception as exc:
            log(f"HEOS set volume failed: {exc}", level="warn")

    async def seek(self, receiver: Receiver, position: float) -> None:
        if self._pid is None:
            return
        ms = int(max(0.0, position) * 1000)
        # HEOS seeks within the current media by millisecond position.
        await self._command(
            receiver.host,
            f"heos://player/set_play_position?pid={self._pid}&position={ms}")

    async def transport(self, receiver: Receiver, action: str) -> None:
        if self._pid is None:
            return
        state = {"pause": "pause", "resume": "play", "stop": "stop"}.get(action)
        if not state:
            return
        await self._command(
            receiver.host,
            f"heos://player/set_play_state?pid={self._pid}&state={state}")

    async def position(self, receiver: Receiver):
        if self._pid is None:
            return None
        try:
            resp = await self._command(
                receiver.host,
                f"heos://player/get_now_playing_media?pid={self._pid}")
            # Progress arrives as an async event; parse cur_pos/duration if present.
            m = re.search(r"cur_pos=(\d+)&duration=(\d+)", resp)
            if m:
                return int(m.group(1)) / 1000.0, int(m.group(2)) / 1000.0
        except Exception:
            pass
        return None

    async def release(self, receiver: Receiver) -> None:
        pid, self._pid = self._pid, None
        if pid is None:
            return
        try:
            await self._command(
                receiver.host, f"heos://player/set_play_state?pid={pid}&state=stop")
        except Exception:
            pass


BACKENDS: dict[str, type[OutputBackend]] = {
    AIRPLAY: AirPlayBackend,
    DLNA: DlnaBackend,
    CAST: CastBackend,
    HEOS: HeosBackend,
}


# ===========================================================================
# PCM ingress + HTTP stream server
# ===========================================================================

@dataclass
class FeedFormat:
    sample_rate: int = 48000
    channels: int = 2
    bits: int = 16          # samples arriving from Swift are int16 interleaved


class PcmBuffer:
    """Thread-safe ring of recent PCM bytes fed by the Swift audio tap.

    The Swift AudioEngine opens a loopback TCP connection to ``feed_port`` and writes
    raw interleaved little-endian PCM. One producer (the feed socket), many consumers
    (one per active HTTP stream request). Each consumer gets a monotonically growing
    read cursor; we only retain a bounded tail so a slow/absent receiver cannot grow
    memory without limit.
    """

    def __init__(self, max_seconds: float, fmt: FeedFormat) -> None:
        self.fmt = fmt
        self._max_seconds = max_seconds
        self._lock = threading.Condition()
        self._chunks: list[bytes] = []
        self._base_offset = 0          # bytes discarded before _chunks[0]
        self._total = 0                # total bytes ever appended
        self._closed = False
        self._max_bytes = int(max_seconds * fmt.sample_rate
                              * fmt.channels * (fmt.bits // 8))

    def set_format(self, fmt: FeedFormat) -> None:
        """Update the format and recompute the byte budget in place. Does NOT swap the
        buffer object or drop the feed connection, so a format change can't break a
        live producer/consumer (which was a real bug when this replaced the object)."""
        with self._lock:
            self.fmt = fmt
            self._max_bytes = int(self._max_seconds * fmt.sample_rate
                                  * fmt.channels * (fmt.bits // 8))

    def append(self, data: bytes) -> None:
        with self._lock:
            if self._closed:
                return
            self._chunks.append(data)
            self._total += len(data)
            # Trim the front to stay within the bounded tail.
            buffered = self._total - self._base_offset
            while buffered > self._max_bytes and len(self._chunks) > 1:
                dropped = self._chunks.pop(0)
                self._base_offset += len(dropped)
                buffered -= len(dropped)
            self._lock.notify_all()

    def read_from(self, cursor: int, timeout: float = 1.0) -> tuple[bytes, int]:
        """Return (bytes, new_cursor) at or after ``cursor``. Blocks up to ``timeout``
        for new data. If the consumer fell behind the retained tail, it is fast-
        forwarded to the oldest available byte (a glitch, but keeps the stream live)."""
        with self._lock:
            if cursor < self._base_offset:
                cursor = self._base_offset
            end = time.monotonic() + timeout
            while cursor >= self._total and not self._closed:
                remaining = end - time.monotonic()
                if remaining <= 0:
                    return b"", cursor
                self._lock.wait(remaining)
            if self._closed and cursor >= self._total:
                return b"", cursor
            # Assemble everything from cursor to the current end.
            out = bytearray()
            pos = self._base_offset
            for chunk in self._chunks:
                chunk_end = pos + len(chunk)
                if chunk_end <= cursor:
                    pos = chunk_end
                    continue
                start = max(0, cursor - pos)
                out += chunk[start:]
                pos = chunk_end
            return bytes(out), self._total

    def close(self) -> None:
        with self._lock:
            self._closed = True
            self._lock.notify_all()

    def flush(self) -> None:
        """Discard all queued audio and advance the base offset to 'now'. Used on seek:
        the engine has moved the tapped PCM, so stale pre-seek samples must be dropped.
        Consumers reading after a flush see only fresh post-seek audio."""
        with self._lock:
            self._chunks.clear()
            self._base_offset = self._total
            self._lock.notify_all()


# A fake file size for the live stream, kept BELOW 2^31. Many renderer firmwares
# (Marantz/HEOS, older smart TVs) compute file sizes with signed 32-bit math and
# reject anything >= 2^31 (it reads as negative), which makes them report duration=0
# and stop. This value and the Range-request handling are the hard-won recipe from
# the mirrorcast-macos project, confirmed against the same class of devices.
FAKE_STREAM_SIZE = 1_900_000_000


def _wav_header(fmt: FeedFormat, data_size: int = FAKE_STREAM_SIZE - 36) -> bytes:
    """A streaming WAV header. The declared size is a large-but-finite value under 2^31
    so renderers treat it as a long playable file (not an endless/zero-length stream)
    without tripping signed-32-bit size math."""
    import struct
    byte_rate = fmt.sample_rate * fmt.channels * (fmt.bits // 8)
    block_align = fmt.channels * (fmt.bits // 8)
    return b"".join([
        b"RIFF", struct.pack("<I", data_size + 36), b"WAVE",
        b"fmt ", struct.pack("<IHHIIHH", 16, 1, fmt.channels,
                             fmt.sample_rate, byte_rate, block_align, fmt.bits),
        b"data", struct.pack("<I", data_size),
    ])


class StreamServer:
    """Owns the PCM ingress socket and an aiohttp server exposing ``/stream.wav``.

    DLNA and Cast receivers pull this URL. AirPlay is pointed at the same URL via
    pyatv. The URL host is the machine's LAN IP so receivers on the network can reach
    it (loopback would not be routable from the device)."""

    def __init__(self, loop: asyncio.AbstractEventLoop) -> None:
        self.loop = loop
        self.fmt = FeedFormat()
        self.buffer = PcmBuffer(max_seconds=30.0, fmt=self.fmt)
        # Pin the HTTP stream port so a firewall rule (e.g. OPNsense allowing the IoT
        # VLAN to reach this Mac) stays valid across launches. Overridable via env.
        try:
            self.preferred_port = int(os.environ.get("MUSICSTUDIO_NETAUDIO_PORT", "45655"))
        except ValueError:
            self.preferred_port = 45655
        self.http_port = 0
        self.feed_port = 0
        self._http_server: Optional[asyncio.AbstractServer] = None
        self._silence_cache: dict[int, bytes] = {}
        self._feed_thread: Optional[threading.Thread] = None
        self._feed_server: Optional[socket.socket] = None
        self._stop = threading.Event()
        from concurrent.futures import ThreadPoolExecutor
        self._io_pool = ThreadPoolExecutor(max_workers=8, thread_name_prefix="stream-io")
        # When set, the stream endpoint serves this file (file-based casting) instead
        # of the live PCM tap. This is the primary path: it plays an actual track at
        # full rate so the receiver never underruns, and local playback can be stopped.
        self._file_path: Optional[str] = None
        self._file_mime: str = "audio/mpeg"
        self._file_token: int = 0  # bumped per file so stale stream URLs 404

    # --- LAN address discovery ------------------------------------------------
    @staticmethod
    def lan_ip() -> str:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        try:
            # No packets are actually sent; this just picks the default-route iface.
            s.connect(("8.8.8.8", 80))
            return s.getsockname()[0]
        except Exception:
            return "127.0.0.1"
        finally:
            s.close()

    def wav_url(self) -> str:
        return f"http://{self.lan_ip()}:{self.http_port}/stream.wav"

    # --- file-based casting ---------------------------------------------------
    _MIME_BY_EXT = {
        ".mp3": "audio/mpeg", ".m4a": "audio/mp4", ".aac": "audio/aac",
        ".flac": "audio/flac", ".wav": "audio/wav", ".ogg": "audio/ogg",
    }

    def set_file(self, path: Optional[str]) -> None:
        """Serve ``path`` at /track from now on, or clear it. Bumps a token so a new
        selection invalidates any previous stream URL the receiver might retry."""
        self._file_path = path
        self._file_token += 1
        if path:
            import os as _os
            ext = _os.path.splitext(path)[1].lower()
            self._file_mime = self._MIME_BY_EXT.get(ext, "audio/mpeg")

    def file_url(self) -> str:
        return (f"http://{self.lan_ip()}:{self.http_port}"
                f"/track{self._file_token}{self._current_ext()}")

    def _current_ext(self) -> str:
        if not self._file_path:
            return ""
        import os as _os
        return _os.path.splitext(self._file_path)[1].lower()

    def file_didl(self, title: str) -> str:
        url = self.file_url()
        safe = (title.replace("&", "&amp;").replace("<", "&lt;")
                .replace(">", "&gt;"))
        return (
            '<DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" '
            'xmlns:dc="http://purl.org/dc/elements/1.1/" '
            'xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/">'
            '<item id="0" parentID="0" restricted="1">'
            f'<dc:title>{safe}</dc:title>'
            '<upnp:class>object.item.audioItem.musicTrack</upnp:class>'
            f'<res protocolInfo="http-get:*:{self._file_mime}:*">{url}</res>'
            '</item></DIDL-Lite>'
        )

    def didl_metadata(self) -> str:
        """Minimal DIDL-Lite so DLNA renderers accept the stream."""
        url = self.wav_url()
        return (
            '<DIDL-Lite xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" '
            'xmlns:dc="http://purl.org/dc/elements/1.1/" '
            'xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/">'
            '<item id="0" parentID="0" restricted="1">'
            '<dc:title>MusicStudio</dc:title>'
            '<upnp:class>object.item.audioItem.musicTrack</upnp:class>'
            f'<res protocolInfo="http-get:*:audio/wav:*">{url}</res>'
            '</item></DIDL-Lite>'
        )

    # --- unified playback URL/metadata ---------------------------------------
    def playback_url(self) -> str:
        """The URL a receiver should play: the selected file if one is set (primary,
        full-rate file casting), otherwise the live PCM tap stream (fallback)."""
        return self.file_url() if self._file_path else self.wav_url()

    def playback_mime(self) -> str:
        return self._file_mime if self._file_path else "audio/wav"

    def playback_didl(self, title: str = "MusicStudio") -> str:
        return self.file_didl(title) if self._file_path else self.didl_metadata()

    # --- feed socket (producer) ----------------------------------------------
    def set_format(self, sample_rate: int, channels: int, bits: int = 16) -> None:
        # Update format in place; never swap or close the buffer, so a format change
        # cannot tear the feed connection out from under a connected producer.
        self.fmt = FeedFormat(sample_rate=sample_rate, channels=channels, bits=bits)
        self.buffer.set_format(self.fmt)

    def _run_feed_server(self) -> None:
        srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        srv.bind(("127.0.0.1", 0))
        srv.listen(1)
        self.feed_port = srv.getsockname()[1]
        self._feed_server = srv
        srv.settimeout(1.0)
        log(f"PCM feed listening on 127.0.0.1:{self.feed_port}")
        while not self._stop.is_set():
            try:
                conn, _ = srv.accept()
            except socket.timeout:
                continue
            except OSError:
                break
            with conn:
                conn.settimeout(2.0)
                while not self._stop.is_set():
                    try:
                        data = conn.recv(16384)
                    except socket.timeout:
                        continue
                    except OSError:
                        break
                    if not data:
                        break
                    self.buffer.append(data)

    async def start(self) -> None:
        # Start the feed socket thread.
        self._feed_thread = threading.Thread(
            target=self._run_feed_server, name="pcm-feed", daemon=True)
        self._feed_thread.start()
        # Wait briefly for the port to be assigned.
        for _ in range(50):
            if self.feed_port:
                break
            await asyncio.sleep(0.02)

        # Raw asyncio HTTP server rather than aiohttp. aiohttp insists on chunked
        # transfer encoding for an unbounded StreamResponse, and HEOS/Marantz cannot
        # parse chunked audio (verified: it connects, reports duration=0, and stops).
        # A plain close-delimited HTTP/1.0-style response - exactly what
        # `python -m http.server` sent for the WAV that played - is what works, so we
        # write the response bytes ourselves with full control over framing.
        server = None
        for port in (self.preferred_port, 0):
            try:
                server = await asyncio.start_server(
                    self._handle_http_client, "0.0.0.0", port, reuse_address=True)
                break
            except OSError as exc:
                log(f"stream port {port} unavailable ({exc}); trying fallback",
                    level="warn")
        if server is None:
            raise RuntimeError("could not bind HTTP stream server")
        self._http_server = server
        self.http_port = server.sockets[0].getsockname()[1]
        log(f"HTTP stream on {self.wav_url()}")

    async def _handle_http_client(self, reader: asyncio.StreamReader,
                                  writer: asyncio.StreamWriter) -> None:
        """Serve one receiver's GET /stream.wav as a close-delimited audio/wav body."""
        try:
            # Read the request line + headers.
            try:
                request_line = await asyncio.wait_for(reader.readline(), timeout=5)
            except asyncio.TimeoutError:
                writer.close(); return
            if not request_line:
                writer.close(); return
            headers = {}
            while True:
                line = await asyncio.wait_for(reader.readline(), timeout=5)
                if line in (b"\r\n", b"\n", b""):
                    break
                if b":" in line:
                    k, _, v = line.partition(b":")
                    headers[k.strip().lower()] = v.strip()
            parts = request_line.split()
            method = parts[0] if parts else b"GET"
            path = parts[1] if len(parts) >= 2 else b""

            # Handshake logging (point 5): record every request a receiver makes to the
            # stream server, including Range probes, so the console shows the full
            # client<->server conversation.
            peer = writer.get_extra_info("peername")
            peer_s = f"{peer[0]}:{peer[1]}" if peer else "?"
            rng_hdr = headers.get(b"range", b"-").decode("latin1", "replace")
            ua = headers.get(b"user-agent", b"").decode("latin1", "replace")
            log(f"HTTP {method.decode('latin1','replace')} "
                f"{path.decode('latin1','replace')} from {peer_s} "
                f"Range={rng_hdr}" + (f" UA={ua}" if ua else ""),
                level="debug")

            # Range header (shared by both the file and live-stream paths).
            start, end = 0, None
            rng = headers.get(b"range")
            if rng:
                m = re.match(rb"bytes=(\d+)-(\d*)", rng.strip())
                if m:
                    start = int(m.group(1))
                    end = int(m.group(2)) if m.group(2) else None

            # File-based casting: /track* serves the currently selected audio file with
            # real byte ranges. This is the primary path (full-rate, no underrun).
            if path.startswith(b"/track"):
                await self._serve_file(method, start, end, writer)
                return

            if not path.startswith(b"/stream"):
                writer.write(b"HTTP/1.1 404 Not Found\r\n"
                             b"Content-Length: 0\r\nConnection: close\r\n\r\n")
                await writer.drain(); writer.close(); return

            common = (
                "Content-Type: audio/wav\r\n"
                "Accept-Ranges: bytes\r\n"
                "Cache-Control: no-cache, no-store\r\n"
                "Connection: close\r\n"
                "transferMode.dlna.org: Streaming\r\n"
                "contentFeatures.dlna.org: "
                "DLNA.ORG_OP=01;DLNA.ORG_CI=0;DLNA.ORG_FLAGS="
                "01700000000000000000000000000000\r\n"
            )
            if rng:
                eff_end = end if end is not None else FAKE_STREAM_SIZE - 1
                head = (
                    f"HTTP/1.1 206 Partial Content\r\n"
                    f"Content-Range: bytes {start}-{eff_end}/{FAKE_STREAM_SIZE}\r\n"
                    f"Content-Length: {eff_end - start + 1}\r\n" + common + "\r\n"
                ).encode("latin1")
            else:
                head = (
                    f"HTTP/1.1 200 OK\r\n"
                    f"Content-Length: {FAKE_STREAM_SIZE}\r\n" + common + "\r\n"
                ).encode("latin1")
            writer.write(head)
            if method == b"HEAD":
                await writer.drain(); writer.close(); return

            # Small bounded probe read (e.g. a tail check): answer with exactly that
            # many bytes from the WAV header + buffered audio, then close. The device
            # uses this to validate the format before committing to playback.
            if end is not None and (end - start + 1) <= 4 * 1024 * 1024:
                n = end - start + 1
                header = _wav_header(self.fmt)
                tail, _ = self.buffer.read_from(0, timeout=0.2)
                payload = (header + tail)
                if len(payload) >= n:
                    payload = payload[:n]
                else:
                    payload = payload + b"\x00" * (n - len(payload))
                writer.write(payload)
                await writer.drain(); writer.close(); return

            # Full stream. The WAV header counts as the first 44 bytes of the body, so
            # only send it when the device is requesting from byte 0.
            if start < 44:
                writer.write(_wav_header(self.fmt)[start:])
            await writer.drain()

            cursor = self.buffer._total  # start from "now" (live)
            while not self._stop.is_set():
                data, cursor = await self.loop.run_in_executor(
                    self._io_pool, self.buffer.read_from, cursor, 0.25)
                if not data:
                    # Engine paused/stalled: send real-time silence so the receiver's
                    # buffer doesn't underrun and drop the session.
                    data = self._silence(0.25)
                writer.write(data)
                await writer.drain()
        except (ConnectionResetError, BrokenPipeError, asyncio.CancelledError):
            pass
        except Exception as exc:
            log(f"stream client error: {exc}", level="warn")
        finally:
            try:
                writer.close()
            except Exception:
                pass

    def _silence(self, seconds: float) -> bytes:
        n = int(seconds * self.fmt.sample_rate) * self.fmt.channels * (self.fmt.bits // 8)
        buf = self._silence_cache.get(n)
        if buf is None:
            buf = b"\x00" * n
            self._silence_cache[n] = buf
        return buf

    async def _serve_file(self, method: bytes, start: int, end: Optional[int],
                          writer: asyncio.StreamWriter) -> None:
        """Serve the selected audio file with real HTTP Range support so the receiver
        gets a full-rate, seekable track (no underrun, no silence)."""
        import os as _os
        path = self._file_path
        if not path or not _os.path.isfile(path):
            writer.write(b"HTTP/1.1 404 Not Found\r\n"
                         b"Content-Length: 0\r\nConnection: close\r\n\r\n")
            await writer.drain(); writer.close(); return
        size = _os.path.getsize(path)
        if end is None or end >= size:
            end = size - 1
        if start >= size:
            start = 0
        length = end - start + 1
        # Always answer Range requests as 206; plain GET as 200.
        is_partial = start != 0 or end != size - 1
        head = (
            f"HTTP/1.1 {'206 Partial Content' if is_partial else '200 OK'}\r\n"
            f"Content-Type: {self._file_mime}\r\n"
            f"Content-Length: {length}\r\n"
            "Accept-Ranges: bytes\r\n"
            "Connection: close\r\n"
            "transferMode.dlna.org: Streaming\r\n"
            f"contentFeatures.dlna.org: http-get:*:{self._file_mime}:"
            "DLNA.ORG_OP=01;DLNA.ORG_CI=0;DLNA.ORG_FLAGS="
            "01700000000000000000000000000000\r\n"
        )
        if is_partial:
            head += f"Content-Range: bytes {start}-{end}/{size}\r\n"
        head += "\r\n"
        writer.write(head.encode("latin1"))
        if method == b"HEAD":
            await writer.drain(); writer.close(); return
        try:
            sent = 0
            t0 = time.monotonic()
            last_report = t0
            with open(path, "rb") as f:
                f.seek(start)
                remaining = length
                while remaining > 0 and not self._stop.is_set():
                    chunk = f.read(min(65536, remaining))
                    if not chunk:
                        break
                    writer.write(chunk)
                    await writer.drain()
                    remaining -= len(chunk)
                    sent += len(chunk)
                    # Emit transfer stats ~1/s so the UI can show real throughput and
                    # progress (point 5): bytes sent, rate, and percent of the file.
                    now = time.monotonic()
                    if now - last_report >= 1.0:
                        elapsed = now - t0
                        rate = sent / elapsed if elapsed > 0 else 0
                        emit("stats",
                             bytes_sent=sent,
                             total_bytes=length,
                             bytes_per_sec=int(rate),
                             percent=round(100.0 * (length - remaining) / length, 1),
                             mime=self._file_mime)
                        last_report = now
            # Final stat on completion.
            elapsed = max(1e-6, time.monotonic() - t0)
            emit("stats", bytes_sent=sent, total_bytes=length,
                 bytes_per_sec=int(sent / elapsed), percent=100.0,
                 mime=self._file_mime)
            log(f"file served: {sent} bytes in {elapsed:.1f}s "
                f"({sent/elapsed/1024:.0f} KiB/s)")
        except (ConnectionResetError, BrokenPipeError, asyncio.CancelledError):
            pass
        except Exception as exc:
            log(f"file serve error: {exc}", level="warn")
        finally:
            try:
                writer.close()
            except Exception:
                pass

    async def stop(self) -> None:
        self._stop.set()
        self.buffer.close()
        if self._feed_server is not None:
            try:
                self._feed_server.close()
            except Exception:
                pass
        if self._http_server is not None:
            try:
                self._http_server.close()
                await self._http_server.wait_closed()
            except Exception:
                pass


# ===========================================================================
# Controller
# ===========================================================================

class Controller:
    """Owns discovery, the active backend/receiver, status, and reconnection."""

    MAX_RECONNECT = 3
    RECONNECT_BACKOFF = [1.0, 2.0, 4.0]

    def __init__(self, loop: asyncio.AbstractEventLoop) -> None:
        self.loop = loop
        self.stream = StreamServer(loop)
        self.backends = {proto: cls(self.stream) for proto, cls in BACKENDS.items()}
        self.receivers: dict[str, Receiver] = {}
        self.active: Optional[Receiver] = None
        self.active_backend: Optional[OutputBackend] = None
        self.state = "idle"
        self.current_title: str = ""       # title of the track being cast
        self.scan_hosts: list[str] = []      # explicit unicast targets (cross-VLAN)
        self.scan_spec: str = ""             # raw user spec, for echoing back
        self._discover_task: Optional[asyncio.Task] = None
        self._monitor_task: Optional[asyncio.Task] = None
        # Disk cache of the last-seen receivers so the UI can show the list instantly
        # on launch instead of waiting ~30-50s for a fresh cross-VLAN scan (point 1).
        home = os.environ.get("MUSICSTUDIO_HOME") or os.path.expanduser("~/.MusicStudio")
        self._cache_path = os.path.join(home, "netaudio-receivers.json")

    def load_cache(self) -> None:
        """Publish the cached receiver list immediately (marked from cache) so the user
        sees receivers at launch while a fresh scan runs in the background."""
        try:
            with open(self._cache_path) as f:
                data = json.load(f)
        except Exception:
            return
        cached: dict[str, Receiver] = {}
        for d in data.get("receivers", []):
            try:
                cached[d["id"]] = Receiver(
                    id=d["id"], name=d["name"], protocol=d["protocol"],
                    model=d.get("model"), host=d.get("host"), port=d.get("port"),
                    available=d.get("available", True),
                    volume_supported=d.get("volume_supported", False))
            except Exception:
                continue
        if cached:
            self.receivers = cached
            self.publish_receivers()
            log(f"Loaded {len(cached)} receiver(s) from cache")

    def save_cache(self) -> None:
        try:
            os.makedirs(os.path.dirname(self._cache_path), exist_ok=True)
            with open(self._cache_path, "w") as f:
                json.dump({"receivers": [r.wire() for r in self.receivers.values()]}, f)
        except Exception as exc:
            log(f"receiver cache save failed: {exc}", level="debug")

    def set_scan_ranges(self, spec: str) -> None:
        self.scan_spec = spec or ""
        self.scan_hosts = parse_ip_ranges(self.scan_spec)
        if self.scan_hosts:
            log(f"Scan range set: {len(self.scan_hosts)} host(s) across VLANs")
        else:
            log("Scan range cleared; multicast (same-subnet) discovery only")

    # --- status ---------------------------------------------------------------
    def set_state(self, state: str, detail: str = "") -> None:
        self.state = state
        # Rich status so the player bar can show exactly what's casting: the receiver
        # name/model, the protocol in use, the track title, and volume. (UI point 5.)
        r = self.active
        emit("status", state=state,
             receiver_id=r.id if r else None,
             receiver_name=r.name if r else None,
             receiver_model=(r.model if r else None),
             protocol=(r.protocol if r else None),
             protocol_label=(PROTOCOL_LABELS.get(r.protocol, r.protocol) if r else None),
             host=(r.host if r else None),
             title=self.current_title,
             detail=detail,
             volume=r.volume if r else None)

    def publish_receivers(self) -> None:
        emit("receivers",
             receivers=[r.wire() for r in self.receivers.values()])

    # --- discovery ------------------------------------------------------------
    def discover(self, timeout: float = 5.0, force: bool = False) -> None:
        """Kick off a discovery pass as a background task. Never blocks the caller, so
        the command loop stays responsive to select/stop/volume while a scan (which can
        take tens of seconds across a /24) runs. If a scan is already in flight and
        ``force`` is set, it is superseded by a fresh one."""
        if self._discover_task and not self._discover_task.done():
            if not force:
                return
            self._discover_task.cancel()
        self._discover_task = asyncio.ensure_future(self._discover(timeout))

    async def _discover(self, timeout: float) -> None:
        scope = (f"multicast + {len(self.scan_hosts)} unicast host(s)"
                 if self.scan_hosts else "multicast (same subnet)")
        self.set_state(self.state, detail=f"Scanning for receivers ({scope})…")
        try:
            results = await asyncio.gather(
                *[self._safe_discover(b, timeout) for b in self.backends.values()],
                return_exceptions=True,
            )
        except asyncio.CancelledError:
            # Superseded by a newer scan (e.g. ranges changed); drop this one quietly.
            return
        found: dict[str, Receiver] = {}
        for res in results:
            if isinstance(res, Exception):
                log(f"discovery backend failed: {res}", level="warn")
                continue
            for recv in res:
                found[recv.id] = recv
        # Preserve the active receiver even if this scan round missed it, but mark it
        # unavailable so the UI can show it's gone without dropping the selection.
        if self.active and self.active.id not in found:
            self.active.available = False
            found[self.active.id] = self.active
        self.receivers = self._dedup_by_device(found)
        self.publish_receivers()
        self.save_cache()
        log(f"Discovery complete: {len(self.receivers)} receiver(s)")

    # A physical device can be discovered on several protocols (a Marantz shows up as
    # AirPlay + HEOS + sometimes DLNA; the Sony as Cast + DLNA). Only some of those
    # actually stream. Collapse duplicates by host, keeping the protocol most likely
    # to work so the UI never offers a receiver that silently fails.
    _PROTOCOL_PREFERENCE = {HEOS: 0, CAST: 1, DLNA: 2, AIRPLAY: 3}

    def _dedup_by_device(self, found: dict[str, Receiver]) -> dict[str, Receiver]:
        # Never collapse the active receiver away; keep whatever the user is using.
        active_id = self.active.id if self.active else None
        by_host: dict[str, Receiver] = {}
        passthrough: dict[str, Receiver] = {}
        for recv in found.values():
            if not recv.host:
                passthrough[recv.id] = recv
                continue
            best = by_host.get(recv.host)
            if best is None:
                by_host[recv.host] = recv
                continue
            # Prefer the active receiver, else the better-ranked protocol.
            if recv.id == active_id:
                by_host[recv.host] = recv
            elif best.id != active_id and (
                    self._PROTOCOL_PREFERENCE.get(recv.protocol, 9)
                    < self._PROTOCOL_PREFERENCE.get(best.protocol, 9)):
                by_host[recv.host] = recv
        result: dict[str, Receiver] = {}
        for recv in list(by_host.values()) + list(passthrough.values()):
            result[recv.id] = recv
        return result

    async def _safe_discover(self, backend: OutputBackend, timeout: float):
        try:
            return await backend.discover(timeout, hosts=self.scan_hosts or None)
        except Exception as exc:
            log(f"{backend.protocol} discovery error: {exc}", level="warn")
            return []

    # --- selection / streaming ------------------------------------------------
    async def select(self, receiver_id: str, path: Optional[str] = None,
                     title: str = "") -> None:
        receiver = self.receivers.get(receiver_id)
        if receiver is None:
            emit("error", message=f"Unknown receiver {receiver_id}")
            return
        # Release any current output first.
        await self.stop(publish=False)
        self.active = receiver
        self.active_backend = self.backends[receiver.protocol]
        # Set the file BEFORE starting, so the backend starts exactly one stream with
        # the right content (fixes the play->stop->restart on first select, which was
        # caused by starting once with no file then again with the file).
        if path:
            self.stream.set_file(path)
            self.current_title = title or os.path.basename(path)
        self.set_state("connecting", detail=f"Connecting to {receiver.name}…")
        log(f"[{receiver.protocol}] connect {receiver.name} @ {receiver.host}")
        try:
            await self.active_backend.connect(receiver)
            log(f"[{receiver.protocol}] connected; starting stream → {self.stream.playback_url()}")
            await self.active_backend.start_stream(receiver)
        except Exception as exc:
            self.set_state("error", detail=f"Could not stream to {receiver.name}: {exc}")
            emit("error", message=f"Streaming to {receiver.name} failed: {exc}")
            self.active = None
            self.active_backend = None
            return
        self.set_state("streaming", detail=f"Streaming to {receiver.name}")
        self._start_monitor()

    async def play_file(self, path: Optional[str], title: str = "") -> None:
        """Change the track on the already-active receiver. If the receiver slept (or the
        session otherwise died) the existing connection is stale, so a plain start_stream
        fails; we then rebuild the pipeline (release → connect → start_stream) once so the
        play action always reactivates streaming."""
        self.stream.set_file(path)
        self.current_title = title or (os.path.basename(path) if path else "")
        if self.active is None or self.active_backend is None:
            return
        try:
            log(f"[{self.active.protocol}] play_file → {self.stream.playback_url()}")
            await self.active_backend.start_stream(self.active)
            self.set_state("streaming", detail=f"Streaming to {self.active.name}")
        except Exception as exc:
            # Stale session (e.g. renderer slept). Rebuild the connection and retry once.
            log(f"[{self.active.protocol}] play_file failed on existing session ({exc}); "
                f"reactivating pipeline", level="warn")
            self.set_state("connecting", detail=f"Reconnecting to {self.active.name}…")
            try:
                await self.active_backend.release(self.active)
            except Exception as rel_exc:
                log(f"[{self.active.protocol}] release before retry failed: {rel_exc}", level="warn")
            try:
                await self.active_backend.connect(self.active)
                await self.active_backend.start_stream(self.active)
                self.set_state("streaming", detail=f"Streaming to {self.active.name}")
            except Exception as exc2:
                self.set_state("error", detail=f"Playback failed: {exc2}")
                emit("error", message=f"Could not play on {self.active.name}: {exc2}")

    async def seek(self, position: float, token: int = 0) -> None:
        """Seek the active session. For a file-backed receiver this is a native seek.
        For a LIVE tap stream there is no seekable media on the receiver: the engine
        has already moved the tapped PCM, so we flush the bounded buffer (discard
        stale pre-seek samples) and restart the receiver session so it pulls fresh
        audio from the new position. Emits seek_ack(token) on completion."""
        if self.active is None or self.active_backend is None:
            emit("seek_ack", token=token)
            return
        is_live = self.stream._file_path is None
        try:
            if is_live:
                # Discard queued samples so the receiver doesn't replay the old position.
                self.stream.buffer.flush()
                # Restart the receiver's stream session to resync to the flushed buffer.
                await self.active_backend.start_stream(self.active)
            else:
                await self.active_backend.seek(self.active, position)
        except Exception as exc:
            log(f"seek failed: {exc}", level="warn")
        emit("seek_ack", token=token)

    async def transport(self, action: str) -> None:
        """pause / resume / stop on the active remote session."""
        if self.active is None or self.active_backend is None:
            return
        try:
            await self.active_backend.transport(self.active, action)
            if action == "pause":
                self.set_state("paused", detail=f"Paused on {self.active.name}")
            elif action == "resume":
                self.set_state("streaming", detail=f"Streaming to {self.active.name}")
        except Exception as exc:
            log(f"transport {action} failed: {exc}", level="warn")

    def _start_monitor(self) -> None:
        if self._monitor_task and not self._monitor_task.done():
            self._monitor_task.cancel()
        self._monitor_task = asyncio.ensure_future(self._monitor())

    async def _monitor(self) -> None:
        """Watch the active receiver; attempt bounded reconnection on failure."""
        attempt = 0
        while self.active is not None and self.state == "streaming":
            await asyncio.sleep(3.0)
            if self.active is None:
                return
            alive = await self._check_alive()
            if alive:
                attempt = 0
                continue
            if attempt >= self.MAX_RECONNECT:
                self.set_state("error",
                               detail=f"Lost {self.active.name}; giving up after "
                                      f"{self.MAX_RECONNECT} attempts")
                await self.stop()
                return
            backoff = self.RECONNECT_BACKOFF[min(attempt, len(self.RECONNECT_BACKOFF) - 1)]
            attempt += 1
            self.set_state("reconnecting",
                           detail=f"Reconnecting to {self.active.name} "
                                  f"(attempt {attempt}/{self.MAX_RECONNECT})…")
            await asyncio.sleep(backoff)
            try:
                await self.active_backend.release(self.active)
                await self.active_backend.connect(self.active)
                await self.active_backend.start_stream(self.active)
                self.set_state("streaming", detail=f"Reconnected to {self.active.name}")
                attempt = 0
            except Exception as exc:
                log(f"reconnect attempt {attempt} failed: {exc}", level="warn")

    async def _check_alive(self) -> bool:
        if self.active is None or self.active_backend is None:
            return False
        host = self.active.host
        if not host:
            return True  # can't probe; assume alive
        # Probe a protocol-appropriate port. A None/Cast-default port was making DLNA
        # and AirPlay sessions look dead every cycle, causing a reconnect flap.
        port = self._probe_port()
        if port is None:
            return True
        try:
            fut = asyncio.open_connection(host, port)
            _, writer = await asyncio.wait_for(fut, timeout=2.0)
            writer.close()
            try:
                await writer.wait_closed()
            except Exception:
                pass
            return True
        except Exception:
            return False

    def _probe_port(self) -> Optional[int]:
        """The TCP port that indicates the active receiver is still reachable."""
        r = self.active
        if r is None:
            return None
        if r.protocol == CAST:
            return r.port or 8009
        if r.protocol == AIRPLAY:
            return r.port or 7000
        if r.protocol == HEOS:
            return r.port or 1255
        if r.protocol == DLNA:
            # Use the port from the device description URL (the handle), e.g. 60006 for
            # HEOS/Marantz. Fall back to the explicit port or skip probing.
            if isinstance(r.handle, str) and r.handle.startswith("http"):
                try:
                    from urllib.parse import urlparse
                    p = urlparse(r.handle).port
                    if p:
                        return p
                except Exception:
                    pass
            return r.port
        return r.port

    async def set_volume(self, level: float) -> None:
        if self.active is None or self.active_backend is None:
            return
        try:
            await self.active_backend.set_volume(self.active, level)
            self.set_state(self.state, detail=f"Volume {int(level * 100)}%")
        except Exception as exc:
            log(f"set volume failed: {exc}", level="warn")

    async def stop(self, publish: bool = True) -> None:
        if self._monitor_task:
            self._monitor_task.cancel()
            self._monitor_task = None
        if self.active and self.active_backend:
            try:
                await self.active_backend.release(self.active)
            except Exception as exc:
                log(f"release failed: {exc}", level="warn")
        self.active = None
        self.active_backend = None
        if publish:
            self.set_state("stopped", detail="Output stopped")

    async def shutdown(self) -> None:
        await self.stop(publish=False)
        await self.stream.stop()


# ===========================================================================
# stdin command loop
# ===========================================================================

async def command_loop(controller: Controller) -> None:
    loop = asyncio.get_running_loop()
    reader = asyncio.StreamReader()
    protocol = asyncio.StreamReaderProtocol(reader)
    await loop.connect_read_pipe(lambda: protocol, sys.stdin)

    while True:
        line = await reader.readline()
        if not line:
            break  # stdin closed -> parent gone
        text = line.decode("utf-8", "replace").strip()
        if not text:
            continue
        try:
            msg = json.loads(text)
        except json.JSONDecodeError:
            emit("error", message=f"Bad command: {text[:120]}")
            continue
        cmd = msg.get("cmd")
        try:
            if cmd == "discover":
                # An optional range can be supplied inline with the discover command.
                if "ranges" in msg:
                    controller.set_scan_ranges(str(msg.get("ranges") or ""))
                # Non-blocking: starts a background scan so the loop keeps handling
                # select/stop/volume commands while discovery runs.
                controller.discover(float(msg.get("timeout", 5.0)), force=True)
            elif cmd == "scan_ranges":
                controller.set_scan_ranges(str(msg.get("ranges") or ""))
            elif cmd == "select":
                await controller.select(msg["id"], msg.get("path"),
                                        str(msg.get("title") or ""))
            elif cmd == "play_file":
                await controller.play_file(msg.get("path"),
                                           str(msg.get("title") or ""))
            elif cmd == "seek":
                await controller.seek(float(msg.get("position", 0.0)),
                                      int(msg.get("token", 0)))
            elif cmd == "transport":
                await controller.transport(str(msg.get("action", "")))
            elif cmd == "set_title":
                controller.current_title = str(msg.get("title") or "")
                controller.set_state(controller.state)
            elif cmd == "stop":
                await controller.stop()
            elif cmd == "set_volume":
                await controller.set_volume(float(msg.get("level", 0.5)))
            elif cmd == "feed_format":
                controller.stream.set_format(
                    int(msg.get("sample_rate", 48000)),
                    int(msg.get("channels", 2)),
                    int(msg.get("bits", 16)))
                emit("ready", stream_port=controller.stream.http_port,
                     feed_port=controller.stream.feed_port)
            elif cmd == "shutdown":
                break
            else:
                emit("error", message=f"Unknown command: {cmd}")
        except Exception as exc:
            emit("error", message=f"Command '{cmd}' failed: {exc}")

    await controller.shutdown()


async def amain() -> None:
    loop = asyncio.get_running_loop()
    controller = Controller(loop)
    await controller.stream.start()
    emit("ready",
         stream_port=controller.stream.http_port,
         feed_port=controller.stream.feed_port)
    # Point 1: publish cached receivers instantly, then refresh in the background so
    # the list is populated at launch without waiting for a full scan.
    controller.load_cache()
    controller.discover(5.0)
    await command_loop(controller)


def main() -> int:
    parser = argparse.ArgumentParser(description="MusicStudio network audio sidecar")
    parser.add_argument("netaudio", nargs="?", help="(ignored positional for parity)")
    parser.parse_args()
    try:
        asyncio.run(amain())
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
