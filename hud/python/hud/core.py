"""hud-core: serves the Waverly page, gathers its data, and relays vision events.

Update policy (polite to every API):
  weather   Open-Meteo, cached 30 min. Fetched on launch, on wake when the
            cache is stale, and every 30 min while the HUD is on screen.
            Never while the HUD is asleep, except once right after the
            location, units or time zone change. No location: no weather.
            Failures retry every 2 min on screen.
  google    every 5 min, plus on wake if older than 2 min, plus at midnight,
            plus at once when the lists' sources, keywords or look-ahead (or the
            Mac's time zone) change. A fetch that changes nothing the page shows
            is not pushed (and the cache is rewritten only now and then).
  word/fact once per day, retry every 15 min until it succeeds.

Checking off a task: the page sends {"t": "task-complete", "list", "task"} on /ws
(once its undo window has passed). Only a task in the lists the page was sent
can be completed, and only with a sign-in that allows it (gcal.tasks_writable).
hud-core marks it completed at Google, drops it from the cached data and pushes
fresh data, then answers that page {"t": "task-done", "list", "task"}; when
anything goes wrong, {"t": "task-error", "list", "task", "reason", "message"}
(reason: scope | unknown | auth | gone | offline) and the page shows the task
again. A task completed here stays out of the lists while Google still returns
it (Google can lag), for up to RECENTLY_DONE_S.

config.json (written by the macOS app) is re-read at once when the app says it
saved it ({"t": "config-changed"} on /ws), and within 2 s of any other change.
Appearance and gesture settings (theme, parallax, weather animation and
detail, open / close animation, scroll reversal) only re-push the page's data:
no network.
"""
from __future__ import annotations

import asyncio
import datetime as dt
import html
import json
import re
import time

import aiohttp
from aiohttp import web
from yarl import URL

from .common import (CONFIG_FILE, PALETTE, STATE, UI_DIR, ConfigError, file_stamp, load_config, read_json, sd_notify,
                     setup_logging, system_tz, system_tz_name, watch_parent, write_json_atomic)
from .gcal import (CLIENT_FILE, TOKEN_FILE, AuthError, Forbidden, Google, NotFound, assign_colors, compose,
                   effective_color, fetch_signature, list_title, read_obj, source_defaults, tasks_writable)

log = setup_logging("core")
UA = "Waverly/1.0 (+https://github.com/LurpDaDerp/Waverly)"
WEATHER_TTL = 30 * 60
COLORS_FILE = STATE / "source_colors.json"
CACHE_FILE = STATE / "cache.json"
LOCAL_HOSTS = ("127.0.0.1", "localhost")
RECENTLY_DONE_S = 10 * 60   # a checked-off task stays hidden this long, while Google still returns it
COMPLETE_TIMEOUT_S = 40     # longest a check-off may take (token refresh and retries included)
# What the page says when a task can't be checked off (task-error "message").
TASK_ERRORS = {
    "scope": "Sign in again in Waverly Settings to check off tasks.",
    "unknown": "This task changed. Try again in a moment.",
    "auth": "Google needs you to sign in again.",
    "gone": "This task changed in Google. Refreshing.",
    "offline": "Couldn't reach Google. Try again.",
}
# Settings the page applies itself, live (validated in common.merge_config).
PAGE_PREFS = ("theme", "parallax", "weather_animation", "weather_detail", "open_animation_s", "close_animation_s",
              "open_animation", "close_animation", "scroll_speed_vertical", "scroll_speed_horizontal", "scroll_reverse_vertical", "scroll_reverse_horizontal")


def page_config(cfg: dict) -> dict:
    """The part of config.json the page needs."""
    return {"name": cfg["name"].strip(), "place": cfg["place"].strip(), "lat": cfg["lat"], "lon": cfg["lon"],
            "temperature_unit": cfg["temperature_unit"], "wind_unit": cfg["wind_unit"], "clock": cfg["clock"],
            "titles": {"left": list_title(cfg, "left"), "right": list_title(cfg, "right")},
            "countdowns": cfg["lists"]["right"]["countdowns"],
            **{k: cfg[k] for k in PAGE_PREFS}}


def local_request(host: str | None, origin: str | None, port: int) -> bool:
    """True for requests from this Mac's own clients. The Host must be loopback (a web
    page using DNS rebinding sends its own domain), and a browser Origin must be the
    page's own: any website may open ws://127.0.0.1/ws, and would read the calendar.
    Native clients (the app, hud-engine) send no Origin."""
    if (host or "").lower().rsplit(":", 1)[0] not in LOCAL_HOSTS:  # "127.0.0.1:47780" -> "127.0.0.1"
        return False
    if origin is None:
        return True
    try:
        u = URL(origin)
        return u.scheme == "http" and (u.host or "").lower() in LOCAL_HOSTS and u.port == port
    except ValueError:
        return False


def weather_key(cfg: dict, tz_name: str):
    """What a weather fetch depends on; None without a location. The position is
    rounded to ~10 km (all that is ever sent, for privacy)."""
    if cfg["lat"] is None or cfg["lon"] is None:
        return None
    return [round(cfg["lat"], 1), round(cfg["lon"], 1), cfg["temperature_unit"], cfg["wind_unit"], tz_name]


def same_fetch(a, b) -> bool:
    """Whether two Google fetches hold the same data (fetched_at aside)."""
    strip = lambda r: {k: v for k, v in r.items() if k != "fetched_at"} if isinstance(r, dict) else r  # noqa: E731
    return strip(a) == strip(b)


class Core:
    def __init__(self):
        self.cfg_stamp = file_stamp(CONFIG_FILE)  # before reading, so a write meanwhile is noticed
        self.cfg = load_config()
        self.port = self.cfg["http_port"]     # changes apply on restart
        self.ui: set[web.WebSocketResponse] = set()
        self.ui_status: set[web.WebSocketResponse] = set()  # clients that want the engine's vstat (app, ?debug page)
        self.vision: web.WebSocketResponse | None = None
        self.session: aiohttp.ClientSession | None = None
        self.awake = False
        self.last_ui_hb = 0.0
        self.last_vision = 0.0
        self.vstat = {}
        self.kick_weather = asyncio.Event()
        self.kick_config = asyncio.Event()   # the app saved config.json: re-read it now
        self.kick_google = asyncio.Event()
        self.google = None            # Google client for the current credential files
        self.google_stamp = None
        self.google_force = False     # refetch at once (config or credentials changed)
        self.google_backoff = 0.0
        self.writable_stamp, self.writable = None, False  # tasks_writable(), per token file version
        self.recently_done: dict[tuple[str, str], float] = {}  # (list, task) -> when it was completed
        self.completing: set[tuple[str, str]] = set()
        self.jobs: set[asyncio.Task] = set()
        self.pushed = None    # the last data pushed to the page, as JSON without google_at
        self.saved_at = 0.0
        colors = read_json(COLORS_FILE, {})
        self.colors = colors if isinstance(colors, dict) else {}
        cache = read_json(CACHE_FILE, {})
        cache = cache if isinstance(cache, dict) else {}
        configured = Google.configured()
        self.raw = cache.get("google_raw") if configured and isinstance(cache.get("google_raw"), dict) else None
        self.composed_day = None
        self.data = {
            "config": page_config(self.cfg),
            "palette": [{"id": p["id"], "dark": p["dark"], "light": p["light"]} for p in PALETTE],
            "google": {"state": "loading" if configured else "setup"},
            "lists": None,
            "weather": cache.get("weather"),
            "word": cache.get("word"),
            "fact": cache.get("fact"),
            "google_at": cache.get("google_at", 0) if self.raw else 0,
        }
        self.recompose()

    # ------------------------------------------------------------------ plumbing
    def save(self):
        keep = {k: self.data.get(k) for k in ("weather", "word", "fact", "google_at")}
        keep["google_raw"] = self.raw
        try:
            write_json_atomic(CACHE_FILE, keep)
            self.saved_at = time.time()
        except OSError as e:
            log.warning("could not save cache: %s", e)

    def can_complete(self) -> bool:
        """Whether tasks may be checked off: Google connected with a sign-in that allows it."""
        if not Google.configured():
            return False
        st = file_stamp(TOKEN_FILE)
        if st != self.writable_stamp:
            self.writable_stamp, self.writable = st, tasks_writable()
        return self.writable

    def page_data(self) -> dict:
        return {**self.data, "google": {**self.data["google"], "can_complete": self.can_complete()}}

    async def push(self):
        self.save()
        data = self.page_data()
        self.pushed = json.dumps({**data, "google_at": None})  # the page doesn't show google_at
        await self.to_ui(json.dumps({"t": "data", **data}))

    def page_changed(self) -> bool:
        """Whether the page would see anything new in a push (google_at aside)."""
        return json.dumps({**self.page_data(), "google_at": None}) != self.pushed

    async def to_ui(self, payload: str, clients=None):
        for ws in list(self.ui if clients is None else clients & self.ui):
            try:
                await ws.send_str(payload)
            except Exception:
                self.ui.discard(ws)

    async def to_vision(self, d):
        if self.vision is not None and not self.vision.closed:
            try:
                await self.vision.send_json(d)
            except Exception:
                pass

    def today(self):
        return dt.datetime.now(system_tz()).date().isoformat()

    # ------------------------------------------------------------------ config
    async def config_loop(self):
        """Apply config.json changes live, and notice new or removed Google credentials
        at once (the macOS app writes both)."""
        bad_stamp = None
        while True:
            try:
                await asyncio.wait_for(self.kick_config.wait(), 2)
            except asyncio.TimeoutError:
                pass
            self.kick_config.clear()
            st = file_stamp(CONFIG_FILE)
            if st != self.cfg_stamp and st != bad_stamp:
                try:
                    new = load_config(strict=True)
                except ConfigError as e:  # keep the last good config until the file is fixed
                    log.error("config.json unreadable, keeping the current settings: %s", e)
                    bad_stamp = st
                else:
                    self.cfg_stamp, bad_stamp = st, None
                    await self.apply_config(new)
            if self.google_credentials_changed():
                self.kick_google.set()

    async def apply_config(self, new: dict):
        old, self.cfg = self.cfg, new
        if new == old:
            return
        if fetch_signature(new) != fetch_signature(old):
            self.google_force = True
            self.kick_google.set()
        tz = system_tz_name()
        key = weather_key(new, tz)
        if key != weather_key(old, tz):
            w = self.data.get("weather")
            if not isinstance(w, dict) or w.get("key") != key:
                self.data["weather"] = None  # never show the old place or units; refetched at once
            self.kick_weather.set()
        if new["http_port"] != old["http_port"]:
            log.info("http_port changes take effect when Waverly restarts")
        log.info("config reloaded")
        self.data["config"] = page_config(new)
        self.recompose()
        await self.push()

    # ------------------------------------------------------------------ weather
    async def fetch_weather(self, s: aiohttp.ClientSession, key):
        lat, lon, temp_unit, wind_unit, tz_name = key
        params = {
            "latitude": lat, "longitude": lon, "timezone": tz_name,
            "temperature_unit": temp_unit, "wind_speed_unit": wind_unit,
            "precipitation_unit": "inch" if temp_unit == "fahrenheit" else "mm",
            "forecast_days": 2,
            "current": "temperature_2m,apparent_temperature,weather_code,cloud_cover,wind_speed_10m,"
                       "precipitation,relative_humidity_2m,is_day",
            "hourly": "temperature_2m,weather_code,precipitation_probability,cloud_cover,is_day",
            "daily": "temperature_2m_max,temperature_2m_min,precipitation_probability_max,sunrise,sunset",
        }
        async with s.get("https://api.open-meteo.com/v1/forecast", params=params,
                         timeout=aiohttp.ClientTimeout(total=25)) as r:
            r.raise_for_status()
            d = await r.json()
        return {"fetched_at": time.time(), "key": key, "units": {"temperature": temp_unit, "wind": wind_unit},
                "current": d["current"], "hourly": d["hourly"], "daily": d["daily"]}

    async def weather_loop(self, s):
        tried_key, last_try = None, 0.0
        while True:
            self.kick_weather.clear()  # a kick that arrives during this pass runs another one at once
            key = weather_key(self.cfg, system_tz_name())
            w = self.data.get("weather")
            if w is not None and (not isinstance(w, dict) or w.get("key") != key):
                # Location, units or time zone changed (or no location): never show stale numbers.
                self.data["weather"] = w = None
                await self.push()
            if key is not None:
                # Once per new key (also at launch) even while asleep, else only on screen.
                first = key != tried_key
                tried_key = key
                age = time.time() - (w or {}).get("fetched_at", 0)
                if age >= WEATHER_TTL and (first or (self.awake and time.time() - last_try > 120)):
                    last_try = time.time()
                    try:
                        fresh = await self.fetch_weather(s, key)
                        # Location or units changed meanwhile: drop it (the kick fetches the new key).
                        if weather_key(self.cfg, system_tz_name()) == key:
                            self.data["weather"] = fresh
                            log.info("weather updated")
                            await self.push()
                    except Exception as e:
                        log.warning("weather fetch failed: %s", str(e) or type(e).__name__)
            try:
                await asyncio.wait_for(self.kick_weather.wait(), 30)
            except asyncio.TimeoutError:
                pass

    # ------------------------------------------------------------------ word & fact
    async def fetch_word(self, s):
        day = self.today()  # the day asked for, even if midnight passes during the request
        async with s.get("https://www.merriam-webster.com/wotd/feed/rss2",
                         timeout=aiohttp.ClientTimeout(total=25)) as r:
            r.raise_for_status()
            xml = await r.text()
        item = xml.split("<item>", 1)[1]
        word = re.search(r"<title><!\[CDATA\[(.*?)\]\]></title>", item, re.S).group(1).strip()
        desc = re.search(r"<description><!\[CDATA\[(.*?)\]\]></description>", item, re.S).group(1)
        pron = re.search(r"\\([^\\<]{1,60})\\", desc)
        pos = re.search(r"&#149;\s*<em>(.*?)</em>", desc)
        definition = ""
        body = desc.split("<br />", 1)[-1]
        for p in re.findall(r"<p>(.*?)</p>", body, re.S):
            text = html.unescape(re.sub(r"<[^>]+>", "", p)).strip()
            if text and not text.startswith("//") and "See the entry" not in text and not text.startswith("Examples"):
                definition = re.sub(r"\s+", " ", text)
                break
        return {"date": day, "word": word, "pron": pron.group(1).strip() if pron else "",
                "pos": html.unescape(pos.group(1)).strip() if pos else "", "definition": definition,
                "source": "Merriam-Webster"}

    async def fetch_fact(self, s):
        d = dt.datetime.now(system_tz())
        day = d.date().isoformat()  # the day asked for, even if midnight passes during the request
        try:
            url = f"https://en.wikipedia.org/api/rest_v1/feed/featured/{d:%Y/%m/%d}"
            async with s.get(url, timeout=aiohttp.ClientTimeout(total=25)) as r:
                r.raise_for_status()
                feed = await r.json()
            facts = []
            for item in feed.get("dyk", []):
                t = re.sub(r"\s*\((?:pictured|left|right|center)[^)]*\)", "", item.get("text", "")).strip()
                t = re.sub(r"^[.…\s]*that\s+", "", t)
                if not t:
                    continue
                t = t[0].upper() + t[1:]
                t = re.sub(r"\?$", ".", t)
                facts.append(t)
            good = [f for f in facts if 50 <= len(f) <= 180] or facts
            if good:
                return {"date": day, "text": good[0], "source": "Wikipedia, Did you know"}
        except Exception as e:
            log.info("wikipedia fact failed (%s), trying uselessfacts", e)
        async with s.get("https://uselessfacts.jsph.pl/api/v2/facts/today?language=en",
                         timeout=aiohttp.ClientTimeout(total=20)) as r:
            r.raise_for_status()
            j = await r.json()
        return {"date": day, "text": j["text"].strip(), "source": "uselessfacts"}

    async def daily_loop(self, s):
        next_try = {"word": 0.0, "fact": 0.0}
        fetchers = {"word": self.fetch_word, "fact": self.fetch_fact}
        while True:
            changed = False
            for key, fn in fetchers.items():
                cur = self.data.get(key) or {}
                if cur.get("date") != self.today() and time.time() >= next_try[key]:
                    try:
                        self.data[key] = await fn(s)
                        log.info("%s of the day updated", key)
                        changed = True
                    except Exception as e:
                        log.warning("%s fetch failed: %s", key, str(e) or type(e).__name__)
                        next_try[key] = time.time() + 15 * 60
            if changed:
                await self.push()
            await asyncio.sleep(60)

    # ------------------------------------------------------------------ google
    def google_credentials_changed(self) -> bool:
        return (file_stamp(CLIENT_FILE), file_stamp(TOKEN_FILE)) != self.google_stamp

    def google_client(self) -> Google:
        """The Google client, recreated (and a fetch forced) whenever the macOS app
        writes or removes the credential files."""
        if self.google is None or self.google_credentials_changed():
            self.google_stamp = (file_stamp(CLIENT_FILE), file_stamp(TOKEN_FILE))
            self.google = Google(self.session)
            self.google_force, self.google_backoff = True, 0.0
        return self.google

    def ensure_colors(self, calendars, tasklists):
        """Give every listed source an auto colour, persisted so it never changes."""
        keys = ["cal:" + c["id"] for c in calendars] + ["tasks:" + t["id"] for t in tasklists]
        colors = assign_colors(self.colors, keys, self.cfg)
        if colors != self.colors:
            self.colors = colors
            try:
                write_json_atomic(COLORS_FILE, colors)
            except OSError as e:
                log.warning("could not save source colours: %s", e)

    def recompose(self):
        """Rebuild the page's lists from the last fetched data (no network)."""
        tz = system_tz()
        try:
            if self.raw:
                self.ensure_colors(self.raw.get("calendars") or [], self.raw.get("tasklists") or [])
            self.data["lists"] = compose(self.raw, self.cfg, self.colors, tz, dt.datetime.now(tz))
        except Exception:
            log.exception("could not build the lists")
            self.data["lists"] = None
        self.composed_day = self.today()

    async def google_loop(self):
        last_ok_day = None
        while True:
            kicked = self.kick_google.is_set()  # woke up, or config / credentials changed
            self.kick_google.clear()            # (a kick during this pass runs another one at once)
            g = self.google_client()
            if not Google.configured():
                if self.data["google"].get("state") != "setup" or self.raw is not None:
                    # Signed out: forget everything that came from the account.
                    self.raw, self.data["google_at"] = None, 0
                    self.data["google"] = {"state": "setup"}
                    self.recompose()
                    await self.push()
            else:
                if self.data["google"].get("state") == "setup":
                    self.data["google"] = {"state": "loading"}
                    await self.push()
                if self.composed_day != self.today():  # midnight: today's list moves on even offline
                    self.recompose()
                    await self.push()
                age = time.time() - (self.data.get("google_at") or 0)
                # A new time zone (travel) moves "today": fetch for the new local day.
                moved = self.raw is not None and self.raw.get("tz") != system_tz_name()
                due = (self.google_force or moved or age >= 300 or (kicked and age >= 120)
                       or last_ok_day != self.today())
                if due and time.time() >= self.google_backoff:
                    force, self.google_force = self.google_force, False
                    fetch_day = self.today()  # g.fetch asks for this day, even if midnight passes meanwhile
                    try:
                        raw = await g.fetch(self.cfg, system_tz())
                        if g is self.google:  # credentials unchanged meanwhile
                            old_raw, self.raw = self.raw, self.without_done(raw)
                            self.data.update(google={"state": "ok"}, google_at=time.time())
                            last_ok_day = fetch_day
                            self.recompose()
                            if self.page_changed():
                                lists = self.data["lists"] or {}
                                log.info("google updated: %d events and %d tasks today, %d upcoming",
                                         len(lists.get("left", {}).get("events", [])),
                                         len(lists.get("left", {}).get("tasks", [])),
                                         len(lists.get("right", {}).get("items", [])))
                                await self.push()
                            elif not same_fetch(old_raw, self.raw) or time.time() - self.saved_at > 1800:
                                self.save()  # nothing new for the page: no push, and the cache only now and then
                    except AuthError as e:
                        log.error("google auth: %s", e)
                        self.data["google"] = {"state": "auth", "message": str(e)}
                        self.google_backoff = time.time() + 600
                        await self.push()
                    except Exception as e:
                        log.warning("google fetch failed: %s", str(e) or type(e).__name__)
                        self.google_force = self.google_force or force  # still owed once the backoff ends
                        if self.data["google"].get("state") != "ok":
                            self.data["google"] = {"state": "error", "message": "Can't reach Google right now."}
                            await self.push()
                        self.google_backoff = time.time() + 90
            try:
                await asyncio.wait_for(self.kick_google.wait(), 20)
            except asyncio.TimeoutError:
                pass

    # ------------------------------------------------------------------ checking off tasks
    def listed_task(self, list_id, task_id) -> bool:
        """True if the page was sent this task (in either list) as part of the current lists."""
        lists = self.data.get("lists") or {}
        items = (lists.get("left") or {}).get("tasks", []) + (lists.get("right") or {}).get("items", [])
        return any(i.get("list") == list_id and i.get("task") == task_id for i in items
                   if i.get("kind", "task") == "task")

    def without_done(self, raw: dict) -> dict:
        """`raw` without the tasks completed here lately (Google may list them for a while).
        Once a fetched list no longer has such a task, Google has caught up: it is forgotten,
        so a task reopened in Google later shows again."""
        now = time.time()
        self.recently_done = {k: at for k, at in self.recently_done.items() if now - at < RECENTLY_DONE_S}
        for (list_id, task_id) in list(self.recently_done):
            key = "tasks:" + list_id
            tasks = (raw.get("tasks") or {}).get(key)
            if tasks is None:
                continue  # that list wasn't fetched: nothing to tell
            if any(t.get("id") == task_id for t in tasks):
                raw["tasks"][key] = [t for t in tasks if t.get("id") != task_id]
            else:
                del self.recently_done[(list_id, task_id)]
        return raw

    def complete_task(self, ws, d: dict):
        """Check a task off for the page (a task-complete message), in the background."""
        list_id, task_id = d.get("list"), d.get("task")

        async def answer(t, **kw):
            try:
                await ws.send_str(json.dumps({"t": t, "list": list_id, "task": task_id, **kw}))
            except Exception:
                pass

        async def fail(reason):
            await answer("task-error", reason=reason, message=TASK_ERRORS[reason])

        async def run():
            key = (list_id, task_id)
            if not (isinstance(list_id, str) and isinstance(task_id, str) and 0 < len(list_id) <= 200
                    and 0 < len(task_id) <= 200) or not self.listed_task(list_id, task_id):
                log.warning("refused to complete a task that isn't in the lists")
                return await fail("unknown")
            if not self.can_complete():
                log.warning("refused to complete a task: the Google sign-in doesn't allow it")
                return await fail("scope")
            if key in self.completing:
                return
            self.completing.add(key)
            g = self.google_client()
            try:
                # capped well inside the page's wait for an answer (app.js SENT_MS)
                await asyncio.wait_for(g.complete_task(list_id, task_id), COMPLETE_TIMEOUT_S)
            except AuthError as e:
                log.warning("could not complete a task: %s", e)
                return await fail("auth")
            except Forbidden as e:
                log.warning("could not complete a task: %s", e)
                return await fail("scope")
            except NotFound as e:
                # Deleted, moved or already completed elsewhere: fetch the lists again.
                log.warning("could not complete a task: %s", e)
                self.google_force = True
                self.kick_google.set()
                return await fail("gone")
            except Exception as e:
                log.warning("could not complete a task: %s", str(e) or type(e).__name__)
                return await fail("offline")
            finally:
                self.completing.discard(key)
            log.info("task completed")
            self.recently_done[key] = time.time()
            if self.raw:
                self.raw = self.without_done(self.raw)
            self.recompose()
            await self.push()
            await answer("task-done")

        job = asyncio.ensure_future(run())
        self.jobs.add(job)
        job.add_done_callback(self.jobs.discard)

    # ------------------------------------------------------------------ http / ws
    async def index(self, request):
        return web.FileResponse(UI_DIR / "index.html", headers={"Cache-Control": "no-store"})

    async def state(self, request):
        return web.json_response(self.page_data())

    async def sources(self, request):
        """Every calendar and task list of the account, for the Settings window."""
        out = {"state": "setup", "account": None, "calendars": [], "tasklists": [],
               "defaults": {"left": [], "right": []}}
        if not Google.configured():
            return web.json_response(out)
        account = read_obj(TOKEN_FILE).get("account")
        out["account"] = account if isinstance(account, str) and account else None
        # "ok" whenever the sources are known (Settings only offers its checklists then),
        # even if the last list fetch failed; "auth" while the saved sign-in is rejected.
        state = self.data["google"].get("state")
        state = "loading" if state == "setup" else state
        g = self.google_client()
        meta, fresh = g.cached_metadata(), False
        if meta is None:
            try:
                meta, fresh = await asyncio.wait_for(g.metadata(), 20), True
            except AuthError as e:
                log.warning("sources: %s", e)
                state = "auth"
            except Exception as e:
                log.warning("sources: metadata fetch failed: %s", str(e) or type(e).__name__)
                state = "error" if state == "loading" else state
        if meta is None and self.raw:  # offline: the last known sources
            meta = (self.raw.get("calendars") or [], self.raw.get("tasklists") or [])
        out["state"] = "ok" if fresh or (meta is not None and state != "auth") else state
        if meta is not None:
            cals, tlists = meta
            self.ensure_colors(cals, tlists)
            color = lambda key: effective_color(key, self.colors, self.cfg)  # noqa: E731
            out["calendars"] = [{"key": "cal:" + c["id"], "name": c["name"],
                                 "google_selected": c["selected"] and not c["hidden"],
                                 "color": color("cal:" + c["id"])} for c in cals]
            out["tasklists"] = [{"key": "tasks:" + t["id"], "name": t["name"], "color": color("tasks:" + t["id"])}
                                for t in tlists]
            out["defaults"] = source_defaults(cals, tlists)
        return web.json_response(out)

    @web.middleware
    async def guard(self, request, handler):
        if not local_request(request.headers.get("Host"), request.headers.get("Origin"), self.port):
            log.warning("refused %s %s (Host %r, Origin %r)", request.method, request.path,
                        request.headers.get("Host", "")[:80], request.headers.get("Origin", "")[:80])
            raise web.HTTPForbidden()
        return await handler(request)

    async def health(self, request):
        now = time.time()
        return web.json_response({"ok": True, "awake": self.awake, "ui_clients": len(self.ui),
                                  "ui_age": round(now - self.last_ui_hb, 1) if self.last_ui_hb else None,
                                  "vision_age": round(now - self.last_vision, 1) if self.last_vision else None,
                                  "vision": self.vstat})

    async def ws_ui(self, request):
        ws = web.WebSocketResponse(heartbeat=15)
        await ws.prepare(request)
        self.ui.add(ws)
        # The engine's status every 2 s goes only to the macOS app (?client=app) and a
        # ?debug page (?vstat=1): it would otherwise wake the hidden page all day long.
        if request.query.get("client") == "app" or "vstat" in request.query:
            self.ui_status.add(ws)
        self.last_ui_hb = time.time()
        await ws.send_str(json.dumps({"t": "data", **self.page_data()}))
        await self.to_vision({"t": "hello"})
        errors = 0
        try:
            async for msg in ws:
                if msg.type != aiohttp.WSMsgType.TEXT:
                    continue
                try:
                    d = json.loads(msg.data)
                except ValueError:
                    continue
                t = d.get("t")
                if t == "hb":
                    self.last_ui_hb = time.time()
                    self._perf(d.get("fps"))
                elif t == "perf":
                    log.warning("ui: %s", str(d.get("note"))[:200])
                elif t == "config-changed":  # the macOS app saved config.json
                    self.kick_config.set()
                elif t == "task-complete":   # the page checked a task off
                    self.complete_task(ws, d)
                elif t in ("slept", "force", "overlay-ready", "overlay-hidden", "camera"):
                    # slept: the page finished its close animation
                    # force: keyboard / menu wake or close (macOS app) or debug tools
                    # overlay-ready / overlay-hidden: the macOS app showed / hid its window
                    # camera: the macOS app reports its camera mode (idle/active/paused)
                    await self.to_vision(d)
                elif t == "error" and errors < 20:
                    errors += 1
                    log.warning("ui error: %s", str(d.get("message"))[:300])
        finally:
            self.ui.discard(ws)
            self.ui_status.discard(ws)
        return ws

    def _perf(self, fps):
        """Log when the on-screen frame rate stays low (it should be 60)."""
        if fps is None:
            self._low = 0
            return
        self._low = getattr(self, "_low", 0) + 1 if fps < 50 else 0
        if self._low == 3 and time.time() - getattr(self, "_low_logged", 0) > 600:
            self._low_logged = time.time()
            log.warning("ui frame rate low for 15 s (%s fps); check CPU load", fps)

    async def ws_vision(self, request):
        ws = web.WebSocketResponse(heartbeat=15)
        await ws.prepare(request)
        if self.vision is not None and not self.vision.closed:
            await self.vision.close()
        self.vision = ws
        self.last_vision = time.time()
        log.info("vision connected")
        try:
            async for msg in ws:
                if msg.type != aiohttp.WSMsgType.TEXT:
                    continue
                self.last_vision = time.time()
                d = json.loads(msg.data)
                t = d.get("t")
                if t == "vstat":
                    self.vstat = d
                    self.awake = d.get("state") == "awake"
                elif t == "wake":
                    self.awake = True
                    self.kick_weather.set()
                    self.kick_google.set()
                elif t == "state":
                    self.awake = bool(d.get("awake"))
                await self.to_ui(msg.data, self.ui_status if t == "vstat" else None)
        finally:
            if self.vision is ws:
                self.vision = None
        return ws

    async def watchdog(self):
        while True:
            sd_notify("WATCHDOG=1")
            await asyncio.sleep(5)

    async def run(self):
        async with aiohttp.ClientSession(headers={"User-Agent": UA}) as s:
            self.session = s
            app = web.Application(middlewares=[self.guard])
            app.router.add_get("/", self.index)
            app.router.add_get("/api/state", self.state)
            app.router.add_get("/api/sources", self.sources)
            app.router.add_get("/health", self.health)
            app.router.add_get("/ws", self.ws_ui)
            app.router.add_get("/vision", self.ws_vision)
            app.router.add_static("/static", UI_DIR)
            runner = web.AppRunner(app, access_log=None)
            await runner.setup()
            await web.TCPSite(runner, "127.0.0.1", self.port).start()
            log.info("listening on 127.0.0.1:%d", self.port)
            sd_notify("READY=1")
            await asyncio.gather(self.weather_loop(s), self.daily_loop(s), self.google_loop(),
                                 self.config_loop(), self.watchdog())


def main():
    STATE.mkdir(parents=True, exist_ok=True)
    watch_parent(log)
    asyncio.run(Core().run())


if __name__ == "__main__":
    main()
