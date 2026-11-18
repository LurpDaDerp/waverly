"""Tests for checking tasks off from the page (hud/core.py task-complete, hud/gcal.py complete_task),
and for what hud-core's refresh loops push to the page.

hud-core runs for real behind its /ws (on a free port); Google is a fake aiohttp server
on another free port (token refresh, task lists, PATCH). Made-up fixtures, no network.

Run:  python3 tests/test_tasks_complete.py      (from hud/, with the venv active)
"""
import asyncio
import datetime as dt
import json
import os
import sys
import tempfile
import time
from pathlib import Path

_TMP = tempfile.mkdtemp(prefix="waverly-test-")
os.environ["HUD_STATE"] = _TMP  # before importing hud: nothing may touch the real state folder
os.environ["HUD_CONFIG"] = str(Path(_TMP) / "config.json")
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "python"))

import aiohttp  # noqa: E402
from aiohttp import web  # noqa: E402

from hud import core as core_mod  # noqa: E402
from hud import gcal  # noqa: E402
from hud.common import merge_config, system_tz  # noqa: E402

READ_SCOPES = ["https://www.googleapis.com/auth/calendar.readonly", "https://www.googleapis.com/auth/tasks.readonly"]
FULL_SCOPES = ["https://www.googleapis.com/auth/calendar.readonly", "https://www.googleapis.com/auth/tasks"]


def sign_in(scopes):
    """Made-up credential files in the temporary state folder."""
    (Path(_TMP) / "google_client.json").write_text(json.dumps({"client_id": "test-client", "client_secret": ""}))
    (Path(_TMP) / "google_token.json").write_text(json.dumps({"refresh_token": "test-refresh", "scopes": scopes}))


def today():
    return dt.datetime.now(system_tz()).date()


def tasks_l1():
    """Google's answer for task list L1: one due today (both lists), one undated (right list only)."""
    return [{"id": "t1", "title": "Water the plants", "position": "1", "due": f"{today()}T00:00:00.000Z"},
            {"id": "t2", "title": "Someday task", "position": "2"}]


class FakeGoogle:
    """Token endpoint, task lists and tasks; PATCH answers come from `patch_plan` (status codes)."""

    def __init__(self):
        self.tokens = 0
        self.patches = []      # (path, json body, Authorization header)
        self.patch_plan = []   # statuses for the next PATCHes (then 200)
        self.reject_token = None   # a token value the PATCH answers 401 to
        self.patch_delay = 0       # seconds each PATCH takes
        self.listed = tasks_l1()
        self.runner = None
        self.base = ""

    async def token(self, request):
        form = await request.post()
        assert form["grant_type"] == "refresh_token" and form["refresh_token"] == "test-refresh"
        self.tokens += 1
        return web.json_response({"access_token": f"AT{self.tokens}", "expires_in": 3600})

    async def patch(self, request):
        body = await request.json()
        auth = request.headers.get("Authorization", "")
        self.patches.append((request.raw_path, body, auth))
        await asyncio.sleep(self.patch_delay)
        if self.reject_token and auth == f"Bearer {self.reject_token}":
            return web.json_response({"error": {"code": 401}}, status=401)
        status = self.patch_plan.pop(0) if self.patch_plan else 200
        if status == 403:
            return web.json_response({"error": {"message": "Request had insufficient authentication scopes."}}, status=403)
        if status != 200:
            return web.json_response({"error": {"code": status}}, status=status)
        return web.json_response({"id": request.match_info["task"], "status": "completed"})

    async def calendars(self, request):
        return web.json_response({"items": []})

    async def lists(self, request):
        return web.json_response({"items": [{"id": "L1", "title": "Inbox"}]})

    async def tasks(self, request):
        return web.json_response({"items": self.listed})   # Google may still list a task just completed

    async def start(self):
        app = web.Application()
        app.router.add_post("/token", self.token)
        app.router.add_patch("/tasks/v1/lists/{list}/tasks/{task}", self.patch)
        app.router.add_get("/tasks/v1/users/@me/lists", self.lists)
        app.router.add_get("/tasks/v1/lists/{list}/tasks", self.tasks)
        app.router.add_get("/calendar/v3/users/me/calendarList", self.calendars)
        self.runner = web.AppRunner(app, access_log=None)
        await self.runner.setup()
        site = web.TCPSite(self.runner, "127.0.0.1", 0)
        await site.start()
        port = site._server.sockets[0].getsockname()[1]
        self.base = f"http://127.0.0.1:{port}"
        gcal.TOKEN_URL, gcal.TASKS, gcal.CAL = f"{self.base}/token", f"{self.base}/tasks/v1", f"{self.base}/calendar/v3"

    async def stop(self):
        await self.runner.cleanup()


class Harness:
    """hud-core with fake Google data already fetched, serving /ws on a free port."""

    async def __aenter__(self):
        self.google = FakeGoogle()
        await self.google.start()
        self.core = c = core_mod.Core()
        c.session = aiohttp.ClientSession()
        c.cfg = merge_config({"lists": {"left": {"sources": ["tasks:L1"]}, "right": {"sources": ["tasks:L1"]}}})
        c.google_client()
        c.raw = {"fetched_at": time.time(), "tz": system_tz().key, "calendars": [],
                 "tasklists": [{"id": "L1", "name": "Inbox"}], "today": {}, "upcoming": {},
                 "tasks": {"tasks:L1": gcal._order_tasks(tasks_l1())}}
        c.data.update(google={"state": "ok"}, google_at=time.time())
        c.recompose()
        app = web.Application(middlewares=[c.guard])
        app.router.add_get("/ws", c.ws_ui)
        self.runner = web.AppRunner(app, access_log=None)
        await self.runner.setup()
        site = web.TCPSite(self.runner, "127.0.0.1", 0)
        await site.start()
        c.port = site._server.sockets[0].getsockname()[1]
        self.client = aiohttp.ClientSession()
        self.ws = await self.client.ws_connect(f"http://127.0.0.1:{c.port}/ws")
        first = await self.recv("data")
        assert first["google"]["state"] == "ok"
        self.first = first
        return self

    async def __aexit__(self, *a):
        await self.ws.close()
        await self.client.close()
        await self.runner.cleanup()
        await self.core.session.close()
        await self.google.stop()

    async def recv(self, t, timeout=5):
        """The next message of type `t` (others are skipped)."""
        end = time.monotonic() + timeout
        while True:
            m = await asyncio.wait_for(self.ws.receive(), max(0.01, end - time.monotonic()))
            d = json.loads(m.data)
            if d.get("t") == t:
                return d

    async def recv_any(self, *types, timeout=5):
        end = time.monotonic() + timeout
        while True:
            m = await asyncio.wait_for(self.ws.receive(), max(0.01, end - time.monotonic()))
            d = json.loads(m.data)
            if d.get("t") in types:
                return d

    async def complete(self, list_id="L1", task_id="t1"):
        await self.ws.send_json({"t": "task-complete", "list": list_id, "task": task_id})


def task_ids(data):
    L = data["lists"]
    return ([("left", t["list"], t["task"]) for t in L["left"]["tasks"]]
            + [("right", i["list"], i["task"]) for i in L["right"]["items"] if i["kind"] == "task"])


def run(coro):
    return asyncio.run(coro)


# ---------------------------------------------------------------------- tests
def test_page_gets_ids_and_can_complete():
    sign_in(FULL_SCOPES)

    async def go():
        async with Harness() as h:
            assert h.first["google"]["can_complete"] is True
            assert task_ids(h.first) == [("left", "L1", "t1"), ("right", "L1", "t1"), ("right", "L1", "t2")]
    run(go())


def test_patch_request_and_success():
    sign_in(FULL_SCOPES)

    async def go():
        async with Harness() as h:
            await h.complete("L1", "t1")
            data = await h.recv("data")
            done = await h.recv("task-done")
            assert (done["list"], done["task"]) == ("L1", "t1")
            (path, body, auth), = h.google.patches
            assert path == "/tasks/v1/lists/L1/tasks/t1" and body == {"status": "completed"}
            assert auth == "Bearer AT1" and h.google.tokens == 1
            assert task_ids(data) == [("right", "L1", "t2")]      # gone from both lists
            assert ("L1", "t1") in h.core.recently_done
            cached = json.loads((Path(_TMP) / "cache.json").read_text())["google_raw"]["tasks"]["tasks:L1"]
            assert [t["id"] for t in cached] == ["t2"]               # and from the cache on disk
    run(go())


def test_ids_are_quoted_in_the_url():
    sign_in(FULL_SCOPES)

    async def go():
        async with Harness() as h:
            await h.core.google_client().complete_task("a/b?c", "x y")
            (path, body, _), = h.google.patches
            assert path == "/tasks/v1/lists/a%2Fb%3Fc/tasks/x%20y", path
    run(go())


def test_unknown_ids_refused_without_a_request():
    sign_in(FULL_SCOPES)

    async def go():
        async with Harness() as h:
            for list_id, task_id in (("L1", "nope"), ("L2", "t1"), ("L1", "e:ev1"), ("L1", None), (None, "t1"),
                                     (["L1"], "t1"), ("L1", "x" * 500)):
                await h.complete(list_id, task_id)
                err = await h.recv("task-error")
                assert err["reason"] == "unknown", (list_id, task_id, err)
                assert err["message"]
            assert h.google.patches == [] and h.google.tokens == 0
            assert len(task_ids(h.core.page_data())) == 3
    run(go())


def test_not_resurrected_by_a_refresh():
    sign_in(FULL_SCOPES)

    async def go():
        async with Harness() as h:
            await h.complete("L1", "t1")
            await h.recv("task-done")
            # The regular refresh: Google still lists t1 for a while; it must stay off the lists.
            h.core.google_force = True
            before = h.core.data["google_at"]
            loop = asyncio.ensure_future(h.core.google_loop())
            try:
                for _ in range(100):
                    await asyncio.sleep(0.05)
                    if h.core.data["google_at"] != before:
                        break
                assert h.core.data["google_at"] != before, "the refresh did not run"
            finally:
                loop.cancel()
            assert [t["id"] for t in h.google.listed] == ["t1", "t2"]
            assert task_ids(h.core.page_data()) == [("right", "L1", "t2")]
            # Long after, a task Google still lists (un-completed there) shows again.
            h.core.recently_done[("L1", "t1")] -= core_mod.RECENTLY_DONE_S + 1
            raw = h.core.without_done({"tasks": {"tasks:L1": gcal._order_tasks(tasks_l1())}})
            assert [t["id"] for t in raw["tasks"]["tasks:L1"]] == ["t1", "t2"]
            assert h.core.recently_done == {}
    run(go())


def test_reopened_task_shows_again():
    sign_in(FULL_SCOPES)

    async def go():
        async with Harness() as h:
            await h.complete("L1", "t1")
            await h.recv("task-done")
            # Google has caught up (t1 no longer listed): nothing left to hide.
            h.core.raw = h.core.without_done({"tasks": {"tasks:L1": gcal._order_tasks(tasks_l1()[1:])}})
            assert h.core.recently_done == {}
            # Reopened in Google a minute later: it shows at the next refresh.
            raw = h.core.without_done({"tasks": {"tasks:L1": gcal._order_tasks(tasks_l1())}})
            assert [t["id"] for t in raw["tasks"]["tasks:L1"]] == ["t1", "t2"]
            # A list that wasn't fetched says nothing: the task stays hidden meanwhile.
            h.core.recently_done[("L1", "t1")] = time.time()
            h.core.without_done({"tasks": {}})
            assert ("L1", "t1") in h.core.recently_done
    run(go())


def test_slow_google_answers_in_time():
    sign_in(FULL_SCOPES)

    async def go():
        saved = core_mod.COMPLETE_TIMEOUT_S
        core_mod.COMPLETE_TIMEOUT_S = 0.5
        try:
            async with Harness() as h:
                h.google.patch_delay = 3
                t0 = time.monotonic()
                await h.complete("L1", "t1")
                err = await h.recv("task-error")
                assert err["reason"] == "offline" and time.monotonic() - t0 < 2.5
                assert ("left", "L1", "t1") in task_ids(h.core.page_data())
                assert h.core.completing == set()
        finally:
            core_mod.COMPLETE_TIMEOUT_S = saved
        # and the cap stays well under the page's wait for an answer (app.js SENT_MS)
        # (the page next to the Python package: inside the app bundle too, where python/ may be a link)
        js = ((Path(__file__).resolve().parents[1] / "python").resolve().parent / "ui" / "app.js").read_text()
        sent_ms = int(js.split("SENT_MS = ", 1)[1].split(",", 1)[0])
        assert core_mod.COMPLETE_TIMEOUT_S * 1000 + 10000 <= sent_ms
    run(go())


def test_failures_keep_the_task():
    sign_in(FULL_SCOPES)

    async def go():
        async with Harness() as h:
            for status, reason in ((500, "offline"), (403, "scope"), (404, "gone")):
                h.google.patch_plan = [status]
                h.core.google_force = False
                await h.complete("L1", "t1")
                err = await h.recv("task-error")
                assert (err["list"], err["task"], err["reason"]) == ("L1", "t1", reason), (status, err)
                assert err["message"] == core_mod.TASK_ERRORS[reason]
                assert ("left", "L1", "t1") in task_ids(h.core.page_data())
                assert h.core.recently_done == {}
                if status == 404:
                    assert h.core.google_force           # lists fetched again at once
            # Google unreachable altogether.
            gcal.TASKS = "http://127.0.0.1:9/tasks/v1"
            await h.complete("L1", "t1")
            err = await h.recv("task-error", timeout=25)
            assert err["reason"] == "offline"
            assert ("left", "L1", "t1") in task_ids(h.core.page_data())
    run(go())


def test_missing_scope_refused():
    sign_in(READ_SCOPES)   # signed in before tasks could be checked off: tasks.readonly only

    async def go():
        async with Harness() as h:
            assert h.first["google"]["can_complete"] is False
            await h.complete("L1", "t1")
            err = await h.recv("task-error")
            assert err["reason"] == "scope" and "Sign in again" in err["message"]
            assert h.google.patches == [] and h.google.tokens == 0
            # Signing in again with the new scope: allowed from then on (the token file changed).
            await asyncio.sleep(0.01)
            sign_in(FULL_SCOPES)
            os.utime(Path(_TMP) / "google_token.json", (time.time() + 5, time.time() + 5))
            assert h.core.can_complete() is True
    run(go())


def test_token_refresh_on_401():
    sign_in(FULL_SCOPES)

    async def go():
        async with Harness() as h:
            h.core.google_client()._access, h.core.google_client()._access_exp = "STALE", time.time() + 3000
            h.google.reject_token = "STALE"
            await h.complete("L1", "t1")
            await h.recv("task-done")
            assert [a for _, _, a in h.google.patches] == ["Bearer STALE", "Bearer AT1"]
            assert h.google.tokens == 1
    run(go())


def test_foreign_origin_refused():
    sign_in(FULL_SCOPES)

    async def go():
        async with Harness() as h:
            try:
                await h.client.ws_connect(f"http://127.0.0.1:{h.core.port}/ws", headers={"Origin": "https://example.com"})
                raise AssertionError("a web page's Origin was accepted")
            except aiohttp.WSServerHandshakeError as e:
                assert e.status == 403
    run(go())


async def refresh(h, timeout=5):
    """One forced Google refresh by the real google_loop (left running; cancel it when done)."""
    before = h.core.data["google_at"]
    h.core.google_force = True
    h.core.kick_google.set()
    end = time.monotonic() + timeout
    while h.core.data["google_at"] == before:
        assert time.monotonic() < end, "the refresh did not run"
        await asyncio.sleep(0.02)


async def no_message(h, t="data", wait=0.4):
    try:
        d = await h.recv(t, timeout=wait)
        raise AssertionError(f"unexpected {t}: {str(d)[:200]}")
    except asyncio.TimeoutError:
        pass


def test_unchanged_refresh_not_pushed():
    sign_in(FULL_SCOPES)

    async def go():
        async with Harness() as h:
            loop = asyncio.ensure_future(h.core.google_loop())
            try:
                await refresh(h)
                await h.recv("data")                      # the first refresh is pushed
                saved = (Path(_TMP) / "cache.json").stat().st_mtime_ns
                await refresh(h)                          # the same lists again: no push, no cache write
                await no_message(h)
                assert (Path(_TMP) / "cache.json").stat().st_mtime_ns == saved
                # A check-off still pushes its data, then answers task-done.
                await h.complete("L1", "t1")
                data = await h.recv_any("data", "task-done")
                assert data["t"] == "data" and task_ids(data) == [("right", "L1", "t2")]
                await h.recv("task-done")
                await refresh(h)                          # Google still lists t1: nothing new for the page
                await no_message(h)
                h.google.listed = tasks_l1() + [{"id": "t3", "title": "New task", "position": "3"}]
                await refresh(h)                          # a real change is pushed
                data = await h.recv("data")
                assert ("right", "L1", "t3") in task_ids(data)
                # A new sign-in that allows checking off is pushed even with the same lists.
                sign_in(READ_SCOPES)
                os.utime(Path(_TMP) / "google_token.json", (time.time() + 5, time.time() + 5))
                await refresh(h)
                assert (await h.recv("data"))["google"]["can_complete"] is False
                # A page that connects now still gets the data at once.
                ws2 = await h.client.ws_connect(f"http://127.0.0.1:{h.core.port}/ws")
                first = json.loads((await ws2.receive(timeout=5)).data)
                assert first["t"] == "data" and ("right", "L1", "t3") in task_ids(first)
                await ws2.close()
            finally:
                loop.cancel()
    run(go())


def test_fetch_across_midnight_refetches():
    sign_in(FULL_SCOPES)

    async def go():
        async with Harness() as h:
            c, day, fetches = h.core, ["2026-11-17"], []
            c.today = lambda: day[0]
            g = c.google_client()
            real_fetch = g.fetch

            async def fetch(cfg, tz):
                fetches.append(day[0])
                raw = await real_fetch(cfg, tz)
                if len(fetches) == 1:
                    day[0] = "2026-11-18"                 # midnight passes while Google answers
                return raw
            g.fetch = fetch
            loop = asyncio.ensure_future(c.google_loop())
            try:
                for _ in range(100):
                    await asyncio.sleep(0.02)
                    if fetches and c.data["google_at"] != h.first["google_at"]:
                        break
                c.kick_google.set()                       # the next pass (the loop's own wait is 20 s)
                for _ in range(100):
                    await asyncio.sleep(0.02)
                    if len(fetches) == 2:
                        break
                assert fetches == ["2026-11-17", "2026-11-18"], fetches   # the new day is fetched at once
            finally:
                loop.cancel()
    run(go())


def test_stale_weather_dropped():
    sign_in(FULL_SCOPES)

    async def go():
        c = core_mod.Core()
        c.cfg = merge_config({"lat": 40.0, "lon": -74.0, "temperature_unit": "fahrenheit", "wind_unit": "mph"})
        c.data["weather"] = None
        pushed, started, release = [], asyncio.Event(), asyncio.Event()

        async def to_ui(payload, clients=None):
            d = json.loads(payload)
            if d.get("t") == "data":
                pushed.append((d["weather"] or {}).get("units"))

        async def fetch_weather(s, key):
            started.set()
            await release.wait()
            return {"fetched_at": time.time(), "key": key, "units": {"temperature": key[2], "wind": key[3]}}
        c.to_ui, c.fetch_weather = to_ui, fetch_weather
        loop = asyncio.ensure_future(c.weather_loop(None))
        try:
            await asyncio.wait_for(started.wait(), 5)
            started.clear()
            # Units switched while that fetch is in flight: its answer must never reach the page.
            metric = {"lat": 40.0, "lon": -74.0, "temperature_unit": "celsius", "wind_unit": "kmh"}
            await c.apply_config(merge_config(metric))
            release.set()
            await asyncio.wait_for(started.wait(), 5)
            for _ in range(100):
                await asyncio.sleep(0.01)
                if (c.data["weather"] or {}).get("units"):
                    break
            assert pushed == [None, {"temperature": "celsius", "wind": "kmh"}], pushed
        finally:
            loop.cancel()
    run(go())


def test_word_and_fact_dated_by_request():
    """Stamped with the day they were asked for, even if midnight passes meanwhile."""
    class Resp:
        def __init__(self, body, after):
            self.body, self.after = body, after

        async def __aenter__(self):
            return self

        async def __aexit__(self, *a):
            pass

        def raise_for_status(self):
            pass

        async def text(self):
            self.after()
            return self.body

        async def json(self):
            self.after()
            return self.body

    class Session:
        def __init__(self, body, after):
            self.body, self.after, self.urls = body, after, []

        def get(self, url, **kw):
            self.urls.append(url)
            return Resp(self.body, self.after)

    c = core_mod.Core()
    day = ["2026-11-17"]
    c.today = lambda: day[0]
    rss = ("<rss><item><title><![CDATA[sample]]></title><description><![CDATA[<p><em>sample</em> \\SAM-pul\\ "
           "&#149; <em>noun</em></p><br /><p>A made-up definition.</p>]]></description></item></rss>")
    s = Session(rss, lambda: day.__setitem__(0, "2026-11-18"))
    w = run(c.fetch_word(s))
    assert w["word"] == "sample" and w["date"] == "2026-11-17", w
    fact = "a made-up fact long enough to be picked for the page, written only for this test?"
    s = Session({"dyk": [{"text": "... that " + fact}]}, lambda: day.__setitem__(0, "2099-01-01"))
    f = run(c.fetch_fact(s))
    asked = s.urls[0].rsplit("/featured/", 1)[1].replace("/", "-")
    assert f["date"] == asked and f["text"].startswith("A made-up fact"), (f, asked)


def test_tasks_writable():
    sign_in(FULL_SCOPES)
    assert gcal.tasks_writable()
    sign_in(READ_SCOPES)
    assert not gcal.tasks_writable()
    (Path(_TMP) / "google_token.json").write_text(json.dumps({"refresh_token": "test-refresh"}))
    assert not gcal.tasks_writable()
    assert gcal.SCOPES[1] == gcal.TASKS_WRITE == "https://www.googleapis.com/auth/tasks"


def main():
    tests = [(n, f) for n, f in sorted(globals().items()) if n.startswith("test_") and callable(f)]
    failed = 0
    saved = gcal.TOKEN_URL, gcal.TASKS, gcal.CAL
    for name, fn in tests:
        try:
            fn()
            print("PASS", name)
        except Exception:  # noqa: BLE001
            failed += 1
            import traceback
            print("FAIL", name)
            traceback.print_exc()
        finally:
            gcal.TOKEN_URL, gcal.TASKS, gcal.CAL = saved
    print(f"\n{len(tests) - failed}/{len(tests)} passed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
