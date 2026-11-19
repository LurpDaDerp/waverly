"""Tests for hud-core's config model and list building (hud/common.py, hud/gcal.py).

Pure functions only, with made-up fixtures; the Google API is faked. No network.

Run:  python3 tests/test_core_lists.py      (from hud/, with the venv active)
  or  python3 -m pytest tests/test_core_lists.py
"""
import asyncio
import datetime as dt
import json
import os
import sys
import tempfile
from pathlib import Path
from zoneinfo import ZoneInfo

_TMP = tempfile.mkdtemp(prefix="waverly-test-")
os.environ["HUD_STATE"] = _TMP  # before importing hud: nothing may touch the real state folder
os.environ["HUD_CONFIG"] = str(Path(_TMP) / "config.json")
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "python"))

from hud import common  # noqa: E402
from hud.common import DEFAULTS, PALETTE_IDS, ConfigError, merge_config, system_tz_name  # noqa: E402
from hud.gcal import (Forbidden, Google, NotFound, _event, _order_tasks, assign_colors, compose,  # noqa: E402
                      effective_color, fetch_signature, keyword_match, parse_keywords, read_obj, resolve_sources,
                      source_defaults, source_tag)

LA = ZoneInfo("America/Los_Angeles")
NOW = dt.datetime(2026, 11, 17, 10, 0, tzinfo=LA)  # a Tuesday morning, PST (-08:00)

CALS = [{"id": "work@group", "name": "Work", "selected": True, "hidden": False},
        {"id": "family@group", "name": "Family", "selected": True, "hidden": False},
        {"id": "hidden@group", "name": "Hidden", "selected": True, "hidden": True},
        {"id": "other@group", "name": "Holidays", "selected": False, "hidden": False}]
LISTS = [{"id": "L1", "name": "Inbox"}, {"id": "L2", "name": "Chores"}]


def cfg_with(**lists):
    """Config with lists.<side> overrides, e.g. cfg_with(left={"sources": [...]})."""
    return merge_config({"lists": lists})


def ev(id, title, start, end, all_day=False, location=""):
    return {"id": id, "title": title, "location": location, "allDay": all_day, "start": start, "end": end}


def task(id, title, due=None):
    return {"id": id, "title": title, "due": due}


def raw_with(today=None, upcoming=None, tasks=None):
    return {"fetched_at": 0, "calendars": CALS, "tasklists": LISTS,
            "today": today or {}, "upcoming": upcoming or {}, "tasks": tasks or {}}


# ---------------------------------------------------------------------- keywords
def test_parse_keywords():
    assert parse_keywords("Report, -lunch , , -, EXAM,-  Gym ") == (["report", "exam"], ["lunch", "gym"])
    assert parse_keywords("") == ([], [])
    assert parse_keywords(None) == ([], [])
    assert parse_keywords(" - , ,") == ([], [])
    assert parse_keywords("--x") == ([], ["-x"])


def test_keyword_match():
    kw = parse_keywords("report, -lunch")
    assert keyword_match("Quarterly REPORT due", kw)
    assert not keyword_match("Report over lunch", kw)       # an exclude always wins
    assert not keyword_match("Team sync", kw)               # includes exist: one must match
    assert keyword_match("Anything", parse_keywords(""))    # empty field: no filtering
    assert keyword_match("Meeting room", parse_keywords("meet"))  # substring, not whole word
    only_ex = parse_keywords("-lunch")
    assert keyword_match("Team sync", only_ex) and not keyword_match("Lunch", only_ex)
    assert not keyword_match("", parse_keywords("x")) and keyword_match(None, parse_keywords(""))


# ---------------------------------------------------------------------- config
def test_defaults_are_neutral():
    assert DEFAULTS["name"] == "" and DEFAULTS["place"] == ""
    assert DEFAULTS["lat"] is None and DEFAULTS["lon"] is None
    assert DEFAULTS["http_port"] == 47780 and "timezone" not in DEFAULTS
    assert DEFAULTS["lists"]["left"] == {"title": "Calendar", "sources": None, "event_keywords": "",
                                         "task_keywords": ""}
    assert DEFAULTS["lists"]["right"] == {"title": "Tasks", "sources": None, "event_keywords": "",
                                          "task_keywords": "", "countdowns": True, "lookahead_days": 30}
    assert set(DEFAULTS) == {"version", "onboarded", "name", "location_auto", "place", "lat", "lon",
                             "temperature_unit", "wind_unit", "clock", "lists", "source_style", "categories",
                             "http_port", "dark_mean", "dark_p99", "away_seconds", "swap_handedness",
                             "theme", "parallax", "weather_animation", "weather_detail",
                             "open_animation_s", "close_animation_s", "open_animation", "close_animation",
                             "scroll_speed_vertical", "scroll_speed_horizontal",
                             "scroll_reverse_vertical", "scroll_reverse_horizontal",
                             "gesture_open_wave", "gesture_open_fist", "gesture_close_fist",
                             "auto_close_away", "auto_close_dark"}
    assert (DEFAULTS["theme"], DEFAULTS["parallax"], DEFAULTS["weather_animation"], DEFAULTS["weather_detail"],
            DEFAULTS["scroll_reverse_vertical"], DEFAULTS["scroll_reverse_horizontal"]) == (
        "adaptive", True, True, "high", False, False)
    assert (DEFAULTS["open_animation_s"], DEFAULTS["close_animation_s"]) == (1.0, 0.75)   # the default timing


def test_merge_config_deep_merges_lists():
    cfg = merge_config({"name": "Alex", "timezone": "Europe/Paris", "extra": {"kept": 1},
                        "lists": {"right": {"lookahead_days": 7, "sources": ["tasks:L1", 5]},
                                  "left": {"event_keywords": "sync"}}})
    assert cfg["name"] == "Alex" and "timezone" not in cfg and cfg["extra"] == {"kept": 1}
    assert cfg["lists"]["right"] == {"title": "Tasks", "sources": ["tasks:L1"], "event_keywords": "",
                                     "task_keywords": "", "countdowns": True, "lookahead_days": 7}
    assert cfg["lists"]["left"]["title"] == "Calendar" and cfg["lists"]["left"]["event_keywords"] == "sync"
    assert cfg["lists"]["left"]["sources"] is None
    assert DEFAULTS["lists"]["right"]["lookahead_days"] == 30   # defaults never mutated
    assert merge_config({}) == merge_config({"lists": "junk"}) == merge_config({"lists": {"left": 3}})


def test_merge_config_sanitises():
    cfg = merge_config({"lat": 38.7, "lon": None, "temperature_unit": "kelvin", "wind_unit": "kmh",
                        "clock": 24, "http_port": "80", "away_seconds": True, "dark_mean": 4,
                        "source_style": [], "categories": {}, "name": None,
                        "lists": {"right": {"lookahead_days": 9999, "countdowns": "no", "title": None,
                                            "sources": "cal:x"}}})
    assert cfg["lat"] is None and cfg["lon"] is None                    # half a location is no location
    assert cfg["temperature_unit"] == "fahrenheit" and cfg["wind_unit"] == "kmh" and cfg["clock"] == "12h"
    assert cfg["http_port"] == 47780 and cfg["away_seconds"] == 5.0 and cfg["dark_mean"] == 4
    assert cfg["source_style"] == {} and cfg["categories"] == [] and cfg["name"] == ""
    r = cfg["lists"]["right"]
    assert r["lookahead_days"] == 365 and r["countdowns"] is True and r["title"] == "Tasks" and r["sources"] is None
    assert merge_config({"lat": 91, "lon": 0})["lat"] is None
    assert merge_config({"lat": 0, "lon": 0})["lat"] == 0
    assert merge_config({"lists": {"right": {"lookahead_days": 0}}})["lists"]["right"]["lookahead_days"] == 1
    assert merge_config({"lists": {"right": {"lookahead_days": 14.0}}})["lists"]["right"]["lookahead_days"] == 14
    huge = 10 ** 400  # an int too big for a float: the default, not an OverflowError
    cfg = merge_config({"lat": huge, "lon": 0, "away_seconds": huge, "dark_mean": -huge, "scroll_speed_vertical": huge,
                        "open_animation_s": huge, "lists": {"right": {"lookahead_days": huge}}})
    assert cfg["lat"] is None and cfg["away_seconds"] == DEFAULTS["away_seconds"]
    assert cfg["dark_mean"] == DEFAULTS["dark_mean"]
    assert cfg["scroll_speed_vertical"] == DEFAULTS["scroll_speed_vertical"] and cfg["open_animation_s"] == 1.0
    assert cfg["lists"]["right"]["lookahead_days"] == 30


def test_merge_config_appearance_and_gestures():
    prefs = ("theme", "parallax", "weather_animation", "weather_detail",
             "scroll_reverse_vertical", "scroll_reverse_horizontal")
    base = merge_config({})
    assert {k: base[k] for k in prefs} == {k: DEFAULTS[k] for k in prefs}
    good = {"theme": "dark", "parallax": False, "weather_animation": False, "weather_detail": "low",
            "scroll_reverse_vertical": True, "scroll_reverse_horizontal": True}
    assert {k: merge_config(good)[k] for k in prefs} == good
    for theme in ("adaptive", "light", "dark"):
        assert merge_config({"theme": theme})["theme"] == theme
    for detail in ("high", "medium", "low"):
        assert merge_config({"weather_detail": detail})["weather_detail"] == detail
    bad = {"theme": "Dark", "parallax": 0, "weather_animation": "false", "weather_detail": 2,
           "scroll_reverse_vertical": 1, "scroll_reverse_horizontal": None}
    assert {k: merge_config(bad)[k] for k in prefs} == {k: DEFAULTS[k] for k in prefs}
    assert merge_config({"theme": ["dark"], "weather_detail": None})["theme"] == "adaptive"
    # the Swift-only hotkey is kept as written (unknown keys survive)
    hk = {"key_code": 4, "modifiers": ["fn", "shift"], "display": "fn ⇧ H"}
    assert merge_config({"hotkey": hk})["hotkey"] == hk


def test_merge_config_gesture_settings():
    keys = ("gesture_open_wave", "gesture_open_fist", "gesture_close_fist", "auto_close_away", "auto_close_dark")
    assert all(DEFAULTS[k] is True for k in keys)                  # every gesture and auto-close on by default
    assert {k: merge_config({})[k] for k in keys} == dict.fromkeys(keys, True)
    off = dict.fromkeys(keys, False)
    assert {k: merge_config(off)[k] for k in keys} == off
    bad = {"gesture_open_wave": 0, "gesture_open_fist": "false", "gesture_close_fist": None,
           "auto_close_away": [], "auto_close_dark": 1}
    assert {k: merge_config(bad)[k] for k in keys} == dict.fromkeys(keys, True)   # only a real boolean counts
    one = merge_config({"gesture_open_fist": False, "something_new": 3})
    assert one["gesture_open_fist"] is False and one["gesture_open_wave"] is True and one["something_new"] == 3


def test_merge_config_animation_lengths():
    base = merge_config({})
    assert (base["open_animation_s"], base["close_animation_s"]) == (1.0, 0.75)
    cases = [  # (written, open result, close result)
        (0, 0.0, 0.0), (0.0, 0.0, 0.0), (-1, 0.0, 0.0),           # instant
        (0.1, 0.0, 0.0), (0.25, 0.0, 0.25), (0.29, 0.0, 0.29),    # below the minimum: instant
        (0.3, 0.3, 0.3), (1, 1.0, 1.0), (1.5, 1.5, 1.5), (1.7, 1.7, 1.5), (2.0, 2.0, 1.5), (9, 2.0, 1.5),
        (float("inf"), 1.0, 0.75), (float("nan"), 1.0, 0.75),     # not a usable number: the default
        (True, 1.0, 0.75), ("1.2", 1.0, 0.75), (None, 1.0, 0.75), ([1], 1.0, 0.75),
    ]
    for v, want_open, want_close in cases:
        cfg = merge_config({"open_animation_s": v, "close_animation_s": v})
        assert (cfg["open_animation_s"], cfg["close_animation_s"]) == (want_open, want_close), v
        assert all(type(cfg[k]) is float for k in ("open_animation_s", "close_animation_s")), v
    json.dumps(merge_config({"open_animation_s": 2}))


def test_load_config_file_handling():
    path = Path(_TMP) / "cfg-test.json"
    old = common.CONFIG_FILE
    common.CONFIG_FILE = path
    try:
        path.unlink(missing_ok=True)
        assert common.load_config() == merge_config({})
        path.write_text('{"name": "Sam", "lists": {"left": {"title": "Today"}}}')
        cfg = common.load_config(strict=True)
        assert cfg["name"] == "Sam" and cfg["lists"]["left"]["title"] == "Today"
        assert cfg["lists"]["right"]["lookahead_days"] == 30
        for bad in ('{"name": "Sa', "[1, 2]"):
            path.write_text(bad)
            assert common.load_config() == merge_config({})
            try:
                common.load_config(strict=True)
                raise AssertionError("strict load accepted a broken file")
            except ConfigError:
                pass
        path.write_text('{"name": "Sam", "lat": 1%s}' % ("0" * 400))
        assert common.load_config(strict=True)["name"] == "Sam" and common.load_config()["lat"] is None
        # Anything else merge_config can't cope with: the defaults, or ConfigError when strict (never a crash).
        merge = common.merge_config

        def broken(user):
            if user:
                raise RuntimeError("unexpected value")
            return merge(user)
        common.merge_config = broken
        try:
            assert common.load_config() == merge_config({})
            try:
                common.load_config(strict=True)
                raise AssertionError("strict load accepted a config it could not merge")
            except ConfigError:
                pass
        finally:
            common.merge_config = merge
    finally:
        common.CONFIG_FILE = old


def test_system_tz_name():
    d = Path(tempfile.mkdtemp(dir=_TMP))
    cases = {"/var/db/timezone/zoneinfo/Europe/Lisbon": "Europe/Lisbon",
             "/usr/share/zoneinfo/America/Argentina/Buenos_Aires": "America/Argentina/Buenos_Aires",
             "/usr/share/zoneinfo/posix/Asia/Tokyo": "Asia/Tokyo",
             "/var/db/timezone/zoneinfo/Not/AZone": "UTC",
             "/somewhere/else": "UTC"}
    for i, (target, want) in enumerate(cases.items()):
        link = d / f"localtime{i}"
        link.symlink_to(target)
        assert system_tz_name(str(link)) == want, (target, system_tz_name(str(link)))
    assert system_tz_name(str(d / "missing")) == "UTC"
    real = system_tz_name()
    ZoneInfo(real)  # whatever this Mac uses resolves to a real zone


# ---------------------------------------------------------------------- sources
def test_source_defaults_and_resolve():
    d = source_defaults(CALS, LISTS)
    assert d == {"left": ["cal:work@group", "cal:family@group"], "right": ["tasks:L1", "tasks:L2"]}
    cfg = merge_config({})
    assert resolve_sources(cfg, "left", CALS, LISTS) == d["left"]
    assert resolve_sources(cfg, "right", CALS, LISTS) == d["right"]
    # Explicit choices: unknown keys dropped, Google's order (calendars first), hidden ones allowed.
    cfg = cfg_with(left={"sources": ["tasks:L2", "cal:gone", "cal:hidden@group", "cal:work@group"]},
                   right={"sources": []})
    assert resolve_sources(cfg, "left", CALS, LISTS) == ["cal:work@group", "cal:hidden@group", "tasks:L2"]
    assert resolve_sources(cfg, "right", CALS, LISTS) == []


def test_fetch_signature():
    base = merge_config({})
    sig = fetch_signature(base)
    same = merge_config({"name": "x", "clock": "24h", "source_style": {"cal:a": {"color": "teal"}},
                         "categories": [{"id": "c1", "name": "A", "color": "blue"}],
                         "lists": {"left": {"title": "T"}, "right": {"countdowns": False, "title": "U"}}})
    assert fetch_signature(same) == sig
    for change in ({"left": {"sources": []}}, {"right": {"sources": ["tasks:L1"]}},
                   {"left": {"event_keywords": "a"}}, {"left": {"task_keywords": "a"}},
                   {"right": {"event_keywords": "a"}}, {"right": {"task_keywords": "a"}},
                   {"right": {"lookahead_days": 7}}):
        assert fetch_signature(merge_config({"lists": change})) != sig, change


# ---------------------------------------------------------------------- colours
def test_assign_colors():
    cfg = merge_config({})
    keys = ["cal:a", "cal:b", "tasks:c"]
    c1 = assign_colors({}, keys, cfg)
    assert [c1[k] for k in keys] == PALETTE_IDS[:3]
    assert assign_colors(c1, keys, cfg) == c1                        # stable
    assert assign_colors(c1, list(reversed(keys)), cfg) == c1        # order of later calls doesn't matter
    many = [f"cal:{i}" for i in range(12)]
    c2 = assign_colors({}, many, cfg)
    assert [c2[k] for k in many] == PALETTE_IDS + PALETTE_IDS[:2]    # wraps round evenly
    # Existing entries are never reassigned; invalid ones are; the least-used colour wins.
    c3 = assign_colors({"cal:x": "blue", "cal:y": "blue", "cal:z": "purple"}, ["cal:x", "cal:y", "cal:z", "cal:n"],
                       cfg)
    assert c3["cal:x"] == "blue" and c3["cal:y"] == "blue"
    assert c3["cal:z"] == "amber" and c3["cal:n"] == "teal"
    # A user's colour counts as "used": blue is taken by the override, so the new source skips it.
    cfg2 = merge_config({"source_style": {"cal:x": {"color": "amber"}}})
    c4 = assign_colors({"cal:x": "blue"}, ["cal:x", "cal:n"], cfg2)
    assert c4 == {"cal:x": "blue", "cal:n": "blue"}
    c5 = assign_colors({"cal:x": "blue", "cal:y": "amber"}, ["cal:n"],
                       merge_config({"source_style": {"cal:y": {"color": "blue"}}}))
    assert c5["cal:n"] == "amber"


def test_effective_color_and_tags():
    colors = {"cal:a": "teal", "tasks:b": "rose"}
    cfg = merge_config({
        "source_style": {"cal:a": {"color": "gold", "category": None},
                         "tasks:b": {"color": "nope", "category": "c1"},
                         "cal:c": {"category": "missing"},
                         "cal:d": {"category": "c2"},
                         "cal:e": "junk"},
        "categories": [{"id": "c1", "name": " Errands ", "color": "violet"},
                       {"id": "c2", "name": "Blank colour", "color": None},
                       {"id": "c3", "name": "  ", "color": "blue"}]})
    assert effective_color("cal:a", colors, cfg) == "gold"
    assert effective_color("tasks:b", colors, cfg) == "rose"            # invalid override ignored
    assert effective_color("cal:e", {"cal:e": "cyan"}, cfg) == "cyan"
    assert source_tag("cal:a", "Work", colors, cfg) == {"label": "Work", "color": "gold"}
    assert source_tag("tasks:b", "Inbox", colors, cfg) == {"label": "Errands", "color": "violet"}
    assert source_tag("cal:c", "Gym", {"cal:c": "green"}, cfg) == {"label": "Gym", "color": "green"}
    assert source_tag("cal:d", "Club", {"cal:d": "coral"}, cfg) == {"label": "Blank colour", "color": "coral"}
    cfg3 = merge_config({"source_style": {"cal:f": {"category": "c3"}}, "categories": cfg["categories"]})
    assert source_tag("cal:f", "Fam", {"cal:f": "slate"}, cfg3) == {"label": "Fam", "color": "slate"}


# ---------------------------------------------------------------------- compose: left
def test_compose_left_events():
    raw = raw_with(today={
        "cal:work@group": [
            ev("w1", "Standup", "2026-11-17T09:00:00-08:00", "2026-11-17T09:15:00-08:00"),
            ev("w2", "Late call", "2026-11-18T07:30:00Z", "2026-11-18T08:00:00Z"),        # 23:30 local
            ev("w3", "Tomorrow early", "2026-11-18T08:30:00Z", "2026-11-18T09:00:00Z"),   # 00:30 tomorrow
            ev("w4", "Night shift", "2026-11-16T23:00:00-08:00", "2026-11-17T01:00:00-08:00"),
            ev("w5", "Report review", "2026-11-17T13:00:00-08:00", "2026-11-17T14:00:00-08:00"),
            ev("w6", "Bad", "not a date", "2026-11-17T14:00:00-08:00"),
            ev("w7", "Zero length", "2026-11-17T12:00:00-08:00", "2026-11-17T12:00:00-08:00"),
        ],
        "cal:family@group": [
            ev("f1", "Trip", "2026-11-16", "2026-11-19", all_day=True),
            ev("f0", "Yesterday", "2026-11-16", "2026-11-17", all_day=True),
            ev("w5", "Report review", "2026-11-17T13:00:00-08:00", "2026-11-17T14:00:00-08:00"),  # shared invite
        ],
        "cal:other@group": [ev("o1", "Not a left source", "2026-11-17", "2026-11-18", all_day=True)],
    })
    lists = compose(raw, merge_config({}), {}, LA, NOW)
    assert lists["date"] == "2026-11-17"
    got = [e["id"] for e in lists["left"]["events"]]
    assert got == ["f1", "w4", "w1", "w7", "w5", "w2"], got
    trip = lists["left"]["events"][0]
    assert trip["allDay"] and trip["start"] == "2026-11-16T00:00:00-08:00"
    assert trip["end"] == "2026-11-19T00:00:00-08:00"
    late = lists["left"]["events"][-1]
    assert late["start"] == "2026-11-17T23:30:00-08:00" and late["tag"]["label"] == "Work"
    assert lists["left"]["events"][4]["tag"]["label"] == "Work"  # shared event shown once, first source wins
    assert lists["left"]["tasks"] == []                          # default left list: calendars only
    # Keyword filters apply to the left list's events.
    lists = compose(raw, cfg_with(left={"event_keywords": "review, call, -late"}), {}, LA, NOW)
    assert [e["id"] for e in lists["left"]["events"]] == ["w5"]


def test_compose_left_tasks():
    raw = raw_with(tasks={"tasks:L1": [task("t1", "Pay rent", "2026-11-17"), task("t2", "Return book", "2026-11-12"),
                                       task("t3", "Future", "2026-11-18"), task("t4", "Someday"),
                                       task("t5", "apply form", "2026-11-17"), task("t6", "Bad due", "17/11")]})
    cfg = cfg_with(left={"sources": ["tasks:L1"]})
    lists = compose(raw, cfg, {"tasks:L1": "amber"}, LA, NOW)
    tasks = lists["left"]["tasks"]
    assert [t["id"] for t in tasks] == ["t2", "t5", "t1"]
    assert tasks[0] == {"id": "t2", "list": "L1", "task": "t2", "title": "Return book", "due": "2026-11-12",
                        "overdue": True, "tag": {"label": "Inbox", "color": "amber"}}
    assert tasks[1]["overdue"] is False
    lists = compose(raw, cfg_with(left={"sources": ["tasks:L1"], "task_keywords": "-rent"}), {}, LA, NOW)
    assert [t["id"] for t in lists["left"]["tasks"]] == ["t2", "t5"]


# ---------------------------------------------------------------------- compose: right
def test_compose_right():
    raw = raw_with(
        upcoming={"cal:work@group": [
            ev("e1", "Ongoing sync", "2026-11-17T09:30:00-08:00", "2026-11-17T11:00:00-08:00"),
            ev("e2", "Over", "2026-11-17T08:00:00-08:00", "2026-11-17T09:00:00-08:00"),
            ev("e3", "Offsite", "2026-11-18", "2026-11-19", all_day=True),
            ev("e4", "Too far", "2026-12-17T09:00:00-08:00", "2026-12-17T10:00:00-08:00"),
            ev("e5", "Last day in range", "2026-12-16T22:00:00-08:00", "2026-12-16T23:00:00-08:00"),
        ]},
        tasks={"tasks:L1": [task("a", "Overdue thing", "2026-10-01"), task("b", "Today thing", "2026-11-17"),
                            task("c", "In 29 days", "2026-12-16"), task("d", "In 30 days", "2026-12-17"),
                            task("u1", "Undated one"), task("u2", "Undated two")],
               "tasks:L2": [task("u3", "Undated chore"), task("f", "Chore soon", "2026-11-18")]})
    cfg = cfg_with(right={"sources": ["cal:work@group", "tasks:L1", "tasks:L2"]})
    colors = {"cal:work@group": "teal", "tasks:L1": "blue", "tasks:L2": "rose"}
    items = compose(raw, cfg, colors, LA, NOW)["right"]["items"]
    ids = [i["id"] for i in items]
    # Same due time: by title ("Chore soon" before "Offsite"); 22:00 event before a task due that day.
    assert ids == ["t:a", "e:e1", "t:b", "t:f", "e:e3", "e:e5", "t:c", "t:u1", "t:u2", "t:u3"], ids
    by = {i["id"]: i for i in items}
    assert by["t:a"] == {"id": "t:a", "kind": "task", "list": "L1", "task": "a", "title": "Overdue thing", "allDay": True,
                         "tag": {"label": "Inbox", "color": "blue"}, "due": "2026-10-01T23:59:59-07:00",
                         "overdue": True}
    assert by["t:b"]["due"] == "2026-11-17T23:59:59-08:00" and by["t:b"]["overdue"] is False
    assert by["e:e1"] == {"id": "e:e1", "kind": "event", "title": "Ongoing sync", "due": "2026-11-17T09:30:00-08:00",
                          "start": "2026-11-17T09:30:00-08:00", "end": "2026-11-17T11:00:00-08:00", "allDay": False,
                          "tag": {"label": "Work", "color": "teal"}}
    assert by["e:e3"]["due"] == "2026-11-18T23:59:59-08:00" and by["e:e3"]["allDay"]
    assert by["t:u1"]["due"] is None and by["t:u3"]["tag"] == {"label": "Chores", "color": "rose"}
    assert (by["t:u3"]["list"], by["t:u3"]["task"]) == ("L2", "u3")   # what the page sends to check it off
    assert "list" not in by["e:e1"] and "task" not in by["e:e1"]
    # Keyword filters (events and tasks separately) and a shorter look-ahead.
    cfg = cfg_with(right={"sources": ["cal:work@group", "tasks:L1", "tasks:L2"], "event_keywords": "sync",
                          "task_keywords": "thing, -today", "lookahead_days": 7})
    items = compose(raw, cfg, colors, LA, NOW)["right"]["items"]
    assert [i["id"] for i in items] == ["t:a", "e:e1"]
    # Default right list = every task list, no calendars.
    items = compose(raw, merge_config({}), colors, LA, NOW)["right"]["items"]
    assert [i["id"] for i in items] == ["t:a", "t:b", "t:f", "t:c", "t:u1", "t:u2", "t:u3"]


def test_compose_right_dst_and_caps():
    # Look a year ahead from November: a March event (PDT, -07:00) sorts by real time.
    raw = raw_with(upcoming={"cal:work@group": [
        ev("m1", "After DST", "2027-03-15T08:30:00-07:00", "2027-03-15T09:00:00-07:00"),
        ev("m0", "Same instant UTC", "2027-03-15T15:00:00Z", "2027-03-15T15:30:00Z")]},
        tasks={"tasks:L1": [task(f"d{i:03}", f"Dated {i:03}", (NOW.date() + dt.timedelta(days=i % 300)).isoformat())
                            for i in range(200)] + [task(f"u{i:02}", f"Undated {i:02}") for i in range(60)]})
    cfg = cfg_with(right={"sources": ["cal:work@group", "tasks:L1"], "lookahead_days": 365})
    items = compose(raw, cfg, {}, LA, NOW)["right"]["items"]
    dated = [i for i in items if i["due"]]
    undated = [i for i in items if not i["due"]]
    assert len(dated) == 150 and len(undated) == 50 and items[150:] == undated
    assert [u["id"] for u in undated] == [f"t:u{i:02}" for i in range(50)]
    cfg = cfg_with(right={"sources": ["cal:work@group"], "lookahead_days": 365})
    items = compose(raw, cfg, {}, LA, NOW)["right"]["items"]
    assert [i["id"] for i in items] == ["e:m0", "e:m1"]  # 15:00 UTC = 08:00 PDT, before 08:30 PDT
    assert items[0]["start"] == "2027-03-15T08:00:00-07:00" and items[1]["due"] == "2027-03-15T08:30:00-07:00"


def test_compose_timezone_change():
    raw = raw_with(today={"cal:work@group": [
        ev("a", "All day", "2026-11-18", "2026-11-19", all_day=True),
        ev("b", "Call", "2026-11-17T18:30:00-08:00", "2026-11-17T19:00:00-08:00")]})
    tokyo = ZoneInfo("Asia/Tokyo")  # 10:00 in Seattle = 03:00 next day in Tokyo
    lists = compose(raw, merge_config({}), {}, tokyo, NOW)
    assert lists["date"] == "2026-11-18"
    assert [(e["id"], e["start"]) for e in lists["left"]["events"]] == [
        ("a", "2026-11-18T00:00:00+09:00"), ("b", "2026-11-18T11:30:00+09:00")]
    lists = compose(raw, merge_config({}), {}, LA, NOW)
    assert [e["id"] for e in lists["left"]["events"]] == ["b"]


def test_compose_edge_cases():
    assert compose(None, merge_config({}), {}, LA, NOW) is None
    assert compose({}, merge_config({}), {}, LA, NOW) is None
    empty = compose({"fetched_at": 1}, merge_config({}), {}, LA, NOW)
    assert empty == {"date": "2026-11-17", "left": {"events": [], "tasks": []}, "right": {"items": []}}
    # Categories replace the pill; colours fall back to the first palette colour if never assigned.
    raw = raw_with(tasks={"tasks:L1": [task("x", "Thing", "2026-11-17")]})
    cfg = merge_config({"source_style": {"tasks:L1": {"category": "c1"}},
                        "categories": [{"id": "c1", "name": "Home", "color": "green"}]})
    item = compose(raw, cfg, {}, LA, NOW)["right"]["items"][0]
    assert item["tag"] == {"label": "Home", "color": "green"}
    item = compose(raw, merge_config({}), {}, LA, NOW)["right"]["items"][0]
    assert item["tag"] == {"label": "Inbox", "color": PALETTE_IDS[0]}
    json.dumps(compose(raw, cfg, {}, LA, NOW))  # always JSON-serialisable


# ---------------------------------------------------------------------- hud-core helpers
def test_page_config_and_weather_key():
    from hud.core import page_config, weather_key
    cfg = merge_config({"name": " Alex ", "place": "Lisbon", "lat": 38.7223, "lon": -9.1393,
                        "temperature_unit": "celsius", "wind_unit": "kmh", "clock": "24h",
                        "lists": {"left": {"title": "  "}, "right": {"title": "Next", "countdowns": False}}})
    assert page_config(cfg) == {"name": "Alex", "place": "Lisbon", "lat": 38.7223, "lon": -9.1393,
                                "temperature_unit": "celsius", "wind_unit": "kmh", "clock": "24h",
                                "titles": {"left": "Calendar", "right": "Next"}, "countdowns": False,
                                "theme": "adaptive", "parallax": True, "weather_animation": True,
                                "weather_detail": "high", "open_animation_s": 1.0, "close_animation_s": 0.75,
                                "open_animation": "fade", "close_animation": "fade",
                                "scroll_speed_vertical": 1.0, "scroll_speed_horizontal": 1.0,
                                "scroll_reverse_vertical": False, "scroll_reverse_horizontal": False}
    prefs = merge_config({"theme": "light", "parallax": False, "weather_animation": False, "weather_detail": "medium",
                          "scroll_reverse_vertical": True, "scroll_reverse_horizontal": False, "hotkey": {"key_code": 4},
                          "dark_mean": 3})
    pc = page_config(prefs)
    assert (pc["theme"], pc["parallax"], pc["weather_animation"], pc["weather_detail"],
            pc["scroll_reverse_vertical"], pc["scroll_reverse_horizontal"]) == ("light", False, False, "medium", True, False)
    assert "hotkey" not in pc and "dark_mean" not in pc   # only what the page needs
    pc = page_config(merge_config({"open_animation_s": 0, "close_animation_s": 1.5}))
    assert (pc["open_animation_s"], pc["close_animation_s"]) == (0.0, 1.5)
    for given, want in ((1.5, 1.5), (0.1, 0.5), (9, 2.0), ("fast", 1.0), (True, 1.0), (None, 1.0), (float("nan"), 1.0)):
        pc = page_config(merge_config({"scroll_speed_vertical": given, "scroll_speed_horizontal": given}))
        assert (pc["scroll_speed_vertical"], pc["scroll_speed_horizontal"]) == (want, want), given
    pc = page_config(merge_config({"open_animation": "shatter", "close_animation": "swirl"}))
    assert (pc["open_animation"], pc["close_animation"]) == ("shatter", "swirl")
    for bad in ("bogus", "ZOOM", 7, None, ["zoom"]):   # anything else is the default
        cfg_bad = merge_config({"open_animation": bad, "close_animation": bad})
        assert (cfg_bad["open_animation"], cfg_bad["close_animation"]) == ("fade", "fade"), bad
    assert weather_key(cfg, "Europe/Lisbon") == [38.7, -9.1, "celsius", "kmh", "Europe/Lisbon"]
    assert weather_key(merge_config({}), "UTC") is None
    moved = merge_config({**cfg, "lat": 38.7301})  # a few hundred metres: same request, no refetch
    assert weather_key(moved, "Europe/Lisbon") == weather_key(cfg, "Europe/Lisbon")


def test_local_request():
    from hud.core import local_request
    ok = [("127.0.0.1:47780", None), ("localhost:47780", None), ("127.0.0.1", None), ("LOCALHOST:47780", None),
          ("127.0.0.1:47780", "http://127.0.0.1:47780"), ("127.0.0.1:47780", "http://localhost:47780")]
    for host, origin in ok:
        assert local_request(host, origin, 47780), (host, origin)
    bad = [(None, None), ("", None), ("evil.example:47780", None),                  # DNS rebinding
           ("127.0.0.1.evil.example:47780", None),
           ("127.0.0.1:47780", "https://evil.example"),                            # any website's WebSocket
           ("127.0.0.1:47780", "http://127.0.0.1:3000"), ("127.0.0.1:47780", "null"),
           ("127.0.0.1:47780", "https://127.0.0.1:47780"), ("127.0.0.1:47780", "http://[::1"),
           ("127.0.0.1:47780", "")]
    for host, origin in bad:
        assert not local_request(host, origin, 47780), (host, origin)


# ---------------------------------------------------------------------- Google parsing
def test_event_parsing():
    base = {"id": "x", "summary": " Lunch ", "start": {"dateTime": "2026-11-17T12:00:00-08:00"},
            "end": {"dateTime": "2026-11-17T13:00:00-08:00"}, "location": "Cafe"}
    assert _event(base) == {"id": "x", "title": "Lunch", "location": "Cafe", "allDay": False,
                            "start": "2026-11-17T12:00:00-08:00", "end": "2026-11-17T13:00:00-08:00"}
    assert _event({**base, "status": "cancelled"}) is None
    assert _event({**base, "eventType": "workingLocation"}) is None
    assert _event({**base, "attendees": [{"self": True, "responseStatus": "declined"}]}) is None
    assert _event({**base, "attendees": [{"self": False, "responseStatus": "declined"}]}) is not None
    assert _event({**base, "start": {"dateTime": "2026-11-17T12:00:00"}}) is None   # no offset
    assert _event({**base, "start": {}}) is None
    assert _event({**base, "id": ""}) is None
    assert _event({**base, "summary": "  "})["title"] == "(No title)"
    utc = _event({**base, "start": {"dateTime": "2026-11-17T20:00:00Z"}, "end": {}})
    assert utc["start"] == utc["end"] == "2026-11-17T20:00:00+00:00"
    allday = _event({"id": "y", "start": {"date": "2026-11-17"}, "end": {}})
    assert allday["allDay"] and allday["start"] == "2026-11-17" and allday["end"] == "2026-11-18"


def test_order_tasks():
    items = [{"id": "c", "title": "Child of a", "parent": "a", "position": "00000000000000000000"},
             {"id": "b", "title": "Second", "position": "00000000000000000002", "due": "2026-11-20T00:00:00.000Z"},
             {"id": "a", "title": "First", "position": "00000000000000000001"},
             {"id": "d", "title": "Done", "position": "00000000000000000000", "status": "completed"},
             {"id": "e", "title": "   ", "position": "00000000000000000003"},
             {"id": "f", "title": "Orphan", "parent": "zz", "position": "00000000000000000004"}]
    assert _order_tasks(items) == [{"id": "a", "title": "First", "due": None},
                                   {"id": "c", "title": "Child of a", "due": None},
                                   {"id": "b", "title": "Second", "due": "2026-11-20"},
                                   {"id": "f", "title": "Orphan", "due": None}]


# ---------------------------------------------------------------------- Google.fetch (faked API)
def test_google_fetch_plan():
    calls = []
    cal_list = [{"id": "work@group", "summary": "Work", "selected": True},
                {"id": "fam@group", "summary": "fam", "summaryOverride": "Family", "selected": True},
                {"id": "gone@group", "summary": "Gone", "selected": True},
                {"id": "h@group", "summary": "Hidden", "selected": True, "hidden": True}]

    def page(n, start, prefix):
        return [{"id": f"{prefix}{i}", "summary": f"{prefix} {i}",
                 "start": {"dateTime": (start + dt.timedelta(minutes=i)).isoformat()},
                 "end": {"dateTime": (start + dt.timedelta(minutes=i + 30)).isoformat()}} for i in range(n)]

    async def fake_get(self, url, params=None):
        params = dict(params or {})
        calls.append((url, params))
        if url.endswith("/users/me/calendarList"):
            return {"items": cal_list}
        if url.endswith("/users/@me/lists"):
            return {"items": [{"id": "L1", "title": "Inbox"}, {"id": "L2", "title": "Chores"}]}
        if "gone%40group" in url:
            raise NotFound("GET ... -> 404")
        if "/lists/" in url:
            return {"items": [{"id": "t1", "title": "Thing", "position": "1", "due": "2026-11-17T00:00:00.000Z"}]}
        if "work%40group" in url:
            # Endless pages: today's request must stop after 1000 events read, the
            # upcoming one as soon as 150 matching events are kept.
            start = dt.datetime.fromisoformat(params["timeMin"])
            n = int(params.get("pageToken", 0))
            return {"items": page(250, start + dt.timedelta(hours=n), f"p{n}-"), "nextPageToken": str(n + 1)}
        return {"items": []}

    real_get = Google._get
    Google._get = fake_get
    try:
        cfg = cfg_with(left={"sources": ["cal:work@group", "cal:gone@group", "tasks:L1"]},
                       right={"sources": ["cal:work@group", "tasks:L1", "tasks:L2"], "event_keywords": "p0"})
        g = Google(session=None)
        raw = asyncio.run(g.fetch(cfg, LA))
    finally:
        Google._get = real_get

    urls = [u for u, _ in calls]
    meta = [p for u, p in calls if u.endswith("calendarList")]
    assert meta and meta[0]["showHidden"] == "true"
    assert [c["name"] for c in raw["calendars"]] == ["Work", "Family", "Gone", "Hidden"]
    assert raw["calendars"][3]["hidden"] is True
    assert sum("/lists/L1/tasks" in u for u in urls) == 1          # in both lists, fetched once
    assert sum("/lists/L2/tasks" in u for u in urls) == 1
    assert not any("fam%40group/events" in u for u in urls)         # in neither list
    assert not any("q" in p for _, p in calls)
    assert raw["today"]["cal:gone@group"] == [] and "cal:gone@group" not in raw["upcoming"]
    assert g.cached_metadata() is None                              # 404: metadata re-read next time
    work = [p for u, p in calls if "work%40group/events" in u]
    today = [p for p in work if p["timeMin"].endswith("T00:00:00-08:00")]
    upcoming = [p for p in work if p not in today]
    assert len(today) == 4 and len(raw["today"]["cal:work@group"]) == 1000
    assert len(upcoming) == 1 and len(raw["upcoming"]["cal:work@group"]) == 250
    assert all(p["singleEvents"] == "true" and p["orderBy"] == "startTime" for p in work)
    assert upcoming[0]["timeMax"].startswith((dt.datetime.now(LA).date() + dt.timedelta(days=30)).isoformat())
    assert raw["tasks"]["tasks:L1"] == [{"id": "t1", "title": "Thing", "due": "2026-11-17"}]
    assert raw["tz"] == "America/Los_Angeles"   # a new time zone refetches
    json.dumps(raw)


def test_google_get_errors():
    """HTTP errors become NotFound (skip the source), Forbidden (API off limits: skip that
    side) or RuntimeError (try again later)."""
    class Resp:
        def __init__(self, status, text):
            self.status, self._text = status, text

        async def text(self):
            return self._text

        async def json(self):
            return json.loads(self._text)

        async def __aenter__(self):
            return self

        async def __aexit__(self, *a):
            return False

    class Session:
        def __init__(self, resp):
            self.resp = resp

        def get(self, url, **kw):
            return self.resp

    disabled = json.dumps({"error": {"code": 403, "message": "Google Tasks API has not been used in project 1 "
                                     "before or it is disabled.", "errors": [{"reason": "accessNotConfigured"}]}})
    cases = [(404, "{}", NotFound), (410, "{}", NotFound), (403, disabled, Forbidden),
             (403, '{"error": {"message": "Request had insufficient authentication scopes."}}', Forbidden),
             (403, '{"error": {"errors": [{"reason": "rateLimitExceeded"}]}}', RuntimeError),
             (500, "oops", RuntimeError)]
    for status, body, want in cases:
        g = Google(Session(Resp(status, body)))
        g._access, g._access_exp = "tok", 1e12
        try:
            asyncio.run(g._get("https://example.invalid/x"))
            raise AssertionError(f"{status} did not raise")
        except want as e:
            assert type(e) is want, (status, type(e))
    g = Google(Session(Resp(200, '{"items": [1]}')))
    g._access, g._access_exp = "tok", 1e12
    assert asyncio.run(g._get("https://example.invalid/x")) == {"items": [1]}


def test_google_token_refresh_client_secret():
    """The refresh request sends client_secret only when the client has one: a PKCE-only
    client (empty or missing secret) must not send the field at all."""
    from hud import gcal

    class Resp:
        status = 200

        async def json(self, content_type=None):
            return {"access_token": "AT", "expires_in": 3600}

        async def __aenter__(self):
            return self

        async def __aexit__(self, *a):
            return False

    class Session:
        def __init__(self):
            self.posts = []

        def post(self, url, data=None, **kw):
            self.posts.append((url, dict(data)))
            return Resp()

    old = gcal.CLIENT_FILE, gcal.TOKEN_FILE
    gcal.CLIENT_FILE, gcal.TOKEN_FILE = Path(_TMP) / "gc-client.json", Path(_TMP) / "gc-token.json"
    try:
        gcal.TOKEN_FILE.write_text(json.dumps({"refresh_token": "RT"}))
        for client, want_secret in (({"client_id": "ID", "client_secret": ""}, None),
                                    ({"client_id": "ID"}, None),
                                    ({"client_id": "ID", "client_secret": None}, None),
                                    ({"client_id": "ID", "client_secret": "  "}, None),
                                    ({"client_id": "ID", "client_secret": "S3"}, "S3")):
            gcal.CLIENT_FILE.write_text(json.dumps(client))
            s = Session()
            g = Google(s)
            assert asyncio.run(g._token()) == "AT"
            (url, data), = s.posts
            assert url == gcal.TOKEN_URL
            assert data["client_id"] == "ID" and data["refresh_token"] == "RT"
            assert data["grant_type"] == "refresh_token"
            if want_secret is None:
                assert "client_secret" not in data, client
            else:
                assert data["client_secret"] == want_secret
            assert asyncio.run(g._token()) == "AT" and len(s.posts) == 1   # cached until near expiry
    finally:
        gcal.CLIENT_FILE, gcal.TOKEN_FILE = old


def test_read_obj():
    p = Path(_TMP) / "obj.json"
    for text, want in (('{"a": 1}', {"a": 1}), ("[1]", {}), ("nope", {}), ("null", {})):
        p.write_text(text)
        assert read_obj(p) == want, text
    assert read_obj(Path(_TMP) / "missing.json") == {}


def main():
    tests = [(n, f) for n, f in sorted(globals().items()) if n.startswith("test_") and callable(f)]
    failed = 0
    for name, fn in tests:
        try:
            fn()
            print("PASS", name)
        except Exception as e:  # noqa: BLE001
            failed += 1
            import traceback
            print("FAIL", name)
            traceback.print_exc()
    print(f"\n{len(tests) - failed}/{len(tests)} passed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
