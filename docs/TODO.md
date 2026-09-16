# Tareas Pendientes del Homelab

Este documento lista las tareas planificadas para mejorar la automatizacion y el mantenimiento del cluster.

---

## 1. Integrar Renovate para Actualizaciones Automaticas

**Motivacion:** Actualmente las versiones de charts Helm e imagenes Docker estan fijadas manualmente. Cuando sale una nueva version (ej. SonarQube), hay que detectarlo y actualizar el `targetRevision` a mano.

**Tareas:**

- [ ] Instalar/configurar Renovate (GitHub App o self-hosted) para escanear el repositorio.
- [ ] Crear `renovate.json` en la raiz del repo con reglas para:
  - Detectar nuevas versiones de charts de Helm (ej. `sonarqube`, `argocd`, etc.).
  - Detectar nuevas versiones de imagenes Docker definidas en values de Helm.
  - Agrupar updates de tipo `patch` y `minor` para reducir ruido.
  - Separar updates `major` en PRs individuales por riesgo.
- [ ] Verificar que Renovate detecte correctamente las imagenes actuales (ej. `sonarqube:26.3.0.120487-community`).
- [ ] Documentar en `docs/OPERATIONS.md` como aprobar/rechazar PRs de Renovate.

**Archivos afectados:**
- `renovate.json` (nuevo)
- `docs/OPERATIONS.md`

---

## 2. Formalizar y Documentar Conventional Commits

**Motivacion:** El repositorio ya usa Conventional Commits de facto (`feat(sonarqube):`, `fix(networking):`, `refactor(observability):`), pero no esta documentado ni hay validacion automatica.

**Tareas:**

- [ ] Documentar la convencion de commits en `docs/CONTRIBUTING.md` o similar:
  - Tipos permitidos: `feat`, `fix`, `docs`, `refactor`, `chore`, `ci`, `test`, `perf`.
  - Formato: `tipo(alcance): descripcion`.
  - Alcances comunes: `sonarqube`, `networking`, `storage`, `observability`, `ansible`, `bootstrap`, `security`.
- [ ] (Opcional) Agregar validacion de mensajes de commit en CI (pre-commit hook o GitHub Action) con herramientas como `commitlint`.
- [ ] Revisar el historial reciente para identificar inconsistencias y corregir si es necesario.

**Archivos afectados:**
- `docs/CONTRIBUTING.md` (nuevo)
- `.github/workflows/commitlint.yaml` (opcional)

---

## 3. Migrar ArgoCD de polling a webhook de GitHub — REVERTIDO (ADR-019)

**Motivacion:** El polling original tenia un intervalo de 180s. Un webhook de GitHub entrega notificaciones en segundos tras cada push, eliminando la latencia innecesaria.

**Estado real:** Se implemento (`webhook_secret` en 1Password, `platform/argocd/webhook-externalsecret.yaml` lo sincronizaba a `argocd-secret`) y funciono por un tiempo, pero dependia del `ClusterSecretStore` de 1Password, que quedo permanentemente en `rate limit exceeded` (ver ADR-018/019). Se revirtio por completo el 2026-09-16: se elimino el webhook (repo de GitHub y manifiestos), el `ClusterSecretStore` `onepassword`, y `timeout.reconciliation` volvio a `180s` como unico mecanismo de sync. Ver ADR-019 en `docs/DECISIONS.md` para el detalle y el plan si se quiere reimplementar mas adelante con un secret que no dependa de un backend externo con rate limit.

**Incidente relacionado:** El 2026-05-13 el webhook (version original) se rompio silenciosamente y el cluster estuvo sin sincronizar hasta el 2026-09-07 sin que nadie lo notara, porque en ese momento `timeout.reconciliation` estaba en `0s` (sin red de seguridad). Ver el comentario en `bootstrap/argocd/values.yaml` y `docs/DECISIONS.md` para el detalle — sigue siendo la razon por la que `timeout.reconciliation` nunca debe volver a `0s`.

---

## Notas

- Prioridad alta: Renovate, ya que reduce el trabajo manual de mantenimiento.
- Prioridad media: Documentar Conventional Commits, para estandarizar contribuciones.
- Prioridad media: Migrar ArgoCD a webhook para sync inmediato tras push.
- Fecha de creacion: 2026-05-11
