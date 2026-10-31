# Nexus

## What it does

`nexus` creates, on fixed dates, the tasks of the templates kept in Kaneo. Kaneo only repeats a task when it is completed (the next one is created when the current one moves to a final column); the old Notion templates created it on a fixed date even if the previous one was still open. See [ADR-033](DECISIONS.md#adr-033-nexus-creates-the-kaneo-template-tasks-on-fixed-dates-built-in-its-own-repo-and-run-here).

The code is the `template` module of the `nexus` app in `github.com/cristsr/notion-task-manager`, which only builds and publishes the image. It runs in the `kaneo` namespace (`workloads/nexus/`, ArgoCD Application `nexus`).

Every hour, from 08:00 America/Bogota, it reads the tasks of the Kaneo project `Plantillas`. A template that is due today (by its own repeat rule) gets a task created in the project `Daily` with the same title, description and priority, due today. A task with that title and due date that already exists, open or archived, is not created again, so the hourly run is safe and a day in which the service was down at 08:00 is recovered when it comes back.

## The templates

They are tasks of the Kaneo project `Plantillas` (id in `KANEO_TEMPLATE_PROJECT_ID`). Each one carries its own schedule:

- the **repeat rule** (daily, weekly, monthly or yearly, interval, weekdays) says how often;
- the **due date** is the first day, the steps are counted from it. A month without that day uses its last day.

A task without a due date or without a repeat rule is skipped with a warning in the log. The description is copied as it is, so payment links and contract numbers live in Kaneo, never in a repo. Templates are never completed: if one were, Kaneo would create its next copy inside `Plantillas`.

| Template | Rule | Due date to set |
|---|---|---|
| Pagar Cuentas | monthly, every 1 | the 2nd |
| Pagar Servicios Guayacán | monthly, every 1 | the 24th |
| Pagar Servicios Fontana | monthly, every 1 | the 24th |

Created tasks do not inherit labels, assignee or subtasks, only title, description and priority. The tasks of `Daily` made by hand (DAI-16, 17 and 18) can keep their own repeat rule: when the template creates a task that already exists it skips it.

## First deploy

The Pod cannot start before the first three steps, so do them in this order:

1. In the app repo, run the `Image` workflow from the branch (Actions > Image > Run workflow), or merge to `main` or `develop`. It publishes `ghcr.io/cristsr/notion-task-manager:sha-<short commit>`.
2. Make the package public (GitHub > Packages > notion-task-manager > Package settings). The cluster pulls it without credentials, as it does with `autosubtitle-base`.
3. Put the same tag in `workloads/nexus/nexus.yaml`.
4. Create a Kaneo API key (Settings > API keys) with permission to read and create tasks, and add to `secrets/homelab.env`:
   - `NEXUS_KANEO_API_KEY`: that key.
   - `NEXUS_MONGO_URI`: `mongodb://admin:<MONGODB_APP_PASSWORD>@mongodb.internal.cristianpuenguenan.online:27017/?authSource=admin`, with the password URL-encoded if it has special characters.
5. `./scripts/apply-real-secrets.sh secrets/homelab.env`, then commit `workloads/nexus/secrets.sops.yaml`.
6. Merge. ArgoCD creates the Deployment.

## Operating

- **Logs**: `kubectl -n kaneo logs deploy/nexus`. A task created from a template logs `Task created from template [id] title`.
- **Expected at start**: the Discord login fails (`TokenInvalid`) and the app may log failed Notion calls: there is no token for either. Neither stops the app.
- **If it does not start**: the app needs MongoDB to boot. A crash loop with `MongooseServerSelectionError` means the URI, the password or the route to the `mongodb` LXC.
- **Run it now**: the job fires at minute 0 of every hour. `kubectl -n kaneo rollout restart deploy/nexus` does not trigger it.
- **Update the image**: publish a new one from the app repo and change the tag in `workloads/nexus/nexus.yaml`. Renovate skips `ghcr.io/cristsr/**`, so nothing does it for you. The tag is a commit, never reused.
- **Add a template**: create a task in `Plantillas` with the due date and the repeat rule. Nothing to deploy.

## Limits

- It only looks at today: a day in which the service was down for all of it is not made up.
- The Notion notifications of the app are not migrated and still run in the old deployment.
