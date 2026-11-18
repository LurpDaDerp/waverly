"""Stand-in for the macOS app's side of the protocol (overlay window + keyboard).

Connects to hud-core's /ws like the Swift app, prints every message the app
would act on, and answers overlay requests the way the app must:
    {"t":"overlay","show":true}   -> (show window) -> {"t":"overlay-ready"}
    {"t":"overlay","show":false}  -> (hide window) -> {"t":"overlay-hidden"}
Optional: --force-wake N / --force-sleep N send keyboard wake/close after N s.
    python3 tools/fake_app.py --port 47780 --seconds 20
"""
import argparse
import asyncio
import json
import time

import aiohttp

ap = argparse.ArgumentParser()
ap.add_argument("--port", type=int, default=47780)
ap.add_argument("--seconds", type=float, default=20)
ap.add_argument("--force-wake", type=float)
ap.add_argument("--force-sleep", type=float)
a = ap.parse_args()


async def main():
    t0 = time.monotonic()
    log = lambda *x: print(f"{time.monotonic() - t0:6.2f}", *x, flush=True)  # noqa: E731
    async with aiohttp.ClientSession() as s:
        async with s.ws_connect(f"http://127.0.0.1:{a.port}/ws") as ws:
            async def timers():
                for at, awake in ((a.force_wake, True), (a.force_sleep, False)):
                    if at is not None:
                        await asyncio.sleep(max(0, at - (time.monotonic() - t0)))
                        log("APP  keyboard", "wake" if awake else "close")
                        await ws.send_json({"t": "force", "awake": awake})
            asyncio.ensure_future(timers())
            while time.monotonic() - t0 < a.seconds:
                try:
                    m = await asyncio.wait_for(ws.receive(), 0.5)
                except asyncio.TimeoutError:
                    continue
                if m.type != aiohttp.WSMsgType.TEXT:
                    break
                d = json.loads(m.data)
                t = d.get("t")
                if t == "overlay":
                    if d.get("prepare"):
                        log("APP  prepare (wake display if asleep)")
                    elif d.get("show"):
                        log("APP  show overlay window")
                        await asyncio.sleep(0.15)  # window ordered front + one display frame
                        await ws.send_json({"t": "overlay-ready"})
                    else:
                        log("APP  hide overlay window")
                        await ws.send_json({"t": "overlay-hidden"})
                elif t in ("wake", "sleep", "state", "camera-want"):
                    log("MSG ", d)
                elif t == "scroll" and d.get("kind") == "end":
                    log("MSG  scroll end", d.get("target"))
                elif t == "vstat":
                    pass

asyncio.run(main())
