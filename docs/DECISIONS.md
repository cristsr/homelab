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

> **Actualización (ADR-008)**: desde que el nodo corre dentro de una VM, Ansible pasó de `ansible_connection: local` a SSH contra la VM. El rol de Ansible no cambió — sigue siendo el único responsable de configurar el nodo una vez que existe; lo que cambió es *qué* nodo existe primero (ahora lo crea Terraform).

---

## ADR-008: VM libvirt provisionada con Terraform

**Estado**: Aceptado
**Fecha**: 2026-08-30

### Contexto

El nodo corría directamente sobre el hardware del laptop (bare-metal, único host). Esto ataba todo el ciclo de vida del cluster al sistema operativo del host: reinstalar el nodo significaba reinstalar la máquina completa, y no existía forma de tomar snapshots o revertir el estado del nodo en sí (solo del cluster, vía `teardown.yaml`). El propio README ya anticipaba esta posibilidad ("desplegada... en un único nodo físico/virtual").

ADR-007 había evaluado y descartado Terraform para el aprovisionamiento, pero por una razón puntual: "Terraform está orientado a provisionar infraestructura cloud, no a configurar un nodo físico/VM **existente**". Esa razón dejó de aplicar en cuanto se decidió correr el nodo dentro de una VM: ahí sí hay infraestructura real que crear (disco, red, dominio libvirt), que es exactamente el dominio de Terraform.

### Opciones consideradas

| Opción | Razón de descarte |
|--------|-------------------|
| **Seguir en bare-metal** | Sin snapshots ni rollback a nivel nodo; reinstalar = reinstalar el SO del host completo |
| **Vagrant + libvirt** | Capa extra (Ruby/Vagrantfile) sobre libvirt sin aportar sobre Terraform; peor tracking de estado que un `.tfstate` |
| **Scripts bash + virt-install** (prototipo explorado en `~/vmconfig` durante esta sesión) | No declarativo, sin estado, sin plan/diff antes de aplicar cambios |

### Decisión

**Terraform con el provider `dmacvicar/libvirt`** (directorio `terraform/`) crea la VM: pool dedicado, volumen base (descarga pristina de Fedora Cloud, nunca booteada directamente) + volumen overlay copy-on-write por VM, `libvirt_cloudinit_disk` con IP estática, y el dominio libvirt en sí.

Ansible **no cambia de rol** (ADR-007 sigue vigente): sigue siendo el único responsable de instalar k0s y hacer el bootstrap inicial — solo cambia el transporte, de `ansible_connection: local` a SSH contra la VM.

**Red**: el host solo tiene WiFi activa (sin cable ethernet disponible), y bridging de una VM sobre WiFi es frágil en la mayoría de drivers/APs. Se optó por NAT libvirt (`192.168.122.0/24`, red `default` existente) + port-forward de `192.168.80.20:80/443` hacia la VM configurado con firewalld (`ansible/host-network.yaml`, corre contra el host, no contra la VM). Cloudflare Tunnel (ADR-005) no se ve afectado porque es una conexión saliente desde dentro de la VM.

### Consecuencias

- `terraform.tfstate` local pasa a ser un artefacto crítico sin backend remoto — punto único de falla conocido y aceptado por ahora (homelab de un solo operador); queda fuera de alcance de esta decisión.
  > **Actualización (ADR-009)**: dejó de aplicar — el state ahora vive en un backend remoto (Cloudflare R2), requisito no opcional para correr Terraform desde un runner de CI efímero.
- Nueva dependencia en el host: libvirt/KVM, además de Terraform.
- Ahora sí es posible tomar snapshots de la VM como mecanismo de recuperación ante desastres a nivel nodo — algo que bare-metal nunca ofreció.
- Acceso LAN directo depende de las reglas de forward-port de firewalld en el host (un componente más que puede fallar); acceso WAN vía Cloudflare Tunnel no tiene overhead adicional.
- `libvirt_domain.k0s_node` tiene `autostart = true`: a diferencia de bare-metal (donde `k0scontroller` arrancaba solo con el host), ahora la VM debe arrancar sola tras un reboot del host para que el cluster vuelva a estar disponible.

### Hallazgos del despliegue real (no obvios de antemano)

- **BIOS legacy + `i440fx`, no UEFI**: en este host, OVMF/UEFI (con o sin secure-boot, con o sin SMM) deja la VM colgada en silencio — sin salida en consola serie ni en framebuffer, CPU al 99% en un spin-loop dentro del firmware. BIOS legacy arranca de forma confiable con la misma plantilla de Fedora Cloud. Nada en k0s/Cilium/Longhorn requiere UEFI, así que `terraform/main.tf` fija `os.type_machine = "pc"` sin bloque de firmware.
- **`memory` del provider `dmacvicar/libvirt` es KiB por defecto**, no MiB — sin `memory_unit = "MiB"` explícito, cada VM se creaba con unos pocos MB de RAM en vez de GB (causa raíz real del cuelgue de arranque, más que el firmware). Ver el comentario en `terraform/main.tf` junto al bloque `libvirt_domain`.
- El schema de este provider (se resolvió a v0.9.9 con el constraint `~> 0.8`) es una reescritura completa frente a versiones anteriores documentadas en la comunidad: mapea el XML de libvirt casi 1:1 con atributos anidados (`disks = [...]`, `os = {...}`), no los bloques `disk {}`/`network_interface {}` clásicos. Si se actualiza el provider, revisar `terraform providers schema -json` antes de tocar `main.tf`.

---

## ADR-009: CI/CD con GitHub Actions hosted + Tailscale + Cloudflare R2

**Estado**: Aceptado
**Fecha**: 2026-08-31

### Contexto

Terraform y Ansible se ejecutaban manualmente desde el propio hipervisor (`qemu:///system` local, grupo `hypervisor` del inventario con `ansible_connection: local`). El operador dejó de querer ejecutar estas herramientas en el homeserver y pidió un flujo CI/CD real con GitHub Actions.

Un runner **hosted** de GitHub Actions vive en la nube pública de GitHub: no tiene ruta de red hacia una LAN doméstica sin NAT/IP pública. Además, `terraform apply` corriendo en un runner efímero no puede depender de un `terraform.tfstate` local — se perdería en cada job. Estos dos problemas (conectividad + estado) son los que resuelve esta decisión.

Durante la investigación se descartó una nota previa en la memoria de proyecto (no reflejada en código) que afirmaba la existencia de un backend nativo `"github"` en Terraform — se confirmó contra la documentación oficial de HashiCorp que **no existe tal backend**; se corrige aquí.

### Opciones consideradas

**Conectividad runner → hipervisor:**

| Opción | Razón de descarte |
|--------|-------------------|
| **Self-hosted runner en el homeserver** | Es exactamente lo que el operador quería dejar de hacer — vuelve a ejecutar todo en el propio host |
| **Puerto SSH expuesto en el router** | Expone la LAN a Internet; los rangos de IP de GitHub Actions cambian con frecuencia, no sirve para un allowlist estable |
| **Cloudflare Tunnel dedicado a SSH (fuera del cluster)** | Viable, pero añade un segundo `cloudflared` a nivel de host solo para esto — más superficie a mantener que Tailscale |

**Backend de state:**

| Opción | Razón de descarte |
|--------|-------------------|
| **State local en el runner** | Se pierde en cada job (runner efímero) — no es una opción real, no una preferencia |
| **HCP Terraform (Terraform Cloud) free tier** | Backend oficial y simple, pero introduce una cuenta/plataforma adicional fuera del stack ya usado (Cloudflare) |

### Decisión

- **Runners hosted de GitHub Actions**, sin self-hosted runner en el homeserver.
- **Tailscale**: el hipervisor físico se une al tailnet (`tailscale up --ssh`); cada job de CI levanta un nodo efímero via `tailscale/github-action@v4` autenticado con un OAuth client, taggeado `tag:ci`, con ACL que solo permite `tag:ci` → el tag del hipervisor por SSH (puerto 22). No se abre ningún puerto en el router.
- **`terraform/provider.tf`** pasa de `qemu:///system` a `qemu+ssh://...` (variables `hypervisor_ssh_host`/`hypervisor_ssh_user`/`hypervisor_ssh_keyfile`, sin default). Esto unifica también la ejecución manual: el operador tampoco corre Terraform en el propio host, siempre remoto por SSH — mismo code path que CI.
- **Inventario de Ansible** (`terraform/templates/inventory.yaml.tftpl`): el grupo `hypervisor` deja de ser `ansible_connection: local` y pasa a SSH real; el grupo `k0s` (VM en la red NAT interna de libvirt, solo alcanzable desde el propio hipervisor) usa `ProxyCommand` para saltar a través del hipervisor.
- **State remoto en Cloudflare R2** (S3-compatible) vía el backend nativo `s3` de Terraform con endpoint custom — reutiliza la cuenta Cloudflare ya usada para DNS/Tunnel en vez de sumar una plataforma nueva. Locking nativo con `use_lockfile = true` (Terraform ≥ 1.10), sin DynamoDB.
- **Alcance del pipeline automático** (`.github/workflows/deploy.yml`, push a `master`): `terraform apply` + `ansible-playbook site.yaml` + `ansible-playbook host-network.yaml` + `vault-populate.yaml` + `load-extra-secrets.yaml`, detrás del Environment `prod` (aprobación manual requerida). Solo `teardown.yaml` (destructivo, interactivo) queda fuera del pipeline.
- `.github/workflows/terraform-plan.yml` corre `terraform plan` y comenta el resultado en cada PR que toque `terraform/**`, sin gate de aprobación (no muta infraestructura).

### Consecuencias

- El homeserver deja de tener terraform/ansible ejecutándose sobre él: solo recibe conexiones SSH entrantes por Tailscale.
- Nueva dependencia externa: Tailscale (tailnet + OAuth client) y una cuenta/bucket de Cloudflare R2.
- Los secrets de infraestructura crecen (`TS_OAUTH_CLIENT_ID`/`TS_OAUTH_SECRET`, `HOMESERVER_SSH_PRIVATE_KEY`, `R2_ACCOUNT_ID`/`R2_ACCESS_KEY_ID`/`R2_SECRET_ACCESS_KEY`, `ANSIBLE_VAULT_PASSWORD`) — todos como GitHub Secrets, ninguno en el repo.
- El flujo manual documentado en `docs/INSTALL.md` sigue funcionando igual, ahora también remoto (misma URI `qemu+ssh://` que usa CI) en vez de local al hipervisor.

**Actualización (2026-09-06):** `load-extra-secrets.yaml` deja de ser "uno-off manual" y pasa a correr en cada deploy automático, junto a `vault-populate.yaml`. Motivo: nunca se ejecutó ni una sola vez desde que el cluster existe (por ser manual, se olvidó), dejando varios servicios (`redis`, `postgresql` app, `mongodb` app, `grafana`, `sonarqube-db`) sin sus secrets desde el día 1. `ansible/extra-secrets.yaml` pasa de vivir fuera de Git (`.gitignore`, texto plano) a versionado y cifrado con `ansible-vault` (mismo patrón que `group_vars/all.yaml`) — se edita con `ansible-vault edit ansible/extra-secrets.yaml`. Para que un cambio se propague sin pasos manuales: el `ExternalSecret` correspondiente debe tener un `refreshInterval` corto (`1m`, no el `1h` por defecto) y el Deployment/StatefulSet que lo consume debe quedar cubierto por Reloader (`autoReloadAll: true` ya cubre los recursos planos; Grafana necesitó la annotation explícita porque no relee su secret de admin en caliente).

## ADR-010: Cilium Gateway API para ingress genérico, Agent Gateway solo para MCP

**Estado**: Aceptado — reduce el alcance de Agent Gateway (ver [ADR-002](#adr-002-agent-gateway-como-ingress))  
**Fecha**: 2026-09-05

### Contexto

El ADR-002 adoptó Agent Gateway como único ingress por dos razones: (a) ser Gateway API nativo (vs. la Admin API de APISIX) y (b) soporte nativo para AI workloads y protocolo MCP. Revisando el uso real en el repo: de los 13 `HTTPRoute` existentes, solo 2 sirven servidores MCP de verdad (SonarQube MCP, OpenMemory) — el resto es tráfico HTTP genérico (ArgoCD, Grafana, Longhorn, OpenBao, Hubble, Headlamp, Flow API, Portfolio, SonarQube UI) que no usa ninguna feature diferencial de Agent Gateway, solo `Gateway`/`HTTPRoute` estándar.

Cilium (ya desplegado como CNI del cluster) implementa su propio Gateway API controller sobre Envoy/eBPF, con conformance Gateway API v1.6.1, pero sin ningún entendimiento del protocolo MCP: no hace multiplexing de servidores MCP, tool namespacing ni virtual MCP — eso sí lo hace Agent Gateway de forma nativa (confirmado contra la documentación oficial de agentgateway.dev). Mantener Agent Gateway como único gateway significa sostener un proyecto joven, con comunidad menor, para tráfico que no aprovecha su diferencial.

### Opciones consideradas

| Opción | Razón de descarte |
|--------|-------------------|
| **Mantener solo Agent Gateway** | Sostiene un segundo proxy/CRD para tráfico que Cilium ya puede servir igual de bien vía Gateway API estándar |
| **Migrar todo a Cilium, retirar Agent Gateway** | Pierde la única capacidad diferencial real (multiplexing/virtual MCP) que sí se planea seguir usando/explorando a futuro |

### Decisión

**Híbrido**: dos `Gateway` conviviendo en el namespace `networking`, cada uno con su propósito:

- **Cilium Gateway API** (`gatewayClassName: cilium`, `Gateway` `main`) sirve el tráfico HTTP genérico — 10 de los 13 `HTTPRoute` actuales.
- **Agent Gateway** (`gatewayClassName: agentgateway`, `Gateway` `agentgateway-mcp`) queda retenido solo para las rutas que dependen de servidores MCP (SonarQube MCP, OpenMemory) y su propia admin UI.

Los CRDs de Gateway API ya estaban instalados por una Application separada (`gateway-api-crds`, no forma parte del chart de Cilium ni del de Agent Gateway), así que ambos controllers los comparten sin duplicación.

### Consecuencias

- `bootstrap/cilium/values.yaml` pasa `gatewayAPI.enabled` a `true` — Cilium crea automáticamente la `GatewayClass cilium` y, por cada `Gateway`, un `Service` `cilium-gateway-<nombre>`.
- El tunel de Cloudflare (config remota, fuera de Git) debe reapuntar manualmente los hostnames migrados hacia el nuevo Service de Cilium — no hay forma de versionar ese cambio.
- Queda abierta la puerta a seguir experimentando con features de protocolo MCP (nuevos servidores, virtual MCP) sin tener que reintroducir Agent Gateway desde cero.
- El TLS interno (listener HTTPS en cualquiera de los dos Gateway) sigue sin resolverse — ninguno de los dos tiene un listener HTTPS ni referencia el certificado wildcard; deuda técnica preexistente al ADR-002, no introducida ni resuelta por este cambio.

## ADR-011: Segmentar acceso público (Cloudflare) vs privado (LAN + Tailscale)

**Estado**: Aceptado  
**Fecha**: 2026-09-06

### Contexto

De las 13 rutas del cluster, la mayoría son herramientas de administración/observabilidad (ArgoCD, Grafana, Headlamp, Hubble, Longhorn, OpenBao, SonarQube UI, admin UI de Agent Gateway, OpenMemory UI/API, SonarQube MCP) que nunca deberían haber sido alcanzables desde Internet — solo `portfolio` (sitio personal) y `api.cristianpuenguenan.online` (`/webhooks`, consumida por servicios externos) son públicas de verdad.

Qué está expuesto a Internet o no se decide en el dashboard de Cloudflare (Zero Trust → Public Hostnames) — pero ver la actualización del 2026-09-06 abajo: acá se asumió que existía una entrada por ruta, cuando en realidad hay un único wildcard, y el fix real sí requirió mover `HTTPRoute`. Además faltaba una vía de acceso privada real: investigando, `ansible/host-network.yaml` (forward de puertos LAN → VM) ya estaba roto — hacía forward al puerto 80/443 de la VM, pero ningún proceso escuchaba ahí (los Services de ambos Gateways son `LoadBalancer` sin IP asignada, sin ningún MetalLB u otro controlador que los resolviera; solo existían sus `NodePort` aleatorios).

### Decisión

- **Cilium L2 Announcements + LB IPAM** (nativo desde Cilium 1.20, sin instalar MetalLB aparte): dos `CiliumLoadBalancerIPPool` de una IP cada uno (`192.168.122.240` y `192.168.122.250`, deliberadamente no consecutivas dentro de la subred NAT de libvirt) + `CiliumL2AnnouncementPolicy` sobre `eth0` de la VM. Cada `Gateway` fija su IP con `spec.addresses` (campo estándar de Gateway API v1) — pero el controller de **Agent Gateway no lo traduce** a una petición real en el `Service` que genera (confirmado contra el cluster: sin la annotation `io.cilium/lb-ipam-ips`, a diferencia de Cilium que sí la agrega). Con un pool compartido sin filtro, Cilium LB IPAM le daba la primera IP libre a `agentgateway-mcp` sin que la pidiera, pisando la IP que le correspondía al Gateway de Cilium. Solución: un pool de 1 IP por `Service`, seleccionado por `serviceSelector` (`io.kubernetes.service.name`/`.namespace`, metadata especial de Cilium) en vez de depender de `spec.addresses`.
- **`ansible/host-network.yaml`** reescrito: en vez de un forward a la IP de la VM, dos juegos de reglas — `80/443` → IP de Cilium, `8080/8443` → IP de Agent Gateway (puerto 80/443 real ahí). Cubre la LAN física (dispositivos sin Tailscale).
- **Tailscale subnet router**: el hipervisor (ya en el tailnet, hasta ahora solo para SSH de CI) pasa a anunciar `192.168.122.0/24` (`tailscale up --advertise-routes=192.168.122.0/24`, aprobado una vez en el admin de Tailscale) — cualquier dispositivo del usuario en su tailnet llega directo a las IPs de los Gateways, sin pasar por el forward del host, desde cualquier lado (no solo en casa).
- **Cloudflare dashboard**: ver actualización 2026-09-06 abajo — este punto original (sacar 11 rutas de una lista) asumía un modelo que no existe.

### Consecuencias

- Riesgo aceptado: `192.168.122.240` y `192.168.122.250` caen dentro del rango DHCP *configurado* de libvirt (`.2`–`.254`), aunque hoy solo la VM usa esa red (`.10`). Colisionaría si se agregan más VMs a la misma red NAT sin antes reducir el rango DHCP de libvirt.
- Acceso privado sin Split DNS por ahora: se accede por IP directa (con el header `Host` correcto) o agregando entradas al `hosts` file local. Tailscale Split DNS queda como mejora futura, no resuelta acá.
- El acceso LAN "sin Tailscale" (dispositivos que el usuario no controla o no quiere sumar al tailnet) queda limitado a quien tenga acceso físico a la LAN de casa — el resto del mundo, incluido el propio usuario fuera de casa, entra por Tailscale.

**Actualización (2026-09-06):** el punto de partida de este ADR era incorrecto — Cloudflare no tiene una entrada de Public Hostname por ruta, tiene un único wildcard (`*.cristianpuenguenan.online`) apuntando a un solo destino. Consecuencia real no anticipada: con ese modelo, **cualquier** `HTTPRoute` que exista contra el Gateway al que apunta el wildcard es automáticamente pública — no hay lista que editar para "sacar" una ruta. El fix correcto no es gestionar una lista (el usuario explícitamente no lo quería, con razón), sino estructural: un **tercer `Gateway`, `public`** (`platform/networking/cilium-gateway/gateway-public.yaml`), sin IP LAN fija (su único consumidor es `cloudflared`, vía `ClusterIP`), donde viven *únicamente* los `HTTPRoute` de `portfolio` y `flow-api` (movidos ahí, `parentRefs` actualizado). El wildcard de Cloudflare se reapunta una sola vez a `cilium-gateway-public.networking.svc.cluster.local:80`. Lo que es público queda decidido por dónde vive el `HTTPRoute` en el código, no por una lista aparte — agregar una ruta nueva a `main`/`agentgateway-mcp` nunca la expone a Internet por accidente.

**Actualización (2026-09-06): DNS privado.** Las rutas de `main`/`agentgateway-mcp` solo se podían alcanzar por IP directa o `hosts` file manual. Se agregó `platform/networking/private-dns/` — un `CoreDNS` propio (imagen oficial `coredns/coredns`, no `dnsmasq`: no hay ninguna imagen de `dnsmasq` bien mantenida, y CoreDNS ya es el servidor que usa Kubernetes internamente) con el plugin `hosts` sirviendo un registro A estático por cada ruta privada, `fallthrough` + `forward` al DNS público real (`1.1.1.1`/`1.0.0.1`) para todo lo demás — nunca se convierte en agujero negro si algo lo usa por error. IP fija `192.168.122.253` vía el mismo mecanismo de Cilium L2 Announcements ya usado para los Gateways (`CiliumLoadBalancerIPPool` con `serviceSelector`). Vive **dentro** del cluster, no en el hipervisor: si el cluster está caído estos hostnames no servirían para nada de todos modos (apuntan a servicios del mismo cluster caído), así que no suma un punto de falla nuevo — y **no** se usa como DNS primario de la LAN completa, solo resuelve `cristianpuenguenan.online` (Tailscale Split DNS y el forward de puerto 53 en `ansible/host-network.yaml` lo acotan a eso). Reloader (`autoReloadAll`) reinicia el pod solo cuando cambia el `ConfigMap` del `Corefile` — agregar una ruta nueva es solo `git push`.

