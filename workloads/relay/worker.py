"""Glue between the arr stack and what it lacks. Gives Spanish subtitles to the episodes Sonarr imports, through Bazarr and Lingarr."""

import asyncio
import contextlib
import html
import json
import logging
import os
import re
import time
from datetime import datetime

import httpx
import redis.asyncio as aioredis
from fastapi import FastAPI, Request
from fastapi.responses import HTMLResponse, JSONResponse
from redis.exceptions import RedisError

logging.basicConfig(
    level=os.environ.get("LOG_LEVEL", "INFO"),
    format="%(asctime)s %(levelname)s %(name)s %(message)s",
)
logging.getLogger("httpx").setLevel(logging.WARNING)
log = logging.getLogger("relay")

LEDGER_PREFIX = "autosubtitle:requested:"
# A request is forgotten once Bazarr holds no translation job; this expiry only
# covers a queue that never drains.
LEDGER_TTL = 10800
# Translation jobs allowed in Bazarr's queue at once, pending or running.
SLOTS = 6
WINDOW = 180
POLL = 10
SEARCH_TIMEOUT = 600
# Bazarr can finish its own search a moment before Sonarr's call reaches us.
SINCE_MARGIN = 120
# Sonarr's title for an episode TheTVDB has not named yet. The wait stays under
# KubeElasti's 30-minute cooldown so the pod is not scaled down mid-loop.
SONARR_TBA = "TBA"
REFRESH_INTERVAL = 300
REFRESH_ATTEMPTS = 5
SEARCH_JOB_PREFIX ="Downloading missing subtitles for"
TRANSLATION_JOB_PREFIXES = ("Extracting and translating", "Translating from")


class RedisUnavailable(Exception):
    pass


class BazarrUnavailable(Exception):
    pass


class SonarrUnavailable(Exception):
    pass


def ledger_key(episode_id):
    return f"{LEDGER_PREFIX}{episode_id}"


async def ledger_claim(redis, episode_id):
    try:
        return bool(await redis.set(ledger_key(episode_id), "1", nx=True, ex=LEDGER_TTL))
    except (RedisError, OSError) as error:
        raise RedisUnavailable(str(error)) from error


async def ledger_release(redis, episode_id):
    try:
        await redis.delete(ledger_key(episode_id))
    except (RedisError, OSError) as error:
        raise RedisUnavailable(str(error)) from error


async def ledger_clear(redis):
    try:
        keys = [key async for key in redis.scan_iter(match=f"{LEDGER_PREFIX}*")]
        if keys:
            await redis.delete(*keys)
        return len(keys)
    except (RedisError, OSError) as error:
        raise RedisUnavailable(str(error)) from error


def pick_track(tracks):
    english = [
        t for t in tracks
        if t["code2"] == "en" and not re.search("signs|songs", t["title"], re.IGNORECASE)
    ]
    for t in english:
        if re.search("dialog|full", t["title"], re.IGNORECASE):
            return t
    return english[0] if english else None


async def embedded_tracks(bazarr, episode_id):
    episode = await bazarr.episode(episode_id)
    if episode is None:
        return []
    entries = sorted(
        (s for s in episode["subtitles"] if s.get("path") is None and s.get("embedded_track_id") is not None),
        key=lambda s: s["embedded_track_id"],
    )
    titles = await bazarr.subtitle_titles(episode["path"], episode_id)
    return [{"id": e["id"], "code2": e["code2"], "title": title} for e, title in zip(entries, titles)]


class Bazarr:
    def __init__(self, base_url, api_key, client=None):
        self._base = base_url.rstrip("/")
        self._headers = {"X-API-KEY": api_key}
        self._client = client or httpx.AsyncClient(timeout=30)

    async def _send(self, method, path, **kwargs):
        try:
            response = await self._client.request(method, self._base + path, headers=self._headers, **kwargs)
        except httpx.HTTPError as error:
            raise BazarrUnavailable(str(error)) from error
        if response.status_code == 401:
            raise BazarrUnavailable("Bazarr rejected the API key")
        return response

    async def _data(self, path, **params):
        response = await self._send("GET", path, params=params)
        if response.status_code >= 400:
            raise BazarrUnavailable(f"GET {path} answered {response.status_code}")
        try:
            return response.json()["data"]
        except (ValueError, KeyError) as error:
            raise BazarrUnavailable(f"GET {path} returned an unexpected body") from error

    async def wanted(self):
        return await self._data("/api/episodes/wanted", start=0, length=-1)

    async def episode(self, episode_id):
        data = await self._data("/api/episodes", **{"episodeid[]": episode_id})
        return data[0] if data else None

    async def subtitle_titles(self, video_path, episode_id):
        data = await self._data("/api/subtitles", subtitlesPath=video_path, sonarrEpisodeId=episode_id)
        return [track["name"] for track in data["embedded_subtitles_tracks"]]

    async def jobs(self):
        return await self._data("/api/system/jobs")

    async def search_series(self, series_id):
        response = await self._send("PATCH", "/api/series", params={"seriesid": series_id, "action": "search-missing"})
        if response.status_code >= 400:
            raise BazarrUnavailable(f"search of series {series_id} answered {response.status_code}")

    async def translate(self, episode_id, subtitles_id):
        response = await self._send(
            "PATCH",
            "/api/subtitles",
            data={
                "action": "translate",
                "language": "es",
                "type": "episode",
                "id": episode_id,
                "subtitles_id": subtitles_id,
                "forced": "False",
                "hi": "False",
            },
        )
        return response.status_code


class Sonarr:
    def __init__(self, base_url, api_key, client=None):
        self._base = base_url.rstrip("/")
        self._headers = {"X-Api-Key": api_key}
        self._client = client or httpx.AsyncClient(timeout=30)

    async def _json(self, method, path, **kwargs):
        try:
            response = await self._client.request(method, self._base + path, headers=self._headers, **kwargs)
        except httpx.HTTPError as error:
            raise SonarrUnavailable(str(error)) from error
        if response.status_code >= 400:
            raise SonarrUnavailable(f"{method} {path} answered {response.status_code}")
        try:
            return response.json()
        except ValueError as error:
            raise SonarrUnavailable(f"{method} {path} returned an unexpected body") from error

    async def all_series(self):
        return await self._json("GET", "/api/v3/series")

    async def series(self, series_id):
        return await self._json("GET", f"/api/v3/series/{series_id}")

    async def delete_series(self, series_id):
        await self._json(
            "DELETE", f"/api/v3/series/{series_id}",
            params={"deleteFiles": "true", "addImportListExclusion": "false"},
        )

    async def episodes(self, series_id):
        return await self._json("GET", "/api/v3/episode", params={"seriesId": series_id})

    async def refresh_pending(self, series_id):
        commands = await self._json("GET", "/api/v3/command")
        return any(
            c["name"] == "RefreshSeries"
            and c["status"] in ("queued", "started")
            and series_id in (c.get("body") or {}).get("seriesIds", [])
            for c in commands
        )

    async def refresh(self, series_id):
        await self._json("POST", "/api/v3/command", json={"name": "RefreshSeries", "seriesId": series_id})


async def refresh_until_titled(sonarr, series_id, named, sleep, interval=REFRESH_INTERVAL, attempts=REFRESH_ATTEMPTS):
    """Refreshes a series until its named episodes lose the TBA title or reach disk.

    Sonarr refuses to import a recently aired episode whose cached title is TBA, and it
    only re-reads TheTVDB on its own schedule. `named` is read on every pass, so a grab
    that arrives during the loop joins it instead of starting another.
    """
    for attempt in range(attempts):
        try:
            untitled = [
                e for e in await sonarr.episodes(series_id)
                if e["id"] in named and not e["hasFile"] and e["title"] in ("", SONARR_TBA)
            ]
            if not untitled:
                return True
            if not await sonarr.refresh_pending(series_id):
                await sonarr.refresh(series_id)
                log.info("REFRESH_REQUESTED series=%s episodes=%s", series_id, [e["id"] for e in untitled])
        except SonarrUnavailable as error:
            log.warning("SONARR_UNAVAILABLE %s", error)
        if attempt < attempts - 1:
            await sleep(interval)
    log.warning("TITLE_STILL_MISSING series=%s", series_id)
    return False


def parse_episode_number(text):
    season, episode = text.split("x")
    return int(season), int(episode)


async def wait_until_known(bazarr, wanted, named_ids, now, sleep, window=WINDOW, poll=POLL):
    deadline = now() + window
    while True:
        listed = {e["sonarrEpisodeId"] for e in wanted}
        unknown = set()
        for episode_id in named_ids:
            if episode_id not in listed and await bazarr.episode(episode_id) is None:
                unknown.add(episode_id)
        if not unknown or now() >= deadline:
            return wanted
        await sleep(poll)
        wanted = await bazarr.wanted()


def _epoch(text):
    try:
        return datetime.fromisoformat(text).timestamp()
    except (TypeError, ValueError):
        return 0.0


async def await_search(bazarr, series_id, series_title, named, now, sleep, wall=time.time,
                       since=None, window=WINDOW, poll=POLL, timeout=SEARCH_TIMEOUT):
    def mine(item):
        return item["job_name"].startswith(SEARCH_JOB_PREFIX) and series_title in item["job_name"]

    async def snapshot(cutoff):
        jobs = [j for j in await bazarr.jobs() if mine(j)]
        active = [j for j in jobs if j["status"] in ("pending", "running")]
        done = [
            j for j in jobs
            if j["status"] in ("completed", "failed")
            and (cutoff is None or _epoch(j.get("last_run_time")) >= cutoff)
        ]
        return active, done

    async def wait_for_finish(cutoff):
        deadline = now() + timeout
        while True:
            active, done = await snapshot(cutoff)
            if done and not active:
                return True
            if now() >= deadline:
                return False
            await sleep(poll)

    if named:
        deadline = now() + window
        while True:
            active, done = await snapshot(since)
            if active or done:
                return await wait_for_finish(since)
            if now() >= deadline:
                break
            await sleep(poll)
    # Two seconds of tolerance for the clock difference with Bazarr's job times.
    cutoff = wall() - 2
    await bazarr.search_series(series_id)
    return await wait_for_finish(cutoff)


async def await_searches(bazarr, episodes, named_ids, now, sleep, wall=time.time, since=None):
    series = {}
    for episode in episodes:
        entry = series.setdefault(episode["sonarrSeriesId"], {"title": episode["seriesTitle"], "named": False})
        entry["named"] = entry["named"] or episode["sonarrEpisodeId"] in named_ids
    resolved = {}
    for series_id, entry in series.items():
        resolved[series_id] = await await_search(
            bazarr, series_id, entry["title"], entry["named"], now, sleep, wall=wall, since=since,
        )
    return resolved


def translation_jobs_in_flight(jobs):
    return sum(
        1 for j in jobs
        if j["job_name"].startswith(TRANSLATION_JOB_PREFIXES) and j["status"] in ("pending", "running")
    )


def priority(episode):
    season, number = parse_episode_number(episode["episode_number"])
    return number, season, episode["seriesTitle"].lower()


async def request_translations(bazarr, redis, candidates, in_flight):
    if in_flight == 0:
        await ledger_clear(redis)
    requested = []
    for episode in sorted(candidates, key=priority):
        if SLOTS - in_flight - len(requested) <= 0:
            break
        episode_id = episode["sonarrEpisodeId"]
        if not await ledger_claim(redis, episode_id):
            continue
        track = pick_track(await embedded_tracks(bazarr, episode_id))
        if track is None:
            log.warning("NO_TRANSLATABLE_TRACK episode=%s", episode_id)
            await ledger_release(redis, episode_id)
            continue
        status = await bazarr.translate(episode_id, track["id"])
        if status == 204:
            requested.append(episode_id)
            continue
        await ledger_release(redis, episode_id)
        # Bazarr answers 415 for image-based subtitle tracks, which it cannot extract.
        code = "NO_TRANSLATABLE_TRACK" if status == 415 else "TRANSLATE_REJECTED"
        log.warning("%s episode=%s status=%s", code, episode_id, status)
    return requested


def _bazarr_from_env():
    return Bazarr(
        os.environ.get("BAZARR_URL", "http://bazarr.media.svc.cluster.local:6767"),
        os.environ.get("BAZARR_API_KEY", ""),
    )


def _sonarr_from_env():
    return Sonarr(
        os.environ.get("SONARR_URL", "http://sonarr.media.svc.cluster.local:8989"),
        os.environ.get("SONARR_API_KEY", ""),
    )


async def clear_overseerr(tvdb_id, base_url, api_key, client=None):
    """Drop the media entry, and with it the requests, so the show can be requested again."""
    if not (tvdb_id and api_key):
        return "skipped"
    client = client or httpx.AsyncClient(timeout=30)
    headers = {"X-Api-Key": api_key}
    try:
        listing = await client.get(f"{base_url}/api/v1/media", headers=headers, params={"take": 1000, "filter": "all"})
        listing.raise_for_status()
        ids = [m["id"] for m in listing.json()["results"] if m.get("mediaType") == "tv" and m.get("tvdbId") == tvdb_id]
        for media_id in ids:
            (await client.delete(f"{base_url}/api/v1/media/{media_id}", headers=headers)).raise_for_status()
    except (httpx.HTTPError, KeyError, ValueError) as error:
        log.warning("OVERSEERR_UNAVAILABLE %s", error)
        return "failed"
    return "deleted" if ids else "none"


def _redis_from_env():
    return aioredis.Redis(
        host=os.environ.get("REDIS_HOST", "redis.internal.cristianpuenguenan.online"),
        port=int(os.environ.get("REDIS_PORT", "6379")),
        password=os.environ.get("REDIS_PASSWORD") or None,
        decode_responses=True,
        socket_connect_timeout=5,
        socket_timeout=10,
    )


async def run_cycle(named_ids, *, bazarr=None, redis=None, now=time.monotonic, sleep=asyncio.sleep,
                    wall=time.time, since=None):
    result = {"requested": [], "skipped": []}
    bazarr = bazarr or _bazarr_from_env()
    try:
        wanted = await bazarr.wanted()
        wanted = await wait_until_known(bazarr, wanted, named_ids, now, sleep)
        resolved = await await_searches(bazarr, wanted, named_ids, now, sleep, wall=wall, since=since)
        wanted = await bazarr.wanted()
        jobs = await bazarr.jobs()
    except BazarrUnavailable as error:
        log.warning("BAZARR_UNAVAILABLE %s", error)
        return result

    candidates = []
    for episode in wanted:
        series_id = episode["sonarrSeriesId"]
        if series_id not in resolved:
            continue
        if resolved[series_id]:
            candidates.append(episode)
        else:
            result["skipped"].append(f"search_unresolved episode={episode['sonarrEpisodeId']}")

    owns_redis = redis is None
    redis = redis or _redis_from_env()
    try:
        result["requested"] = await request_translations(
            bazarr, redis, candidates, translation_jobs_in_flight(jobs),
        )
    except RedisUnavailable as error:
        log.warning("REDIS_UNAVAILABLE %s", error)
    except BazarrUnavailable as error:
        log.warning("BAZARR_UNAVAILABLE %s", error)
    finally:
        if owns_redis:
            with contextlib.suppress(RedisError, OSError):
                await redis.aclose()
    log.info("run finished requested=%s skipped=%s", result["requested"], result["skipped"])
    return result


app = FastAPI(docs_url=None, redoc_url=None, openapi_url=None)

_state = {"running": False, "pending": False, "named": set(), "since": None}
_tasks = set()


def trigger(episode_ids):
    _state["named"] |= set(episode_ids)
    if _state["since"] is None:
        _state["since"] = time.time() - SINCE_MARGIN
    if _state["running"]:
        _state["pending"] = True
        return "queued"
    _state["running"] = True
    task = asyncio.get_running_loop().create_task(_drain())
    _tasks.add(task)
    task.add_done_callback(_tasks.discard)
    return "started"


async def _drain():
    try:
        while True:
            named, since = _state["named"], _state["since"]
            _state.update(named=set(), since=None, pending=False)
            try:
                await run_cycle(named, since=since)
            except Exception:
                log.exception("run failed")
            if not _state["pending"]:
                break
    finally:
        _state["running"] = False


def _episode_ids(body):
    try:
        data = json.loads(body)
    except ValueError:
        return set()
    episodes = data.get("episodes") if isinstance(data, dict) else None
    if not isinstance(episodes, list):
        return set()
    return {e["id"] for e in episodes if isinstance(e, dict) and isinstance(e.get("id"), int)}


# Series being refreshed, with the episode ids their loop is watching.
_refreshing = {}


def trigger_refresh(series_id, episode_ids):
    if series_id in _refreshing:
        _refreshing[series_id] |= episode_ids
        return "joined"
    _refreshing[series_id] = set(episode_ids)
    task = asyncio.get_running_loop().create_task(_refresh(series_id))
    _tasks.add(task)
    task.add_done_callback(_tasks.discard)
    return "started"


async def _refresh(series_id):
    try:
        await refresh_until_titled(_sonarr_from_env(), series_id, _refreshing[series_id], asyncio.sleep)
    except Exception:
        log.exception("refresh failed")
    finally:
        _refreshing.pop(series_id, None)


def _grab(body):
    try:
        data = json.loads(body)
    except ValueError:
        return None, set()
    if not isinstance(data, dict) or data.get("eventType") != "Grab":
        return None, set()
    series = data.get("series")
    series_id = series.get("id") if isinstance(series, dict) else None
    if not isinstance(series_id, int):
        return None, set()
    return series_id, _episode_ids(body)


@app.post("/metadata/refresh", status_code=202, operation_id="refreshSeriesMetadata")
async def post_metadata_refresh(request: Request):
    series_id, episode_ids = _grab(await request.body())
    if series_id is None:
        return JSONResponse({"state": "ignored"}, status_code=202)
    return JSONResponse({"state": trigger_refresh(series_id, episode_ids)}, status_code=202)


@app.post("/subtitles/run", status_code=202, operation_id="runSubtitleCycle")
async def post_run(request: Request):
    state = trigger(_episode_ids(await request.body()))
    return JSONResponse({"state": state}, status_code=202)


@app.get("/healthz", operation_id="getWorkerHealth")
async def get_healthz():
    return {"status": "ok"}


_PAGE = """<!doctype html><meta charset=utf-8><meta name=viewport content="width=device-width">
<title>Series</title><style>body{font:16px sans-serif;max-width:40rem;margin:1rem auto;padding:0 1rem}
li{display:flex;justify-content:space-between;align-items:center;padding:.4rem 0;border-bottom:1px solid #8884}
small{opacity:.6}button{background:#c33;color:#fff;border:0;border-radius:4px;padding:.4rem .8rem}</style>
<h1>Series</h1><ul>%s</ul><script>
async function del(b){b.disabled=true;const r=await fetch('/series/'+b.dataset.id+'/delete',{method:'POST'});
if(r.ok)b.closest('li').remove();else{b.disabled=false;b.textContent='Error'}}
</script>"""


@app.get("/series", response_class=HTMLResponse, operation_id="listSeries")
async def get_series():
    series = await _sonarr_from_env().all_series()
    rows = "".join(
        f"<li><span>{html.escape(s['title'])} <small>{s.get('year', '')} · "
        f"{s.get('statistics', {}).get('sizeOnDisk', 0) / 2**30:.1f} GB</small></span>"
        f"<button data-id={int(s['id'])} onclick=del(this)>Borrar</button></li>"
        for s in sorted(series, key=lambda s: s["title"].lower())
    )
    return _PAGE % rows


@app.post("/series/{series_id}/delete", operation_id="deleteSeries")
async def post_series_delete(series_id: int):
    sonarr = _sonarr_from_env()
    try:
        tvdb_id = (await sonarr.series(series_id)).get("tvdbId")
        await sonarr.delete_series(series_id)
    except SonarrUnavailable as error:
        log.warning("SERIES_DELETE_FAILED %s", error)
        return JSONResponse({"state": "failed"}, status_code=502)
    overseerr = await clear_overseerr(
        tvdb_id,
        os.environ.get("OVERSEERR_URL", "http://overseerr.media.svc.cluster.local:5055"),
        os.environ.get("OVERSEERR_API_KEY", ""),
    )
    log.info("SERIES_DELETED series=%s overseerr=%s", series_id, overseerr)
    return {"state": "deleted", "overseerr": overseerr}
