# Decisiones de Arquitectura (ADR)

Registro de las principales decisiones técnicas tomadas en el homelab. Cada entrada explica el contexto que motivó la decision, las alternativas evaluadas y las consecuencias.

---

## ADR-001: k0s como distribución Kubernetes

**Estado**: Aceptado — reemplazó MicroK8s  
**Fecha**: 2026-04

### Contexto

El homelab arrancó con **MicroK8s**. Con el tiempo surgieron fricciones que lo hacían incompatible con un setup GitOps limpio:

- MicroK8s instala y gestiona addons propios (DNS, ingress, storage) que crean abstracciones sobre los componentes reales, dificultando el control directo con ArgoCD.
- Se distribuye via **snap**, lo que genera paths no estándar para binarios CNI (`/snap/microk8s/...`) que rompen la configuración de Cilium.
- Deshabilitar `kube-proxy` para cederlo a Cilium eBPF no es un proceso limpio ni documentado en MicroK8s.
- La actualización de versiones via snap puede ocurrir fuera del control del operador.

### Opciones consideradas

| Opción | Razón de descarte |
|--------|------------------|
| **MicroK8s** | Paths no estándar, addons opacos, snap, kube-proxy difícil de deshabilitar |
| **k3s** | Instala Traefik y componentes extra por defecto, requiere flags para deshabilitar |
| **RKE2** | Más orientado a producción enterprise, overhead innecesario para single-node |

### Decisión

**k0s**: binario único sin dependencias, configuración 100% declarativa via `/etc/k0s/k0s.yaml`, `kube-proxy` se deshabilita con `--disable-components=kube-proxy`, paths estándar de CNI, servicio systemd estable.

### Consecuencias

- Cilium puede gestionar toda la plomería de red sin conflictos de paths.
- La configuración del nodo es reproducible via plantilla Jinja2 en Ansible.
- Se pierde el ecosistema de addons de MicroK8s (positivo: se gana control total sobre cada componente).

---

## ADR-002: Agent Gateway como ingress

**Estado**: Aceptado — reemplazó APISIX  
**Fecha**: 2026-05

### Contexto

**Apache APISIX** fue el primer ingress del homelab. La fricción principal fue su modelo de configuración:

- Las rutas se gestionan mediante la **Admin API** (llamadas HTTP al panel de control), no con recursos YAML declarativos en Git.
- Aunque APISIX tiene CRDs propios (`ApisixRoute`, `ApisixUpstream`), son una capa de abstracción sobre su Admin API y no siguen el estándar de Kubernetes Gateway API.
- Esto hace que ArgoCD gestione los recursos ArgoCD pero no controle realmente la configuración de rutas, rompiendo el principio GitOps de "todo en Git".
- El homelab tiene MCP servers que necesitan un gateway que entienda AI workloads y protocolos MCP nativamente.

### Opciones consideradas

| Opción | Razón de descarte |
|--------|------------------|
| **APISIX** | Config vía Admin API, no Gateway API nativa, fricción con GitOps |
| **Nginx Ingress** | Ingress API legacy, no Gateway API, sin soporte MCP |
| **Envoy Gateway** | Gateway API nativa pero sin soporte AI/MCP |
| **Istio Gateway** | Demasiado overhead para single-node |

### Decisión

**Agent Gateway**: implementa **Gateway API de Kubernetes** (`Gateway`, `HTTPRoute` como recursos nativos), toda la configuración es YAML declarativo gestionado por ArgoCD, tiene soporte nativo para AI workloads y protocolo MCP.

### Consecuencias

- Toda la configuración de rutas vive en Git y es sincronizada por ArgoCD.
- Los MCP servers (SonarQube MCP, OpenMemory) se exponen con HTTPRoutes estándar con path rewriting.
- Agent Gateway es un proyecto joven con menor comunidad que APISIX o Nginx; puede tener breaking changes.

---

## ADR-003: Cilium como CNI

**Estado**: Aceptado  
**Fecha**: 2026-04

### Contexto

Se necesita un CNI que cumpla tres requisitos simultáneamente:

1. **Reemplazo de kube-proxy**: eliminar el overhead de iptables usando eBPF.
2. **NetworkPolicies expresivas**: capacidad de restringir tráfico entre pods con reglas más granulares que las nativas de Kubernetes.
3. **Observabilidad de red**: visibilidad de flujos L3/L4/L7 sin instrumentar aplicaciones.

### Opciones consideradas

| Opción | Razón de descarte |
|--------|------------------|
| **Flannel** | Solo L2/L3, sin NetworkPolicy, sin observabilidad |
| **Calico** | NetworkPolicy nativa, pero sin eBPF completo ni Hubble |
| **Weave** | Proyecto en mantenimiento reducido |

### Decisión

**Cilium** con `kubeProxyReplacement: true`:

- Todo el plano de datos de red via **eBPF** (sin iptables).
- **Hubble** para observabilidad de flujos de red en tiempo real con UI.
- `CiliumNetworkPolicy` para reglas de red más expresivas (ej: filtrar por namespace label + puerto específico).
- **Service mesh sin sidecar** disponible si se necesita mTLS en el futuro.

### Consecuencias

- Requiere kernel Linux ≥ 4.19 (no es problema en Ubuntu 22.04 con kernel 5.x+).
- La configuración inicial es más compleja (paths de CNI bins, `k8sServiceHost`, modos de routing).
- Cilium gestiona kube-proxy, DNS y NetworkPolicy, reduciendo el número de componentes independientes.

---

## ADR-004: Longhorn como storage

**Estado**: Aceptado  
**Fecha**: 2026-04

### Contexto

En single-node se necesita un StorageClass que permita PVCs persistentes para bases de datos (PostgreSQL, MongoDB, Redis, Qdrant, OpenBao). Los requisitos son: snapshots, backups opcionales, y dos políticas de retención distintas (`Delete` para datos efímeros, `Retain` para bases de datos).

### Opciones consideradas

| Opción | Razón de descarte |
|--------|------------------|
| **local-path-provisioner** | Sin snapshots, sin backups, sin UI, política única |
| **Rook-Ceph** | Excesivamente complejo para single-node, alto consumo de recursos |
| **OpenEBS** | Más complejo de configurar, comunidad más pequeña |

### Decisión

**Longhorn** instalado via Helm:

- Dos StorageClasses: `longhorn` (ReclaimPolicy: Delete) y `longhorn-retain` (ReclaimPolicy: Retain) para bases de datos.
- UI web para inspeccionar volúmenes, snapshots y réplicas.
- Réplicas configuradas en 1 (single-node no puede replicar a otro nodo).
- Snapshots programables para backups de bases de datos.

### Consecuencias

- Requiere `open-iscsi` instalado en el nodo (gestionado por Ansible como prerequisito).
- Los procesos de Longhorn (manager, engine image, replica) consumen recursos del nodo (~200MB RAM).
- En single-node, la redundancia es limitada: un fallo de disco = pérdida de datos. Mitigado con snapshots.

---

## ADR-005: Cloudflare Tunnel para acceso externo

**Estado**: Aceptado  
**Fecha**: 2026-04

### Contexto

Los servicios del homelab necesitan ser accesibles desde Internet (ArgoCD, Grafana, SonarQube, etc.) sin comprometer la seguridad de la red doméstica. La red doméstica está detrás de un router con NAT y sin IP pública fija, lo que hace que la apertura de puertos sea frágil (IP cambia) e implica exponer directamente el nodo al tráfico entrante de Internet.

### Opciones consideradas

| Opción | Razón de descarte |
|--------|------------------|
| **Port forwarding en router** | Requiere IP pública estática, expone el nodo directamente a Internet, DDNS es frágil |
| **Tailscale / WireGuard VPN** | Requiere cliente VPN en el dispositivo de acceso, no sirve para acceso web público sin cliente |
| **VPS como reverse proxy** | Coste mensual adicional, latencia extra, otro sistema que mantener |

### Decisión

**Cloudflare Tunnel** (`cloudflared`): el agente establece una conexión **saliente** cifrada desde el cluster hacia Cloudflare. Todo el tráfico entrante fluye por esa conexión sin necesidad de abrir puertos en el router ni tener IP fija.

Beneficios adicionales:
- El DNS del dominio (`*.cristianpuenguenan.online`) ya está gestionado en Cloudflare, unificando DNS + túnel + certificados TLS en una sola plataforma.
- Cloudflare actúa como WAF y DDoS protection de forma transparente.
- El token del túnel se gestiona como secret en OpenBao y se sincroniza via ExternalSecret, por lo que `cloudflared` arranca sin credenciales en texto plano.

### Consecuencias

- No se abre ningún puerto en el router; el nodo no es directamente accesible desde Internet.
- El acceso externo depende de la disponibilidad de Cloudflare (prácticamente 100% uptime).
- Para acceso LAN sin pasar por Cloudflare, Agent Gateway sigue accesible directamente en `192.168.80.20:443`.

---

## ADR-006: OpenBao como backend de secretos


**Estado**: Aceptado  
**Fecha**: 2026-04

### Contexto

El cluster necesita un sistema centralizado para gestionar secretos (tokens de APIs, credenciales de bases de datos, claves TLS) que cumpla dos requisitos: los secretos **no deben vivir en texto plano en Git** y deben poder sincronizarse automáticamente con Kubernetes Secrets cuando un pod los necesita.

La alternativa más simple —poner los secretos directamente como Kubernetes Secrets en el repositorio— es incompatible con GitOps porque requeriría cifrarlos en el repo (SOPS, sealed-secrets) o aceptar el riesgo de exposición.

### Opciones consideradas

| Opción | Razón de descarte |
|--------|------------------|
| **Sealed Secrets** | Secretos cifrados en Git pero atados a la clave del cluster; si el cluster muere se pierden los secretos originales |
| **SOPS + age/GPG** | Cifrado en Git válido, pero requiere descifrado manual o CI/CD para aplicar; no ofrece API dinámica para rotación |
| **HashiCorp Vault** | Solución de referencia pero con BSL (Business Source License) desde 2023; OpenBao es su fork comunitario con licencia MPL-2.0 |
| **Doppler / Infisical** | SaaS externos; introduce dependencia de un tercero para secretos críticos del cluster |

### Decisión

**OpenBao** (fork comunitario de HashiCorp Vault, licencia MPL-2.0) desplegado en el cluster vía Helm:

- KV v2 como engine principal: todos los secretos del cluster viven en `secret/` con versionado.
- **Kubernetes auth**: los pods se autentican con su ServiceAccount, sin credenciales hardcodeadas.
- **External Secrets Operator** sincroniza automáticamente desde OpenBao hacia Kubernetes Secrets; los pods solo ven Secrets nativos de Kubernetes.
- La clave de unseal se gestiona con **Static Seal** (AES-256) cifrada con `ansible-vault` en el repositorio.

### Consecuencias

- Ningún secreto de producción vive en texto plano en Git.
- Tras cada reinicio del pod `openbao-0`, el vault queda sellado y requiere unseal manual con la clave AES-256. Es el principal punto de fricción operativa.
- External Secrets Operator añade un componente extra, pero desacopla completamente la gestión de secretos de su consumo.
- Al ser un fork activo de Vault, la API es 100% compatible: la documentación de Vault es válida para OpenBao.

---

## ADR-007: Ansible para aprovisionamiento del nodo

**Estado**: Aceptado  
**Fecha**: 2026-04

### Contexto

El nodo necesita ser aprovisionado **antes** de que Kubernetes exista: instalar k0s, kubectl, Helm, Helmfile, prerequisitos de Longhorn, y crear los secrets iniciales que el cluster necesita en el primer arranque. Este bootstrapping no puede hacerse con GitOps porque ArgoCD aún no existe.

Además, los secrets de arranque (GitHub PAT, tokens de Cloudflare, clave de OpenBao) no pueden vivir en texto plano en el repositorio.

### Opciones consideradas

| Opción | Razón de descarte |
|--------|------------------|
| **Scripts bash** | No son idempotentes, gestión de secrets complicada, difíciles de mantener |
| **Terraform** | Orientado a provisionar infraestructura cloud, no configuración de un nodo físico/VM existente |
| **Cloud-init** | Solo se ejecuta una vez en el primer arranque, no re-ejecutable |

### Decisión

**Ansible** con estructura de playbooks separados:

- `site.yaml`: playbook principal, idempotente, instala y configura todo el nodo desde cero.
- `vault-populate.yaml`: escribe los secrets de infraestructura en OpenBao KV una vez que el cluster está activo.
- `teardown.yaml`: destruye el cluster limpiamente para reinstalaciones.
- `ansible-vault` cifra los secrets sensibles en `group_vars/all.yaml`, el archivo de contraseña del vault (`.vault-pass`) está en `.gitignore`.

### Consecuencias

- El estado completo del nodo es reproducible ejecutando un único comando (`ansible-playbook site.yaml`).
- Los secrets sensibles están cifrados en el repositorio, seguros para versionar.
- Requiere Python y Ansible instalados en el nodo antes de ejecutar (dependencia de bootstrapping manual mínima).
- El playbook se ejecuta localmente en el nodo (`ansible_connection: local`), no requiere SSH desde un host externo.
