"""Google Calendar + Tasks (long-lived refresh token) and the two lists the page shows.
Calendars are only read; a task is changed only when it is checked off on the
page, and then only marked completed (Google.complete_task).

Files (written by the macOS app, both chmod 600, in HUD_STATE):
  google_client.json  {"client_id": ..., "client_secret": ... ("" = none, PKCE only), "source": ...}
  google_token.json   {"refresh_token": ..., "scopes": [...], "account": ...}

Google.fetch() keeps near-raw data (the "raw" dict below, also cached on disk);
compose() turns it into the page's lists for the current config, time zone and
time. So changes that don't alter *what* is fetched (titles, colours,
categories, countdowns) re-compose without touching the network.

  raw = {"fetched_at": float, "tz": "<IANA name the fetch used>",
         "calendars": [{"id", "name", "selected", "hidden"}],   # Google's order, hidden ones too
         "tasklists": [{"id", "name"}],
         "today":    {"cal:<id>": [event]},   # left calendars, the local day of the fetch
         "upcoming": {"cal:<id>": [event]},   # right calendars, now .. today + lookahead
         "tasks":    {"tasks:<id>": [task]}}  # every list used by either side, Google's order
  event = {"id", "title", "location", "allDay", "start", "end"}  # dates (all-day, end exclusive)
                                                                  # or ISO datetimes with offset
  task  = {"id", "title", "due": "YYYY-MM-DD" | None}

Every task the page gets carries "list" and "task" (its task list's and its own
Google id), what the page sends back to check it off.
"""
from __future__ import annotations

import asyncio
import datetime as dt
import json
import logging
import time
from urllib.parse import quote
from zoneinfo import ZoneInfo

import aiohttp

from .common import LIST_TITLES, PALETTE_IDS, STATE, read_json

log = logging.getLogger("core.google")
CLIENT_FILE = STATE / "google_client.json"
TOKEN_FILE = STATE / "google_token.json"
SCOPES = ["https://www.googleapis.com/auth/calendar.readonly",
          "https://www.googleapis.com/auth/tasks"]
# Sign-ins from before tasks could be checked off hold tasks.readonly instead: they
# read tasks as before, but checking off needs SCOPES[1] (a new sign-in).
TASKS_WRITE = SCOPES[1]
TOKEN_URL = "https://oauth2.googleapis.com/token"
CAL = "https://www.googleapis.com/calendar/v3"
TASKS = "https://tasks.googleapis.com/tasks/v1"
META_TTL = 3600       # calendar / task list metadata
MAX_DATED = 150       # right list caps
MAX_UNDATED = 50
MAX_SCAN = 1000       # events or tasks read per source and fetch, at most
# Google's `q` search matches whole words, while the keyword filter matches any
# part of the title ("meet" must find "Meeting"), so it is not used to narrow
# the upcoming-events request; the 150 kept / 1000 scanned caps bound it instead.
USE_SEARCH_Q = False


class AuthError(Exception):
    pass


class NotFound(RuntimeError):
    """A calendar or task list that no longer exists (404/410)."""


class Forbidden(RuntimeError):
    """This API can't be used: the sign-in lacks its scope (unticked on Google's consent
    screen), or it isn't enabled in the user's own Google Cloud project."""


# Phrases of a 403 that mean "this API is off limits" rather than a passing problem.
_FORBIDDEN = ("insufficient", "accessnotconfigured", "service_disabled", "has not been used in project")


def read_obj(path) -> dict:
    """A JSON object file as a dict ({} if missing, unreadable or not an object)."""
    d = read_json(path, {})
    return d if isinstance(d, dict) else {}


def tasks_writable() -> bool:
    """True when the saved sign-in may mark tasks completed (its "scopes" hold TASKS_WRITE)."""
    scopes = read_obj(TOKEN_FILE).get("scopes")
    return isinstance(scopes, list) and TASKS_WRITE in scopes


# ---------------------------------------------------------------------- pure helpers
def parse_keywords(text) -> tuple[list[str], list[str]]:
    """'report, -lunch' -> (["report"], ["lunch"]): comma separated, trimmed,
    lower-cased; a leading - excludes. Empty tokens and a lone - are ignored."""
    inc, exc = [], []
    for tok in (text if isinstance(text, str) else "").split(","):
        tok = tok.strip().lower()
        if tok.startswith("-"):
            tok = tok[1:].strip()
            if tok:
                exc.append(tok)
        elif tok:
            inc.append(tok)
    return inc, exc


def keyword_match(title: str, kw: tuple[list[str], list[str]]) -> bool:
    """Case-insensitive substring match: no exclude may appear, and when there are
    includes at least one must."""
    inc, exc = kw
    t = (title or "").lower()
    if any(x in t for x in exc):
        return False
    return not inc or any(x in t for x in inc)


def source_defaults(calendars: list, tasklists: list) -> dict:
    """sources == null: left = every calendar (except ones hidden from Google Calendar's
    list), right = every task list."""
    return {"left": ["cal:" + c["id"] for c in calendars if not c.get("hidden")],
            "right": ["tasks:" + t["id"] for t in tasklists]}


def resolve_sources(cfg: dict, side: str, calendars: list, tasklists: list) -> list[str]:
    """Source keys of one list that exist, in Google's order (calendars, then task lists)."""
    chosen = cfg["lists"][side].get("sources")
    if chosen is None:
        return source_defaults(calendars, tasklists)[side]
    chosen = set(chosen)
    known = ["cal:" + c["id"] for c in calendars] + ["tasks:" + t["id"] for t in tasklists]
    return [k for k in known if k in chosen]


def fetch_signature(cfg: dict) -> str:
    """Everything in the config that changes what is fetched (a change refetches at once)."""
    L, R = cfg["lists"]["left"], cfg["lists"]["right"]
    return json.dumps([L.get("sources"), R.get("sources"), L["event_keywords"], L["task_keywords"],
                       R["event_keywords"], R["task_keywords"], R["lookahead_days"]])


def _style(cfg: dict, key: str) -> dict:
    s = cfg.get("source_style", {}).get(key)
    return s if isinstance(s, dict) else {}


def effective_color(key: str, colors: dict, cfg: dict) -> str:
    """The user's colour for a source if set and valid, else its auto colour."""
    c = _style(cfg, key).get("color")
    if c in PALETTE_IDS:
        return c
    c = colors.get(key)
    return c if c in PALETTE_IDS else PALETTE_IDS[0]


def assign_colors(existing: dict, keys: list[str], cfg: dict) -> dict:
    """Auto colours (source_colors.json). A source seen for the first time gets the
    palette colour used by the fewest sources (by effective colour; ties: palette
    order). Existing valid entries are never changed. Returns a new dict."""
    colors = {k: v for k, v in (existing or {}).items() if isinstance(k, str) and v in PALETTE_IDS}
    for key in keys:
        if key in colors:
            continue
        counts = dict.fromkeys(PALETTE_IDS, 0)
        for k in colors:
            counts[effective_color(k, colors, cfg)] += 1
        colors[key] = min(PALETTE_IDS, key=counts.__getitem__)  # min keeps the first of equals
    return colors


def category_of(key: str, cfg: dict) -> dict | None:
    cid = _style(cfg, key).get("category")
    if not isinstance(cid, str) or not cid:
        return None
    for c in cfg.get("categories", []):
        if isinstance(c, dict) and c.get("id") == cid and isinstance(c.get("name"), str) and c["name"].strip():
            return c
    return None


def source_tag(key: str, name: str, colors: dict, cfg: dict) -> dict:
    """The pill of a source's items: its category if it has one, else its own name and colour."""
    cat = category_of(key, cfg)
    if cat:
        color = cat.get("color")
        return {"label": cat["name"].strip(), "color": color if color in PALETTE_IDS
                else effective_color(key, colors, cfg)}
    return {"label": name, "color": effective_color(key, colors, cfg)}


def list_title(cfg: dict, side: str) -> str:
    return cfg["lists"][side]["title"].strip() or LIST_TITLES[side]


def _local_midnight(day: dt.date, tz: ZoneInfo) -> dt.datetime:
    return dt.datetime.combine(day, dt.time(), tz)


def event_span(ev: dict, tz: ZoneInfo) -> tuple[dt.datetime, dt.datetime]:
    """Start and end of a stored event as aware datetimes in `tz` (all-day: local midnights)."""
    if ev["allDay"]:
        s = _local_midnight(dt.date.fromisoformat(ev["start"]), tz)
        e = _local_midnight(dt.date.fromisoformat(ev["end"]), tz)
    else:
        s = dt.datetime.fromisoformat(ev["start"]).astimezone(tz)
        e = dt.datetime.fromisoformat(ev["end"]).astimezone(tz)
    return s, max(s, e)


def compose(raw: dict | None, cfg: dict, colors: dict, tz: ZoneInfo, now: dt.datetime) -> dict | None:
    """The page's `lists` from raw Google data (see the module docstring)."""
    if not raw:
        return None
    cals, tlists = raw.get("calendars") or [], raw.get("tasklists") or []
    names = {"cal:" + c["id"]: c["name"] for c in cals} | {"tasks:" + t["id"]: t["name"] for t in tlists}
    tags = {}

    def tag(key):
        if key not in tags:
            tags[key] = source_tag(key, names.get(key, ""), colors, cfg)
        return tags[key]

    now = now.astimezone(tz)
    today = now.date()
    day0, day1 = _local_midnight(today, tz), _local_midnight(today + dt.timedelta(days=1), tz)

    def events(bucket, keys, kw, keep):
        """(start, end, event, key) of the stored events of `keys` that pass, each event once."""
        out, seen = [], set()
        for key in keys:
            if not key.startswith("cal:"):
                continue
            for ev in (raw.get(bucket) or {}).get(key, []):
                try:
                    s, e = event_span(ev, tz)
                except (KeyError, TypeError, ValueError):
                    continue
                if ev["id"] in seen or not keep(s, e) or not keyword_match(ev["title"], kw):
                    continue
                seen.add(ev["id"])
                out.append((s, e, ev, key))
        return out

    def tasks(keys, kw):
        """(due date or None, task, key) of the stored tasks of `keys` that pass, Google's order."""
        out = []
        for key in keys:
            if not key.startswith("tasks:"):
                continue
            for t in (raw.get("tasks") or {}).get(key, []):
                try:
                    due = dt.date.fromisoformat(t["due"]) if t.get("due") else None
                except (TypeError, ValueError):
                    due = None
                if keyword_match(t["title"], kw):
                    out.append((due, t, key))
        return out

    # Left: today. Events overlapping the local day (all-day first, then by start);
    # tasks due today or overdue (by due date, then title).
    L = cfg["lists"]["left"]
    left_keys = resolve_sources(cfg, "left", cals, tlists)
    in_today = lambda s, e: s < day1 and (e > day0 or s >= day0)  # noqa: E731  (zero-length events count)
    evs = events("today", left_keys, parse_keywords(L["event_keywords"]), in_today)
    evs.sort(key=lambda x: (not x[2]["allDay"], x[0], x[2]["title"].lower()))
    left_events = [{"id": ev["id"], "title": ev["title"], "start": s.isoformat(), "end": e.isoformat(),
                    "allDay": ev["allDay"], "location": ev.get("location", ""), "tag": tag(key)}
                   for s, e, ev, key in evs]
    tks = [x for x in tasks(left_keys, parse_keywords(L["task_keywords"])) if x[0] and x[0] <= today]
    tks.sort(key=lambda x: (x[0], x[1]["title"].lower()))
    left_tasks = [{"id": t["id"], "list": key[6:], "task": t["id"], "title": t["title"], "due": due.isoformat(),
                   "overdue": due < today, "tag": tag(key)} for due, t, key in tks]

    # Right: upcoming. Overdue tasks and tasks due before today + lookahead, events
    # still running or starting before then, sorted by due; undated tasks last.
    R = cfg["lists"]["right"]
    right_keys = resolve_sources(cfg, "right", cals, tlists)
    horizon_day = today + dt.timedelta(days=R["lookahead_days"])
    horizon = _local_midnight(horizon_day, tz)
    dated, undated = [], []
    for due, t, key in tasks(right_keys, parse_keywords(R["task_keywords"])):
        item = {"id": "t:" + t["id"], "kind": "task", "list": key[6:], "task": t["id"], "title": t["title"],
                "allDay": True, "tag": tag(key)}
        if due is None:
            undated.append({**item, "due": None, "overdue": False})
        elif due < horizon_day:
            at = dt.datetime.combine(due, dt.time(23, 59, 59), tz)
            dated.append((at, {**item, "due": at.isoformat(), "overdue": due < today}))
    for s, e, ev, key in events("upcoming", right_keys, parse_keywords(R["event_keywords"]),
                                lambda s, e: e > now and s < horizon):
        at = dt.datetime.combine(s.date(), dt.time(23, 59, 59), tz) if ev["allDay"] else s
        dated.append((at, {"id": "e:" + ev["id"], "kind": "event", "title": ev["title"], "due": at.isoformat(),
                           "start": s.isoformat(), "end": e.isoformat(), "allDay": ev["allDay"], "tag": tag(key)}))
    dated.sort(key=lambda x: (x[0], x[1]["title"].lower()))

    return {"date": today.isoformat(),
            "left": {"events": left_events, "tasks": left_tasks},
            "right": {"items": [d for _, d in dated[:MAX_DATED]] + undated[:MAX_UNDATED]}}


def _event(e: dict) -> dict | None:
    """Google event -> stored event; None for cancelled, declined, working-location or malformed ones."""
    if not e.get("id") or e.get("status") == "cancelled" or e.get("eventType") == "workingLocation":
        return None
    if any(a.get("self") and a.get("responseStatus") == "declined" for a in e.get("attendees", [])):
        return None
    start, end = e.get("start") or {}, e.get("end") or {}
    try:
        if "date" in start:
            s = dt.date.fromisoformat(start["date"])
            en = dt.date.fromisoformat(end["date"]) if "date" in end else s + dt.timedelta(days=1)
            s, en = s.isoformat(), max(en, s + dt.timedelta(days=1)).isoformat()
            all_day = True
        else:
            s = dt.datetime.fromisoformat(start["dateTime"])
            en = dt.datetime.fromisoformat(end.get("dateTime", start["dateTime"]))
            if s.tzinfo is None or en.tzinfo is None:
                return None
            s, en = s.isoformat(), en.isoformat()
            all_day = False
    except (KeyError, TypeError, ValueError):
        return None
    return {"id": e["id"], "title": (e.get("summary") or "").strip() or "(No title)",
            "location": e.get("location", ""), "allDay": all_day, "start": s, "end": en}


def _order_tasks(items: list) -> list:
    """Open tasks with a title, in Google's order: by position, subtasks right after their parent."""
    pos = {t.get("id"): t.get("position", "") for t in items}
    out = []
    for t in items:
        title = (t.get("title") or "").strip()
        if t.get("status") == "completed" or t.get("deleted") or not title or not t.get("id"):
            continue
        parent = t.get("parent")
        order = (pos[parent], 1, t.get("position", "")) if parent in pos else (t.get("position", ""), 0, "")
        due = t.get("due")  # Google Tasks keeps only the date part
        out.append((order, {"id": t["id"], "title": title, "due": due[:10] if due else None}))
    out.sort(key=lambda x: x[0])
    return [t for _, t in out]


# ---------------------------------------------------------------------- Google API
class Google:
    def __init__(self, session: aiohttp.ClientSession):
        self.s = session
        self._access = None
        self._access_exp = 0.0
        self._meta = None
        self._meta_at = 0.0
        self._meta_lock = asyncio.Lock()

    @staticmethod
    def configured() -> bool:
        return CLIENT_FILE.exists() and TOKEN_FILE.exists()

    async def _token(self) -> str:
        if self._access and time.time() < self._access_exp - 120:
            return self._access
        client, tok = read_obj(CLIENT_FILE), read_obj(TOKEN_FILE)
        if not client.get("client_id") or not tok.get("refresh_token"):
            raise AuthError("not configured")
        data = {"client_id": client["client_id"], "refresh_token": tok["refresh_token"],
                "grant_type": "refresh_token"}
        secret = client.get("client_secret")
        secret = secret.strip() if isinstance(secret, str) else ""
        if secret:  # a client without one (PKCE only): omit the field
            data["client_secret"] = secret
        async with self.s.post(TOKEN_URL, data=data, timeout=aiohttp.ClientTimeout(total=20)) as r:
            body = await r.json(content_type=None)
            if r.status != 200:
                err = body.get("error", r.status) if isinstance(body, dict) else r.status
                if err in ("invalid_grant", "invalid_client", "unauthorized_client"):
                    raise AuthError(f"Google rejected the saved sign-in ({err})")
                raise RuntimeError(f"token refresh failed: {err}")
        self._access = body["access_token"]
        self._access_exp = time.time() + int(body.get("expires_in", 3600))
        return self._access

    async def _get(self, url, params=None):
        for attempt in range(2):
            tok = await self._token()
            async with self.s.get(url, params=params, headers={"Authorization": f"Bearer {tok}"},
                                  timeout=aiohttp.ClientTimeout(total=25)) as r:
                if r.status == 401 and attempt == 0:
                    self._access = None
                    continue
                if r.status >= 400:
                    await self._fail("GET", url, r)
                return await r.json()

    async def _patch(self, url, body: dict):
        """The write twin of _get: the same token refresh on a 401 and the same errors."""
        for attempt in range(2):
            tok = await self._token()
            async with self.s.patch(url, json=body, headers={"Authorization": f"Bearer {tok}"},
                                    timeout=aiohttp.ClientTimeout(total=20)) as r:
                if r.status == 401 and attempt == 0:
                    self._access = None
                    continue
                if r.status >= 400:
                    await self._fail("PATCH", url, r)
                return await r.json(content_type=None)

    @staticmethod
    async def _fail(method, url, r):
        """Raise the error for an HTTP error answer (see NotFound and Forbidden)."""
        text = (await r.text())[:4000]
        msg = f"{method} {url.split('?')[0]} -> {r.status}: {text[:300]}"
        if r.status in (404, 410):
            raise NotFound(msg)
        if r.status == 403 and any(p in text.lower() for p in _FORBIDDEN):
            raise Forbidden(msg)
        raise RuntimeError(msg)

    async def _paged(self, url, params):
        items, params = [], dict(params)
        while True:
            d = await self._get(url, params)
            items += d.get("items", [])
            tok = d.get("nextPageToken")
            if not tok or len(items) >= MAX_SCAN:
                return items
            params["pageToken"] = tok

    # ------------------------------------------------------------------ metadata
    def cached_metadata(self):
        """(calendars, tasklists) if fetched within the last hour, else None."""
        return self._meta if self._meta and time.time() - self._meta_at < META_TTL else None

    async def metadata(self):
        """(calendars, tasklists) in Google's order, hidden calendars included; cached 1 h.
        A missing scope (unticked on Google's consent screen) just gives an empty side."""
        async with self._meta_lock:
            if self.cached_metadata() is None:
                async def get(url, params):
                    try:
                        return await self._paged(url, params)
                    except Forbidden as e:
                        log.warning("no permission: %s", e)
                        return None
                cal_items, list_items = await asyncio.gather(
                    get(f"{CAL}/users/me/calendarList", {"maxResults": 250, "showHidden": "true"}),
                    get(f"{TASKS}/users/@me/lists", {"maxResults": 100}))
                if cal_items is None and list_items is None:
                    raise AuthError("Waverly isn't allowed to read your calendars or tasks")
                cals = [{"id": c["id"], "name": (c.get("summaryOverride") or c.get("summary") or "").strip()
                         or "Calendar", "selected": bool(c.get("selected")), "hidden": bool(c.get("hidden"))}
                        for c in cal_items or [] if c.get("id") and not c.get("deleted")]
                lists = [{"id": t["id"], "name": (t.get("title") or "").strip() or "Tasks"}
                         for t in list_items or [] if t.get("id")]
                self._meta, self._meta_at = (cals, lists), time.time()
            return self._meta

    # ------------------------------------------------------------------ data
    async def _events(self, key: str, params: dict, keep=None, max_keep: int | None = None) -> list:
        """Stored events of one calendar, paging until done, MAX_SCAN read or max_keep kept."""
        url = f"{CAL}/calendars/{quote(key[4:], safe='')}/events"
        params = {"singleEvents": "true", "orderBy": "startTime", "maxResults": 250, **params}
        out, scanned = [], 0
        while True:
            d = await self._get(url, params)
            items = d.get("items", [])
            scanned += len(items)
            for e in items:
                ev = _event(e)
                if ev and (keep is None or keep(ev)):
                    out.append(ev)
            tok = d.get("nextPageToken")
            if not tok or scanned >= MAX_SCAN or (max_keep and len(out) >= max_keep):
                return out
            params["pageToken"] = tok

    async def complete_task(self, list_id: str, task_id: str):
        """Marks one task completed: the only change Waverly ever makes in Google."""
        await self._patch(f"{TASKS}/lists/{quote(list_id, safe='')}/tasks/{quote(task_id, safe='')}",
                          {"status": "completed"})

    async def _tasks(self, key: str) -> list:
        items = await self._paged(f"{TASKS}/lists/{quote(key[6:], safe='')}/tasks", {
            "showCompleted": "false", "showHidden": "false", "maxResults": 100})
        return _order_tasks(items)

    async def fetch(self, cfg: dict, tz: ZoneInfo) -> dict:
        """Raw data for the current config: today's events of the left calendars, upcoming
        events of the right calendars, and every task list used by either side (once)."""
        cals, tlists = await self.metadata()
        left = resolve_sources(cfg, "left", cals, tlists)
        right = resolve_sources(cfg, "right", cals, tlists)
        R = cfg["lists"]["right"]

        now = dt.datetime.now(tz)
        day0 = _local_midnight(now.date(), tz)
        day1 = _local_midnight(now.date() + dt.timedelta(days=1), tz)
        horizon = _local_midnight(now.date() + dt.timedelta(days=R["lookahead_days"]), tz)
        kw = parse_keywords(R["event_keywords"])
        upcoming = {"timeMin": now.replace(microsecond=0).isoformat(), "timeMax": horizon.isoformat()}
        if USE_SEARCH_Q and len(kw[0]) == 1:
            upcoming["q"] = kw[0][0]
        today = {"timeMin": day0.isoformat(), "timeMax": day1.isoformat()}

        jobs = []  # (bucket, key, coroutine)
        jobs += [("today", k, self._events(k, today)) for k in left if k.startswith("cal:")]
        jobs += [("upcoming", k, self._events(k, upcoming, lambda ev: keyword_match(ev["title"], kw), MAX_DATED))
                 for k in right if k.startswith("cal:")]
        jobs += [("tasks", k, self._tasks(k)) for k in dict.fromkeys(left + right) if k.startswith("tasks:")]

        results = await asyncio.gather(*(c for _, _, c in jobs), return_exceptions=True)
        raw = {"fetched_at": time.time(), "tz": tz.key, "calendars": cals, "tasklists": tlists,
               "today": {}, "upcoming": {}, "tasks": {}}
        for (bucket, key, _), res in zip(jobs, results):
            if isinstance(res, (NotFound, Forbidden)):
                # Deleted or no longer shared, or no permission: skip it and
                # re-read the metadata next time.
                log.warning("skipping %s: %s", key, res)
                self._meta_at = 0.0
                res = []
            elif isinstance(res, BaseException):
                raise res
            raw[bucket][key] = res
        return raw
