# Homelab Pending Tasks

This document lists the tasks planned to improve cluster automation and maintenance.

---

## 1. Integrate Renovate for Automatic Updates

**Motivation:** Currently Helm chart and Docker image versions are pinned manually. When a new version comes out (e.g. SonarQube), it has to be detected and the `targetRevision` updated by hand.

**Tasks:**

- [ ] Install/configure Renovate (GitHub App or self-hosted) to scan the repository.
- [ ] Create `renovate.json` at the repo root with rules to:
  - Detect new versions of Helm charts (e.g. `sonarqube`, `argocd`, etc.).
  - Detect new versions of Docker images defined in Helm values.
  - Group `patch` and `minor` updates to reduce noise.
  - Separate `major` updates into individual PRs due to risk.
- [ ] Verify that Renovate correctly detects the current images (e.g. `sonarqube:26.3.0.120487-community`).
- [ ] Document in `docs/OPERATIONS.md` how to approve/reject Renovate PRs.

**Affected files:**
- `renovate.json` (new)
- `docs/OPERATIONS.md`

---

## 2. Formalize and Document Conventional Commits

**Motivation:** The repository already uses Conventional Commits de facto (`feat(sonarqube):`, `fix(networking):`, `refactor(observability):`), but it is not documented and there is no automatic validation.

**Tasks:**

- [ ] Document the commit convention in `docs/CONTRIBUTING.md` or similar:
  - Allowed types: `feat`, `fix`, `docs`, `refactor`, `chore`, `ci`, `test`, `perf`.
  - Format: `type(scope): description`.
  - Common scopes: `sonarqube`, `networking`, `storage`, `observability`, `ansible`, `bootstrap`, `security`.
- [ ] (Optional) Add commit message validation in CI (pre-commit hook or GitHub Action) with tools like `commitlint`.
- [ ] Review recent history to identify inconsistencies and fix them if needed.

**Affected files:**
- `docs/CONTRIBUTING.md` (new)
- `.github/workflows/commitlint.yaml` (optional)

---

## 3. Migrate ArgoCD from polling to a GitHub webhook — REVERTED (ADR-019)

**Motivation:** The original polling had a 180s interval. A GitHub webhook delivers notifications within seconds of each push, eliminating unnecessary latency.

**Actual status:** It was implemented (`webhook_secret` in 1Password, `platform/argocd/webhook-externalsecret.yaml` synced it to `argocd-secret`) and worked for a while, but it depended on 1Password's `ClusterSecretStore`, which got permanently stuck in `rate limit exceeded` (see ADR-018/019). It was fully reverted on 2026-09-16: the webhook was removed (GitHub repo and manifests), the `onepassword` `ClusterSecretStore`, and `timeout.reconciliation` went back to `180s` as the sole sync mechanism. See ADR-019 in `docs/DECISIONS.md` for details and the plan if it is to be reimplemented later with a secret that doesn't depend on a rate-limited external backend.

**Related incident:** On 2026-05-13 the webhook (original version) broke silently and the cluster went unsynced until 2026-09-07 without anyone noticing, because at that time `timeout.reconciliation` was set to `0s` (no safety net). See the comment in `bootstrap/argocd/values.yaml` and `docs/DECISIONS.md` for details — this remains the reason why `timeout.reconciliation` must never be set back to `0s`.

---

## Notes

- High priority: Renovate, since it reduces manual maintenance work.
- Medium priority: Document Conventional Commits, to standardize contributions.
- Medium priority: Migrate ArgoCD to webhook for immediate sync after push.
- Creation date: 2026-05-11
