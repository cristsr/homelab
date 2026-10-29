# Relay

## Trial

A trial of Bazarr's own translate action through Lingarr, run on one real episode on 2026-10-28 (local time) before the worker existed.

- **Setting changed:** `translator.translator_type` in Bazarr went from `google_translate` to `lingarr`; `translator.lingarr_url` was already `http://lingarr:9876`.
- **Episode:** Mushi-Shi S00E01, "The Shadow That Devours the Sun" (Sonarr episode id 497). It was the first episode in Bazarr's list of episodes missing Spanish once ordered by episode number, then season, then series title.
- **Track:** `Dialog - ENG ASS`, database id 864, the only embedded subtitle of that file.
- **Call:** `PATCH /api/subtitles` with `action=translate`, `language=es`, `type=episode`, `id=497`, `subtitles_id=864`, `forced=False` and `hi=False` answered `204`.
- **Time:** 884 seconds from the call until `…es.srt` appeared next to the video, about 15 minutes.
- **Result:** 746 lines translated. The file has 747 subtitle blocks, because Bazarr adds a first one reading `# Subtitles translated with Lingarr #` from 00:00:00 to 00:00:03 (its `translator_info` setting is on).
- **Residue:** 0 lines containing `<font` or `{\`.
- **Files left by Bazarr:** the extracted source `Mushi-Shi - S00E01 - The Shadow That Devours the Sun Bluray-1080p.en.ass` (82301 bytes) and the translation `….es.srt` (52214 bytes), both beside the video. Bazarr extracts the track in its original ASS format and keeps it.
- **Speed:** about 0.8 lines per second inside one job, since Lingarr translates the lines one by one. Bazarr runs up to 4 jobs at once (`concurrent_jobs: 4`).
- **Jobs list:** the finished job appeared as "Translated from EN to ES using Lingarr", and its progress message holds the path of the source subtitle, relative to `/data`. Bazarr lists pending, running, failed and completed jobs, the last two keeping only the 10 most recent, and `GET /api/system/jobs` accepts a `status` filter. The name a job carries while pending or running was not observed in this trial.

To undo the trial, set the translator back and delete the two files:

```bash
kubectl -n media exec deploy/bazarr -- sh -c 'k=$(sed -n "s/^ *apikey: *//p" /config/config/config.yaml | head -1); curl -s -o /dev/null -w "%{http_code}\n" -X POST -H "X-API-KEY: $k" http://localhost:6767/api/system/settings --data-urlencode "settings-translator-translator_type=google_translate"'
```

## What it does

`relay` is a small FastAPI app in the `media` namespace that glues the arr stack to what it lacks. Its first job gives Spanish subtitles to the episodes Sonarr imports. It sits at zero replicas and KubeElasti wakes it on the first call: Sonarr's webhook on import complete and on upgrade, or a CronJob that calls it every day at 06:00.

A run reads the episodes Bazarr lists as missing Spanish, waits for Bazarr's own search of each series (or asks Bazarr to run it), and only for the episodes that still lack Spanish asks Bazarr to extract the English dialogue track and translate it through Lingarr. Each episode it requests is recorded in Redis under `autosubtitle:requested:{episodeId}` for three hours, so it is never requested twice, and at most six translation jobs are pending or running in Bazarr at once.

The app never touches the media files and never calls Lingarr itself; Bazarr does both. Its code is `workloads/relay/worker.py` and its tests are `workloads/relay/test_worker.py`.

## Rollout order

1. Merge the branch to `master`. ArgoCD syncs the `relay` Application on its own, so the pod will fail to start until steps 3 and 4 are done; it recovers by itself afterwards.
2. The workflow `Autosubtitle image` builds and pushes `ghcr.io/cristsr/autosubtitle-base:1.0.0`.
3. Make that package public once, in the GitHub package settings of `autosubtitle-base`. Until then the pod fails with `ImagePullBackOff`.
4. Load `BAZARR_API_KEY` and `REDIS_PASSWORD` with `scripts/apply-real-secrets.sh <answers-file>` and commit the updated `workloads/media/secrets.sops.yaml`. The template is committed with the placeholder `replace-me` in both values.
5. ArgoCD syncs the `relay` Application (wave 10, after `media`, whose `SopsSecret` creates the secret it reads).
6. Switch Bazarr to Lingarr, if it is not already.
7. Create the Sonarr webhook.
8. Check it: import an episode, or call the app by hand, and watch `kubectl -n media get pods -l app=relay` go from none to one pod and back to none after the 30-minute cooldown.

## Switch Bazarr to Lingarr

```bash
kubectl -n media exec deploy/bazarr -- sh -c 'k=$(sed -n "s/^ *apikey: *//p" /config/config/config.yaml | head -1); curl -s -o /dev/null -w "%{http_code}\n" -X POST -H "X-API-KEY: $k" http://localhost:6767/api/system/settings --data-urlencode "settings-translator-translator_type=lingarr"'
```

It prints `204`. To go back to Google Translate, run the same command with `google_translate` in place of `lingarr`.

## Create the Sonarr webhook

Sonarr's connections are not managed by the repo, so the webhook is created once through its API:

```bash
cat <<'JSON' | kubectl -n media exec -i deploy/sonarr -- sh -c 'k=$(sed -n "s:.*<ApiKey>\(.*\)</ApiKey>.*:\1:p" /config/config.xml); curl -s -X POST -H "X-Api-Key: $k" -H "Content-Type: application/json" --data-binary @- http://localhost:8989/api/v3/notification'
{
  "name": "Relay subtitles",
  "implementation": "Webhook",
  "configContract": "WebhookSettings",
  "onImportComplete": true,
  "onUpgrade": true,
  "fields": [
    { "name": "url", "value": "http://relay.media.svc.cluster.local:8080/subtitles/run" },
    { "name": "method", "value": 1 }
  ]
}
JSON
```

To check it, list the connections; the entry named `Relay subtitles` must show `onImportComplete` and `onUpgrade` as `true`:

```bash
kubectl -n media exec deploy/sonarr -- sh -c 'k=$(sed -n "s:.*<ApiKey>\(.*\)</ApiKey>.*:\1:p" /config/config.xml); curl -s -H "X-Api-Key: $k" http://localhost:8989/api/v3/notification' | jq '.[] | {name, onImportComplete, onUpgrade}'
```

## Create the Sonarr grab webhook (metadata refresh)

A second connection, on grab only, lets `relay` refresh a series whose episode Sonarr still caches as `TBA`. Create it the same way as the first one, with another name and URL:

```json
{
  "name": "Relay metadata",
  "implementation": "Webhook",
  "configContract": "WebhookSettings",
  "onGrab": true,
  "fields": [
    { "name": "url", "value": "http://relay.media.svc.cluster.local:8080/metadata/refresh" },
    { "name": "method", "value": 1 }
  ]
}
```

`relay` reads Sonarr's key from the `lingarr` secret. The loop waits 5 minutes between refreshes and gives up after 5, staying under KubeElasti's 30-minute cooldown; a title that TheTVDB names later is picked up by Sonarr's own refresh or by a manual "Refresh & Scan".

## Rebuild the image

The image holds only the dependencies listed in `workloads/relay/requirements.txt`. When that file or the `Dockerfile` changes, bump the tag in three places at once: the workflow `.github/workflows/autosubtitle-image.yml`, and the Deployment and the CronJob in `workloads/relay/relay.yaml`. Renovate skips `ghcr.io/cristsr/**`, so nothing does it for you. Editing `worker.py` needs none of this: the ConfigMap changes name and the Deployment rolls.

The tag is a version in the form `major.minor.patch`, and a tag already pushed is never reused:

- **patch:** a dependency moves to a new patch or minor release, for example `fastapi` 0.162.0 to 0.162.1 (`1.0.0` to `1.0.1`).
- **minor:** a package is added or removed (`1.0.0` to `1.1.0`).
- **major:** the Python base image changes its minor version, or a dependency changes in a way the script must follow (`1.0.0` to `2.0.0`).

## Moving the webhook from `autosubtitle`

The old Service `autosubtitle` disappears when ArgoCD prunes it, so point the existing Sonarr connection at the new URL in the same window. Find its id with the listing command above, then edit its `url` field to `http://relay.media.svc.cluster.local:8080/subtitles/run` (Sonarr UI: Settings → Connect, or `PUT /api/v3/notification/{id}`), and rename the connection to `Relay subtitles`.
