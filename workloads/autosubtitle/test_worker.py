import asyncio
import json
import unittest
from datetime import datetime, timezone
from unittest import mock

import httpx
import redis.exceptions

import worker

BASE_EPOCH = 1_793_000_000.0


class Clock:
    def __init__(self):
        self.t = 0.0

    def now(self):
        return self.t

    async def sleep(self, seconds):
        self.t += seconds

    def wall(self):
        return BASE_EPOCH + self.t


class FakeRedis:
    def __init__(self, keys=None, error=None):
        self.store = dict.fromkeys(keys or [], "1")
        self.set_calls = []
        self.error = error

    async def set(self, key, value, nx=False, ex=None):
        if self.error:
            raise self.error
        self.set_calls.append((key, nx, ex))
        if nx and key in self.store:
            return None
        self.store[key] = value
        return True

    async def scan_iter(self, match=None):
        if self.error:
            raise self.error
        prefix = (match or "").rstrip("*")
        for key in list(self.store):
            if key.startswith(prefix):
                yield key

    async def delete(self, *keys):
        if self.error:
            raise self.error
        return sum(self.store.pop(key, None) is not None for key in keys)


def wanted_episode(episode_id, series_id, series_title, number):
    return {
        "sonarrEpisodeId": episode_id,
        "sonarrSeriesId": series_id,
        "seriesTitle": series_title,
        "episode_number": number,
        "missing_subtitles": [{"code2": "es"}],
    }


def job(job_id, name, status, wall=BASE_EPOCH):
    return {
        "job_id": job_id,
        "job_name": name,
        "status": status,
        "last_run_time": datetime.fromtimestamp(wall, timezone.utc).isoformat(),
    }


SIGNS = "Signs & Songs - ENG ASS"
DIALOG = "Dialog - ENG ASS"


class FakeBazarr:
    def __init__(self, clock, wanted=(), on_search=None, stuck_series=()):
        self.clock = clock
        self.wanted_list = list(wanted)
        self.known = {e["sonarrEpisodeId"] for e in self.wanted_list}
        self.titles_by_series = {e["sonarrSeriesId"]: e["seriesTitle"] for e in self.wanted_list}
        self.job_list = []
        self.search_calls = []
        self.translate_calls = []
        self.statuses = {}
        self.on_search = on_search
        self.stuck_series = set(stuck_series)
        self.titles = [SIGNS, DIALOG]
        self.down = False

    async def wanted(self):
        if self.down:
            raise worker.BazarrUnavailable("down")
        return list(self.wanted_list)

    async def episode(self, episode_id):
        if episode_id not in self.known:
            return None
        return {
            "path": f"/data/{episode_id}.mkv",
            "subtitles": [
                {"path": None, "embedded_track_id": 3, "id": episode_id * 10, "code2": "en"},
                {"path": None, "embedded_track_id": 4, "id": episode_id * 10 + 1, "code2": "en"},
            ],
        }

    async def subtitle_titles(self, video_path, episode_id):
        return list(self.titles)

    async def jobs(self):
        return list(self.job_list)

    async def search_series(self, series_id):
        self.search_calls.append(series_id)
        status = "running" if series_id in self.stuck_series else "completed"
        name = f"Downloading missing subtitles for {self.titles_by_series[series_id]}"
        self.job_list.append(job(100 + len(self.job_list), name, status, self.clock.wall()))
        if self.on_search:
            self.on_search(series_id)

    async def translate(self, episode_id, subtitles_id):
        self.translate_calls.append((episode_id, subtitles_id))
        return self.statuses.get(episode_id, 204)


class LedgerTest(unittest.IsolatedAsyncioTestCase):
    async def test_claiming_twice_only_succeeds_once(self):
        redis_client = FakeRedis()
        self.assertTrue(await worker.ledger_claim(redis_client, 721))
        self.assertFalse(await worker.ledger_claim(redis_client, 721))

    async def test_claim_expires_after_three_hours(self):
        redis_client = FakeRedis()
        await worker.ledger_claim(redis_client, 721)
        self.assertEqual(redis_client.set_calls, [("autosubtitle:requested:721", True, 10800)])

    async def test_released_episode_can_be_claimed_again(self):
        redis_client = FakeRedis()
        await worker.ledger_claim(redis_client, 721)
        await worker.ledger_release(redis_client, 721)
        self.assertTrue(await worker.ledger_claim(redis_client, 721))

    async def test_clear_deletes_only_ledger_keys(self):
        redis_client = FakeRedis(["autosubtitle:requested:721", "autosubtitle:requested:722", "other:1"])
        self.assertEqual(await worker.ledger_clear(redis_client), 2)
        self.assertEqual(set(redis_client.store), {"other:1"})

    async def test_redis_error_becomes_unavailable(self):
        redis_client = FakeRedis(error=redis.exceptions.ConnectionError("down"))
        with self.assertRaises(worker.RedisUnavailable):
            await worker.ledger_claim(redis_client, 721)

    async def test_clearing_an_empty_keyspace_returns_zero(self):
        self.assertEqual(await worker.ledger_clear(FakeRedis()), 0)


def track(track_id, title, code2="en"):
    return {"id": track_id, "title": title, "code2": code2}


class PickTrackTest(unittest.IsolatedAsyncioTestCase):
    def test_dialogue_wins_over_signs_and_songs(self):
        chosen = worker.pick_track([track(2725, SIGNS), track(2726, DIALOG)])
        self.assertEqual(chosen["id"], 2726)

    def test_only_a_signs_track_gives_nothing(self):
        self.assertIsNone(worker.pick_track([track(1, SIGNS)]))

    def test_no_english_track_gives_nothing(self):
        self.assertIsNone(worker.pick_track([track(1, "Dialog - JPN ASS", "ja")]))

    def test_first_of_several_titled_tracks_wins(self):
        chosen = worker.pick_track([track(1, "Full - ENG"), track(2, "Dialog - ENG")])
        self.assertEqual(chosen["id"], 1)

    def test_untitled_tracks_fall_back_to_the_first(self):
        chosen = worker.pick_track([track(1, "English (SDH)"), track(2, "English")])
        self.assertEqual(chosen["id"], 1)

    def test_capitals_do_not_hide_a_signs_track(self):
        chosen = worker.pick_track([track(1, "SIGNS & SONGS - ENG"), track(2, "Commentary")])
        self.assertEqual(chosen["id"], 2)

    async def test_titles_are_paired_by_embedded_track_order(self):
        class Episodes:
            async def episode(self, episode_id):
                return {
                    "path": "/data/x.mkv",
                    "subtitles": [
                        {"path": None, "embedded_track_id": 4, "id": 2726, "code2": "en"},
                        {"path": "/data/x.en.srt", "embedded_track_id": None, "id": 9, "code2": "en"},
                        {"path": None, "embedded_track_id": 3, "id": 2725, "code2": "en"},
                    ],
                }

            async def subtitle_titles(self, video_path, episode_id):
                return [SIGNS, DIALOG]

        tracks = await worker.embedded_tracks(Episodes(), 718)
        self.assertEqual(
            tracks,
            [
                {"id": 2725, "code2": "en", "title": SIGNS},
                {"id": 2726, "code2": "en", "title": DIALOG},
            ],
        )


def mock_bazarr(handler):
    client = httpx.AsyncClient(transport=httpx.MockTransport(handler))
    return worker.Bazarr("http://bazarr.test", "secret-key", client=client)


class BazarrClientTest(unittest.IsolatedAsyncioTestCase):
    async def test_wanted_keeps_the_fields_the_run_needs(self):
        seen = {}

        def handler(request):
            seen["key"] = request.headers.get("X-API-KEY")
            seen["query"] = dict(request.url.params)
            data = [wanted_episode(i, 15, "Paradise Kiss", "1x1") for i in range(35)]
            return httpx.Response(200, json={"data": data, "total": 35})

        episodes = await mock_bazarr(handler).wanted()
        self.assertEqual(len(episodes), 35)
        self.assertEqual(episodes[0]["seriesTitle"], "Paradise Kiss")
        self.assertEqual(episodes[0]["episode_number"], "1x1")
        self.assertEqual(seen["key"], "secret-key")
        self.assertEqual(seen["query"], {"start": "0", "length": "-1"})

    def test_episode_number_splits_into_season_and_episode(self):
        self.assertEqual(worker.parse_episode_number("1x12"), (1, 12))

    async def test_named_episode_listed_after_forty_seconds_is_kept(self):
        clock = Clock()
        late = wanted_episode(718, 15, "Paradise Kiss", "1x1")
        other = wanted_episode(285, 9, "Lazarus", "1x1")

        class Late(FakeBazarr):
            async def wanted(self):
                return [other, late] if clock.t >= 40 else [other]

            async def episode(self, episode_id):
                return {"path": "/data/x.mkv", "subtitles": []} if clock.t >= 40 else None

        bazarr = Late(clock)
        listed = await worker.wait_until_known(bazarr, [other], {718}, clock.now, clock.sleep)
        self.assertEqual([e["sonarrEpisodeId"] for e in listed], [285, 718])
        self.assertEqual(clock.t, 40)

    async def test_named_episode_never_listed_is_left_out_after_the_window(self):
        clock = Clock()
        other = wanted_episode(285, 9, "Lazarus", "1x1")
        bazarr = FakeBazarr(clock, [other])
        listed = await worker.wait_until_known(bazarr, [other], {718}, clock.now, clock.sleep)
        self.assertEqual([e["sonarrEpisodeId"] for e in listed], [285])
        self.assertEqual(clock.t, 180)

    async def test_a_connection_error_is_unavailable(self):
        def handler(request):
            raise httpx.ConnectError("refused")

        with self.assertRaises(worker.BazarrUnavailable):
            await mock_bazarr(handler).wanted()

    async def test_a_rejected_key_is_unavailable(self):
        with self.assertRaises(worker.BazarrUnavailable):
            await mock_bazarr(lambda request: httpx.Response(401)).wanted()


class AwaitSearchTest(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.clock = Clock()
        self.episodes = [
            wanted_episode(718, 15, "Paradise Kiss", "1x1"),
            wanted_episode(719, 15, "Paradise Kiss", "1x2"),
            wanted_episode(285, 9, "NANA", "1x1"),
        ]

    async def await_one(self, bazarr, named, since=None):
        return await worker.await_search(
            bazarr, 15, "Paradise Kiss", named, self.clock.now, self.clock.sleep,
            wall=self.clock.wall, since=since,
        )

    async def test_a_job_that_appears_and_completes_needs_no_search_request(self):
        clock = self.clock
        name = "Downloading missing subtitles for Paradise Kiss"

        class Timed(FakeBazarr):
            async def jobs(self):
                if clock.t < 20:
                    return []
                if clock.t < 50:
                    return [job(1, name, "running", BASE_EPOCH + 20)]
                return [job(1, name, "completed", BASE_EPOCH + 50)]

        bazarr = Timed(clock, self.episodes)
        self.assertTrue(await self.await_one(bazarr, True, since=BASE_EPOCH - 120))
        self.assertEqual(bazarr.search_calls, [])

    async def test_without_a_job_in_the_window_the_search_is_requested(self):
        bazarr = FakeBazarr(self.clock, self.episodes)
        self.assertTrue(await self.await_one(bazarr, True, since=BASE_EPOCH - 120))
        self.assertEqual(bazarr.search_calls, [15])
        self.assertGreaterEqual(self.clock.t, 180)

    async def test_a_backlog_series_is_searched_at_once(self):
        bazarr = FakeBazarr(self.clock, self.episodes)
        self.assertTrue(await self.await_one(bazarr, False))
        self.assertEqual(bazarr.search_calls, [15])
        self.assertLess(self.clock.t, 180)

    async def test_a_job_that_never_completes_leaves_the_search_unresolved(self):
        bazarr = FakeBazarr(self.clock, self.episodes, stuck_series={15})
        self.assertFalse(await self.await_one(bazarr, False))
        self.assertEqual(self.clock.t, 600)

    async def test_each_series_is_searched_once(self):
        bazarr = FakeBazarr(self.clock, self.episodes)
        resolved = await worker.await_searches(
            bazarr, self.episodes, set(), self.clock.now, self.clock.sleep, wall=self.clock.wall,
        )
        self.assertEqual(sorted(bazarr.search_calls), [9, 15])
        self.assertEqual(resolved, {15: True, 9: True})


def candidates(*items):
    return [wanted_episode(i, sid, title, number) for i, sid, title, number in items]


class RequestTranslationsTest(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.clock = Clock()
        self.nana = [(100 + n, 1, "NANA", f"1x{n}") for n in range(1, 5)]
        self.paradise = [(200 + n, 2, "Paradise Kiss", f"1x{n}") for n in range(1, 5)]

    def bazarr_for(self, items):
        return FakeBazarr(self.clock, candidates(*items))

    async def test_episodes_are_requested_by_episode_number_first(self):
        items = self.nana + self.paradise
        bazarr = self.bazarr_for(items)
        requested = await worker.request_translations(bazarr, FakeRedis(), candidates(*items), 0)
        self.assertEqual(requested, [101, 201, 102, 202, 103, 203])

    async def test_jobs_in_flight_take_slots(self):
        items = self.nana + self.paradise
        bazarr = self.bazarr_for(items)
        requested = await worker.request_translations(bazarr, FakeRedis(), candidates(*items), 4)
        self.assertEqual(len(requested), 2)

    async def test_a_claimed_episode_is_not_requested_again(self):
        bazarr = self.bazarr_for(self.nana)
        redis_client = FakeRedis(["autosubtitle:requested:101"])
        requested = await worker.request_translations(bazarr, redis_client, candidates(*self.nana[:2]), 1)
        self.assertEqual(requested, [102])

    async def test_claims_are_cleared_when_nothing_is_in_flight(self):
        bazarr = self.bazarr_for(self.nana)
        redis_client = FakeRedis(["autosubtitle:requested:101"])
        requested = await worker.request_translations(bazarr, redis_client, candidates(*self.nana[:1]), 0)
        self.assertEqual(requested, [101])

    async def test_claims_are_kept_while_jobs_are_in_flight(self):
        bazarr = self.bazarr_for(self.nana)
        redis_client = FakeRedis(["autosubtitle:requested:101"])
        await worker.request_translations(bazarr, redis_client, candidates(*self.nana[:1]), 2)
        self.assertIn("autosubtitle:requested:101", redis_client.store)

    async def test_an_image_based_track_is_logged_and_released(self):
        bazarr = self.bazarr_for(self.nana)
        bazarr.statuses = {101: 415}
        redis_client = FakeRedis()
        with self.assertLogs("autosubtitle", level="WARNING") as logs:
            requested = await worker.request_translations(bazarr, redis_client, candidates(*self.nana[:1]), 0)
        self.assertEqual(requested, [])
        self.assertTrue(any("NO_TRANSLATABLE_TRACK" in line for line in logs.output))
        self.assertNotIn("autosubtitle:requested:101", redis_client.store)

    async def test_a_signs_only_episode_makes_no_request(self):
        bazarr = self.bazarr_for(self.nana)
        bazarr.titles = [SIGNS, SIGNS]
        redis_client = FakeRedis()
        with self.assertLogs("autosubtitle", level="WARNING"):
            requested = await worker.request_translations(bazarr, redis_client, candidates(*self.nana[:1]), 0)
        self.assertEqual(requested, [])
        self.assertEqual(bazarr.translate_calls, [])
        self.assertNotIn("autosubtitle:requested:101", redis_client.store)

    async def test_a_rejected_translation_is_released_and_the_next_one_tried(self):
        items = self.nana[:1] + self.paradise[:1]
        bazarr = self.bazarr_for(items)
        bazarr.statuses = {101: 502}
        redis_client = FakeRedis()
        with self.assertLogs("autosubtitle", level="WARNING") as logs:
            requested = await worker.request_translations(bazarr, redis_client, candidates(*items), 0)
        self.assertEqual(requested, [201])
        self.assertTrue(any("TRANSLATE_REJECTED" in line for line in logs.output))
        self.assertNotIn("autosubtitle:requested:101", redis_client.store)

    def test_only_pending_and_running_translation_jobs_count_as_in_flight(self):
        jobs = [
            job(1, "Extracting and translating from EN to ES", "pending"),
            job(2, "Translating from EN to ES using Lingarr", "running"),
            job(3, "Translated from EN to ES using Lingarr", "completed"),
            job(4, "Downloading missing subtitles for NANA", "running"),
        ]
        self.assertEqual(worker.translation_jobs_in_flight(jobs), 2)


class RunCycleTest(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        self.clock = Clock()
        self.paradise = wanted_episode(719, 15, "Paradise Kiss", "1x2")
        self.nana = wanted_episode(285, 9, "NANA", "1x1")

    async def run_cycle(self, bazarr, redis_client, named=()):
        return await worker.run_cycle(
            set(named), bazarr=bazarr, redis=redis_client,
            now=self.clock.now, sleep=self.clock.sleep, wall=self.clock.wall,
        )

    async def test_spanish_found_by_the_search_means_no_translation(self):
        bazarr = FakeBazarr(self.clock, [self.paradise])
        bazarr.on_search = lambda series_id: bazarr.wanted_list.clear()
        result = await self.run_cycle(bazarr, FakeRedis())
        self.assertEqual(result["requested"], [])
        self.assertEqual(bazarr.translate_calls, [])

    async def test_nothing_found_by_the_search_means_a_translation(self):
        bazarr = FakeBazarr(self.clock, [self.paradise])
        result = await self.run_cycle(bazarr, FakeRedis())
        self.assertEqual(result["requested"], [719])
        self.assertEqual(bazarr.translate_calls, [(719, 7191)])

    async def test_an_episode_that_has_spanish_is_never_searched(self):
        bazarr = FakeBazarr(self.clock, [])
        result = await self.run_cycle(bazarr, FakeRedis())
        self.assertEqual(result["requested"], [])
        self.assertEqual(bazarr.search_calls, [])

    async def test_redis_down_keeps_the_searches_and_requests_nothing(self):
        bazarr = FakeBazarr(self.clock, [self.paradise])
        redis_client = FakeRedis(error=redis.exceptions.ConnectionError("down"))
        with self.assertLogs("autosubtitle", level="WARNING") as logs:
            result = await self.run_cycle(bazarr, redis_client)
        self.assertEqual(bazarr.search_calls, [15])
        self.assertEqual(result["requested"], [])
        self.assertTrue(any("REDIS_UNAVAILABLE" in line for line in logs.output))

    async def test_bazarr_down_ends_the_run(self):
        bazarr = FakeBazarr(self.clock, [self.paradise])
        bazarr.down = True
        with self.assertLogs("autosubtitle", level="WARNING") as logs:
            result = await self.run_cycle(bazarr, FakeRedis())
        self.assertEqual(result["requested"], [])
        self.assertTrue(any("BAZARR_UNAVAILABLE" in line for line in logs.output))

    async def test_a_series_whose_search_never_completes_is_skipped(self):
        bazarr = FakeBazarr(self.clock, [self.paradise, self.nana], stuck_series={9})
        result = await self.run_cycle(bazarr, FakeRedis())
        self.assertEqual(result["requested"], [719])
        self.assertIn("search_unresolved", " ".join(result["skipped"]))


class HttpSurfaceTest(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        worker._state.update(running=False, pending=False, named=set(), since=None)
        self.calls = []
        self.gate = asyncio.Event()

    def client(self):
        return httpx.AsyncClient(transport=httpx.ASGITransport(app=worker.app), base_url="http://worker.test")

    def fake_run(self, block_first=True):
        async def run(named, **kwargs):
            self.calls.append(set(named))
            if block_first and len(self.calls) == 1:
                await self.gate.wait()

        return mock.patch.object(worker, "run_cycle", run)

    async def idle(self):
        for _ in range(200):
            if not worker._state["running"]:
                return
            await asyncio.sleep(0)

    async def test_the_first_call_starts_a_run(self):
        with self.fake_run(block_first=False):
            async with self.client() as client:
                response = await client.post("/run")
            await self.idle()
        self.assertEqual(response.status_code, 202)
        self.assertEqual(response.json(), {"state": "started"})
        self.assertEqual(len(self.calls), 1)

    async def test_a_call_during_a_run_is_queued(self):
        with self.fake_run():
            async with self.client() as client:
                await client.post("/run")
                await asyncio.sleep(0)
                response = await client.post("/run")
                self.gate.set()
                await self.idle()
        self.assertEqual(response.status_code, 202)
        self.assertEqual(response.json(), {"state": "queued"})

    async def test_twelve_calls_during_one_run_cause_exactly_one_more_run(self):
        with self.fake_run():
            async with self.client() as client:
                await client.post("/run")
                await asyncio.sleep(0)
                responses = [await client.post("/run") for _ in range(12)]
                self.gate.set()
                await self.idle()
        self.assertEqual({r.status_code for r in responses}, {202})
        self.assertEqual(len(self.calls), 2)

    async def test_a_body_that_is_not_json_still_starts_a_run(self):
        with self.fake_run(block_first=False):
            async with self.client() as client:
                response = await client.post("/run", content=b"not json {")
            await self.idle()
        self.assertEqual(response.status_code, 202)
        self.assertEqual(self.calls, [set()])

    async def test_episode_ids_of_a_sonarr_body_reach_the_run(self):
        body = {"eventType": "Download", "episodes": [{"id": 718, "title": "Atelier"}]}
        with self.fake_run(block_first=False):
            async with self.client() as client:
                await client.post("/run", content=json.dumps(body))
            await self.idle()
        self.assertEqual(self.calls, [{718}])

    async def test_health_answers_ok(self):
        async with self.client() as client:
            response = await client.get("/healthz")
        self.assertEqual(response.status_code, 200)

    async def test_the_interactive_docs_are_not_served(self):
        async with self.client() as client:
            docs = await client.get("/docs")
            schema = await client.get("/openapi.json")
        self.assertEqual((docs.status_code, schema.status_code), (404, 404))


if __name__ == "__main__":
    unittest.main()
