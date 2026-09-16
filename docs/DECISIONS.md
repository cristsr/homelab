# Decisiones de Arquitectura (ADR)

Registro de las principales decisiones técnicas tomadas en el homelab. Cada entrada explica el contexto que motivó la decision, las alternativas evaluadas y las consecuencias.

---

## ADR-001: k0s como distribución Kubernetes

**Estado**: Superseded por [ADR-014](#adr-014-migración-de-k0slibvirtfedora-a-talos-linuxproxmox-ve-y-de-openebs-lvm-a-openebs-zfs-localpv) — reemplazó MicroK8s  
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

**Estado**: Superseded por [ADR-013](#adr-013-reemplazo-de-longhorn-por-openebs-local-pv-lvm)  
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

> **Actualización (ADR-015)**: la clave de unseal y el resto de las credenciales ya no viven cifradas en el repositorio con `ansible-vault` — viven en `secrets/homelab.env`, plano y gitignored, cargadas a OpenBao con un script manual.

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

**Estado**: Superseded por [ADR-014](#adr-014-migración-de-k0slibvirtfedora-a-talos-linuxproxmox-ve-y-de-openebs-lvm-a-openebs-zfs-localpv)
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

**Actualización (2026-09-07): el sync de ArgoCD llevaba roto desde el 13 de mayo, sin que nadie lo notara.** Investigando por otro motivo, se encontró que `argocd-cm` tiene `timeout.reconciliation: 0s` (deshabilita el polling periódico por completo — la intención original, según las tareas de `docs/TODO.md`, era dejarlo como *fallback* de 600s, no apagarlo) y que el webhook de GitHub configurado en el repo (`https://argocd.cristianpuenguenan.online/api/webhook`, activo desde 2026-05-13) devuelve 404 en cada entrega: la URL apunta al dominio público, pero ningún `HTTPRoute` la sirve ahí — ArgoCD solo tenía ruta privada. Con las dos cosas rotas a la vez, ArgoCD nunca detectó un commit nuevo salvo que alguien lo refrescara a mano desde la UI; se encontraron Applications hasta 15+ commits atrasadas.

Fix: **`platform/argocd/httproute-webhook.yaml`**, una `HTTPRoute` nueva contra el Gateway `public`, hostname `argocd.cristianpuenguenan.online`, que expone *solo* el path `/api/webhook` (el resto de ArgoCD sigue sin ruta pública) — el payload va firmado (HMAC) contra `webhook.github.secret`, ya mezclado en `argocd-secret` por `webhook-externalsecret.yaml` desde que se implementó esto (`docs/TODO.md` #3), así que exponer el path es seguro sin cambios adicionales. Y `timeout.reconciliation` pasa de `0s` a `600s` (`bootstrap/argocd/values.yaml`) — el webhook sigue disparando el sync al instante en el caso normal, pero un fallo de entrega ya no deja el cluster sin sincronizar silenciosamente por meses.

**Actualización (2026-09-07): Agent Gateway crasheaba en loop hacía más de un día, causa distinta y también preexistente.** El pod de `agentgateway` (namespace `networking`) nunca llegaba a `Ready` — sus logs mostraban un informer esperando indefinidamente el CRD `tcproutes.gateway.networking.k8s.io`, que no existe en el cluster: `gitops/apps/platform/networking/gateway-api-crds.yaml` instalaba el canal `standard` (v1.6.1) de Gateway API, que no incluye `TCPRoute`/`UDPRoute`/`TLSRoute` (esos viven en el canal `experimental`, superset del `standard` — mismos CRDs base sin cambios de esquema). Fix: cambiar `path: config/crd/standard` → `path: config/crd/experimental`, mismo `targetRevision`. Esto es lo que dejaba las 3 rutas de Agent Gateway (`mcp`, `openmemory-api`, `agentgateway`) en `503` durante toda la migración de dominio de ADR-012 — confirmado que el error era identico en `.internal` y en el dominio nuevo, así que no era una regresión de esa migración.

**Actualización (2026-09-09, ver ADR-015):** `vault-populate.yaml` y `load-extra-secrets.yaml` salen del pipeline automático — la carga de secretos en OpenBao pasa a ser 100% manual (`scripts/load-secrets-to-openbao.sh`), nunca corre en CI. El secret `ANSIBLE_VAULT_PASSWORD` deja de usarse (ya no hay `ansible-vault` en el repo); el preflight ahora toma sus 6 credenciales desde GitHub Actions secrets/vars inyectados como env vars del step (`ARGOCD_GITHUB_PAT`, `OPENBAO_STATIC_SEAL_KEY` ya existían como secrets para Terraform; se suman `ARGOCD_WEBHOOK_SECRET`, `CLOUDFLARE_API_TOKEN`, `CLOUDFLARED_TOKEN` como secrets nuevos y `ARGOCD_REPO_URL` como variable — ver `docs/CI_CD_HYPERVISOR_SETUP.md`).

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

**Actualización (2026-09-06): el acceso LAN seguía roto, causa distinta.** Tras arreglar las IPs fijas, el forward-port de `ansible/host-network.yaml` seguía sin funcionar desde dispositivos reales de la LAN (confirmado con un celular real — ni siquiera un `ping` bastaba como prueba, hacía falta HTTP/DNS real). Troubleshooting con `tcpdump` en la interfaz LAN y `virbr0` simultáneamente: el `SYN` llegaba al hipervisor, firewalld aplicaba el DNAT correctamente (confirmado inspeccionando `nft list ruleset` — la tabla `nat_PRE_FedoraServer_allow` con las reglas correctas, dispatch de zona verificado), pero el paquete **nunca salía hacia `virbr0`** — el hipervisor respondía `ICMP port unreachable` en su propio nombre. Causa real: `table ip libvirt_network` (gestionada por `libvirtd`, no por firewalld) tiene una cadena `guest_input` que por diseño **rechaza cualquier conexión nueva entrante hacia la red NAT virtual**, incluso después del DNAT — solo deja pasar tráfico de conexiones ya establecidas (protección estándar de libvirt para redes NAT, para que VMs detrás de NAT no reciban conexiones no solicitadas). Validado insertando una regla `accept` de prueba antes del `reject` — el mismo `curl` que daba `000` pasó a dar `404` real (conexión + DNAT + respuesta del Gateway, solo faltaba el `Host` header correcto).

Solución persistente: `ansible/host-network.yaml` instala `/etc/libvirt/hooks/network` (`ansible/templates/libvirt-network-hook.sh.j2`) — un hook que libvirt invoca en cada evento de su red `default`; en el evento `started` (incluido tras un reboot del hipervisor, cuando libvirt regenera `guest_input` desde cero) reinserta las 6 excepciones `accept` necesarias (una por combinación IP:puerto de los 3 Services con IP fija: `main`, `agentgateway-mcp`, `private-dns`). No se pudo usar el elemento `<portForward>` de libvirt (existe, pero es para interfaces `passt` de una VM individual, no para redes `<forward mode='nat'>` tradicionales con bridge como esta) — el patrón de hook es el soportado para este caso.

**Actualización (2026-09-06): dominio propio para lo privado (`cristianpuenguenan.internal`).** Con todo lo anterior funcionando, seguía apareciendo un `404` confuso al probar una ruta privada sin el DNS interno configurado en el dispositivo: `argocd.cristianpuenguenan.online` resuelve igual contra el registro público real de Cloudflare (el wildcard), cayendo en el Gateway `public` — un `404` que parece un bug de la app pero en realidad es "nunca llegaste al CoreDNS privado". Fix: los 11 `HTTPRoute` de `main`/`agentgateway-mcp` pasan a `*.cristianpuenguenan.internal` (`.internal` no es un TLD delegado en el DNS público, nunca puede colisionar), y el `Corefile` de `platform/networking/private-dns/configmap.yaml` sirve ese dominio en vez de `.online`. `portfolio`/`api` (Gateway `public`) siguen en `.online`, sin cambios. Con esto, sin el DNS privado configurado el hostname privado directamente no resuelve (NXDOMAIN) — un error inequívoco de "falta configurar DNS", no un `404` ambiguo.

## ADR-012: TLS para las rutas internas con CA privada del cluster

**Estado**: Aceptado
**Fecha**: 2026-09-06

### Contexto

Las rutas privadas servían todo por HTTP plano (puerto 80). Además, el acceso "LAN física sin Tailscale" exigía mantención permanente (hosts file por dispositivo, puertos explícitos `:8080`, excepciones de firewall) para un caso de uso que en la práctica no se usa: todos los dispositivos reales del usuario están en el tailnet.

Restricción dura para el TLS: `.internal` es un TLD reservado — el CA/Browser Forum prohíbe a las CAs públicas emitir certificados para él. Let's Encrypt no es opción para `*.cristianpuenguenan.internal`.

### Decisión

- **CA privada dentro del cluster** (`platform/networking/cert-manager/internal-tls.yaml`), replicando el patrón ya existente de la PKI de Hubble: Issuer `selfSigned` → `Certificate` `internal-root-ca` (isCA, 10 años) → `ClusterIssuer` `internal-ca` → leaf. Sin dependencia de ninguna CA externa; la renovación es automática vía cert-manager.
- **Wildcard único** `*.cristianpuenguenan.internal` (+ apex) en el secret `wildcard-internal-tls` (namespace `networking`), referenciado por el listener `https` (TLS terminate) de `main`. Un solo certificado que renovar, no 11.
- **Redirect 301 HTTP→HTTPS en `main`**: el puerto 80 queda restringido (`allowedRoutes` solo namespace `networking`) a una `HTTPRoute` catch-all con filter `RequestRedirect`. Las 8 rutas de contenido de `main` fijan `sectionName: https` en sus `parentRefs` — sin eso se adjuntarían a ambos listeners y servirían contenido por HTTP igual.
- **`agentgateway-mcp` se queda en HTTP plano** (excepción documentada): su controller (v1.1.0) ignora silenciosamente los listeners HTTPS — no crea el listener en `status`, ni el puerto 443 en el Service, ni reporta error/evento alguno. Las 3 rutas MCP (`mcp`, `openmemory-api`, `agentgateway` UI) sirven por el puerto 80 del tailnet privado; el transporte ya está cifrado por WireGuard en el plano de Tailscale. Reevaluar cuando Agent Gateway soporte TLS termination.
- **Tailscale como única vía soportada** para dispositivos: la LAN física sin Tailscale queda declarada fuera de alcance (el redirect a HTTPS apunta a IPs internas inalcanzables desde la LAN — falla explícita, no degradada). Los forward-ports y el hook de libvirt se mantienen porque el tráfico Tailscale→cluster que atraviesa el hipervisor los sigue necesitando.

### Consecuencias

- La CA debe confiarse a mano una vez por dispositivo del tailnet (`docs/OPERATIONS.md` §11.5) — aceptable porque el usuario controla todos los dispositivos; un visitante en la LAN no puede usar estas rutas de ninguna forma.
- Si el secret `internal-root-ca` se pierde, la CA regenerada no será confiable por los dispositivos hasta repetir la instalación (hoy no hay backup específico del secret; el certificado dura 10 años).
- El plano público no cambia: Cloudflare sigue terminando TLS en el borde para `portfolio`/`api`; `wildcard-home-tls` (Let's Encrypt) sigue emitido pero sin referenciar.
- Las URLs de las 3 rutas de Agent Gateway quedan `http://` (puerto 80): `http://mcp.cristianpuenguenan.internal/sonarqube`, `http://openmemory-api...`, `http://agentgateway...` — el resto de las privadas son `https://`.
- Apps sin cambios: ArgoCD ya corría `--insecure` (TLS delegado al edge es el patrón previsto); Grafana/Headlamp no usan cookies `secure`.

**Actualización (2026-09-06): las 3 rutas de Agent Gateway también pasan a HTTPS.** La excepción de arriba ("`agentgateway-mcp` se queda en HTTP plano") seguía dejando esas 3 URLs sin TLS de cara al cliente, no solo como excepción interna — y el controller de Agent Gateway sigue sin soportar listeners HTTPS, así que no había manera de resolverlo ahí directamente. Solución: **`main` hace de proxy TLS hacia `agentgateway-mcp`**, no distinto de cómo ya proxya hacia cualquier otro backend — una nueva `HTTPRoute` (`platform/networking/cilium-gateway/httproute-agentgateway-proxy.yaml`) con `parentRefs: [{name: main, sectionName: https}]`, las 3 hostnames, y `backendRefs` apuntando directo al `Service agentgateway-mcp:80` (mismo namespace `networking`, sin `ReferenceGrant`). Sin matching de path ni rewrite: Agent Gateway sigue haciendo su propio ruteo/rewrite/multiplexing puertas adentro con sus `HTTPRoute` de siempre (`mcp-sonarqube`, `openmemory`, `agentgateway-ui`), que no cambiaron — solo cambió quién le entrega el tráfico. Con esto vuelven a ser 11 rutas (no 8) con `sectionName: https` contra `main`.

Consecuencia: `agentgateway-mcp` ya no necesita IP LAN propia. Pasa a `Service` `ClusterIP` (`gateway.controller.service.type` en `platform/networking/agentgateway/agentgateway.yaml`) — el `spec.addresses: 192.168.122.250` del `Gateway` se quita (ya era dead config, ver arriba: el controller nunca lo tradujo a una petición real) y se elimina su `CiliumLoadBalancerIPPool` en `lb-ippool.yaml` (huérfano sin `Service LoadBalancer` que lo reclame). El DNS privado (`private-dns/configmap.yaml`) mueve `mcp`/`agentgateway`/`openmemory-api`.internal de `.250` a `.240`, y se limpian del `ansible/host-network.yaml` y del hook de libvirt las reglas de forward-port/firewall que apuntaban a `.250` (quedaban apuntando a nada). El plano de acceso queda simétrico: las 11 rutas privadas entran todas por `192.168.122.240:443`, sin excepciones de transporte visibles para el cliente.

**Actualización (2026-09-07): se abandona la CA propia — Let's Encrypt real vía subdominio de `cristianpuenguenan.online`.** La CA privada (`internal-root-ca`) cumplía, pero exigía instalarla a mano en cada dispositivo del tailnet (`certutil -addstore`, una vez por dispositivo — tedioso y fácil de olvidar en uno nuevo), y expone un riesgo de fondo no evidente al momento de decidir: un dispositivo que confía en una CA raíz propia confía en **cualquier** certificado que esa CA firme, para **cualquier** dominio — si la clave privada del secret `internal-root-ca` se filtrara, alguien podría falsificar un certificado válido para cualquier sitio (banco, `google.com`, etc.) y ese dispositivo lo aceptaría sin avisar. Decisión: reemplazar por un certificado real.

`.internal` sigue sin poder usarse con una CA pública (sigue siendo TLD reservado, sin cambios en esa restricción) — pero el usuario ya es dueño de `cristianpuenguenan.online`, que ya tiene un `ClusterIssuer` de Let's Encrypt funcionando vía DNS-01 (`letsencrypt-prod-cloudflare-dns01`, el mismo que emite `wildcard-home-tls`). El desafío DNS-01 **no exige que el nombre resuelva a nada real** — solo que se pueda crear un registro TXT `_acme-challenge.*` vía la API de Cloudflare, algo que cert-manager ya hace. Eso permite pedir un wildcard real para un subdominio dedicado, `*.internal.cristianpuenguenan.online`, sin publicar jamás un registro A/AAAA para él.

Migración ejecutada en 3 fases para no arriesgar el cluster (nunca se cortó acceso a las rutas de administración):

1. **Aditiva**: nuevo `Certificate` `wildcard-internal-online` (mismo Issuer que `wildcard-home-tls`) → secret `wildcard-internal-online-tls`; segundo listener HTTPS en `main` (`https-online`, con su propio `hostname` y `certificateRefs` — **Cilium/Envoy no soporta múltiples `certificateRefs` en un mismo listener**, dos listeners con `hostname` disjuntos en el mismo puerto 443 es el patrón soportado para servir 2 certs por SNI); las 11 `HTTPRoute` reciben el hostname nuevo además del viejo (y un segundo `parentRef` donde adjuntan directo a `main`); `private-dns` resuelve ambos dominios. Nada del `.internal` viejo se tocó.
2. **Habilitación real**: se agregó una segunda entrada de Tailscale Split DNS (mismo nameserver `192.168.122.253`, restringida a `internal.cristianpuenguenan.online`) — sin esto el hostname nuevo no resolvía para ningún dispositivo del tailnet.
3. **Decomiso**: una vez confirmado en vivo desde un dispositivo real (TLS válido, sin instalar nada, `curl`/navegador sin `-k`), se sacaron el hostname y el listener viejos, y se borró `platform/networking/cert-manager/internal-tls.yaml` completo (Issuer selfSigned + CA + ClusterIssuer `internal-ca`).

**Hallazgo durante la validación, corrección a lo documentado arriba sobre "nunca resuelve publicamente":** el wildcard **público** `*.cristianpuenguenan.online` sí matchea por DNS a `argocd.internal.cristianpuenguenan.online` y demás — las reglas de wildcard DNS (RFC 1034 §4.3.3) aplican a cualquier profundidad de subdominio mientras no exista un registro explícito bloqueando un nivel intermedio (`internal.cristianpuenguenan.online` no tiene ninguno). Confirmado en vivo: `nslookup argocd.internal.cristianpuenguenan.online 1.1.1.1` responde con las IPs de Cloudflare. Esto **no es una brecha real**: al conectar de verdad contra esa IP con ese hostname, el handshake TLS falla en el borde de Cloudflare (`SEC_E_ILLEGAL_MESSAGE`, alerta fatal) porque ese hostname nunca fue dado de alta como "Hostname" válido en la config SSL de Cloudflare — la resolución DNS es pública, la conexión no. Distinto de `.internal` (que daba `NXDOMAIN` limpio), pero funcionalmente equivalente en seguridad.

Consecuencias:
- Cero instalación por dispositivo, para siempre — el certificado lo confía cualquier navegador de fábrica.
- Certificate Transparency: cualquiera puede ver en `crt.sh` que existe `*.internal.cristianpuenguenan.online` — revela que hay una zona de administración privada (no revela qué hostnames específicos, esos nunca se emiten individualmente), algo que con `.internal` (TLD reservado) no era ni remotamente posible. Riesgo aceptado: es solo reconocimiento, no acceso.
- Un solo `ClusterIssuer` para los dos wildcards (público y privado) — mismo token de Cloudflare, sin credenciales nuevas.
- Riesgo de error humano ligeramente mayor que antes: `.internal` y `.online` eran visualmente imposibles de confundir; `internal.cristianpuenguenan.online` vs `cristianpuenguenan.online` difieren en una sola etiqueta — un `HTTPRoute` mal armado (parentRef al Gateway `public` en vez de `main`, o el hostname sin el prefijo `internal.`) expondría una ruta de administración a Internet. Mitigado por convención de nombres consistente y revisión de diffs, no por control automático.

---

## ADR-013: Reemplazo de Longhorn por OpenEBS Local PV LVM

**Estado**: Superseded por [ADR-014](#adr-014-migración-de-k0slibvirtfedora-a-talos-linuxproxmox-ve-y-de-openebs-lvm-a-openebs-zfs-localpv) — el motor LVM elegido acá se reemplazó por ZFS al migrar a Talos (ver ADR-014); el razonamiento de esta entrada (por qué no Longhorn) sigue vigente.  
**Fecha**: 2026-09-08

### Contexto

ADR-004 descartó OpenEBS por "más complejo de configurar, comunidad más pequeña" y adoptó Longhorn con réplicas=1 (sin ganancia real de redundancia en single-node). Ese mismo mecanismo de Longhorn —volúmenes expuestos vía iSCSI (`iscsid`, `ansible/tasks/longhorn-prereqs.yaml`)— resultó ser la causa más probable de un cuelgue real de `k0s reset` durante un teardown (2026-09-07, documentado en memoria de sesión y en `ansible/tasks/graceful-shutdown.yaml`): si el kubelet muere antes de que el CSI driver desmonte y haga logout de esas sesiones, quedan mounts/sesiones "busy" que cuelgan el `umount` interno del reset.

Se aprovechó un ciclo de teardown/rebuild del cluster (sin cargas productivas todavía) para revisar la decisión: en un solo nodo, la capa de red + réplicas + iSCSI de Longhorn no compra nada (replicaCount ya estaba fijo en 1) y sí paga en superficie de fallo y en throughput/latencia frente a un motor puramente local.

### Opciones consideradas

Motores de OpenEBS Local PV evaluados para reemplazar a Longhorn (ver tabla completa de trade-offs discutida con el operador):

| Opción | Razón de descarte / elección |
|--------|------------------------------|
| **Local PV Hostpath** | Máxima performance y cero aprovisionamiento adicional, pero sin snapshots ni resize online ni thin-provisioning |
| **Local PV ZFS** | Requiere ZFS (DKMS/kmod) en un host Fedora que no lo trae por defecto — más piezas nuevas que mantener |
| **Mayastor (NVMe-oF)** | Pensado para replicación multi-nodo; overkill para un solo nodo, no aporta nada sobre Local PV |
| **Local PV LVM** (elegido) | Requiere un Volume Group LVM dedicado (no existía) — a cambio da snapshots, thin-provisioning y resize online con performance cercana a la nativa del disco |

### Decisión

**OpenEBS Local PV LVM** (chart standalone `lvm-localpv` de `https://openebs.github.io/lvm-localpv`, no el paquete umbrella `openebs/openebs` con NDM/Mayastor — solo se instala el motor que se usa):

- Disco dedicado nuevo (`vdb`, raw, sin `backing_store` qcow2) en la VM vía Terraform (`libvirt_volume.openebs_data_disk`, `terraform/variables.tf` `openebs_disk_size_bytes`), separado del disco raíz para que el VG no compita con el filesystem del SO.
- Volume Group `vg-openebs` creado por Ansible (`ansible/tasks/openebs-prereqs.yaml`, idempotente vía `pvcreate`/`vgcreate`), reemplazando el prerequisito de `iscsi-initiator-utils`/`iscsid`.
- Mismo split de dos StorageClasses que Longhorn, renombradas 1:1 para minimizar el diff en los consumidores: `openebs-lvm` (default, `Delete`) y `openebs-lvm-retain` (`Retain`, bases de datos). `provisioner: local.csi.openebs.io`, `parameters: {storage: "lvm", volgroup: "vg-openebs"}`.
- Namespace `openebs` (reemplaza `longhorn-system`).
- ServiceMonitor propio del chart (`lvmNode.serviceMonitor.enabled: true`) en vez del ServiceMonitor manual que tenía Longhorn.

### Consecuencias

- **Sin UI web**: Longhorn tenía una UI propia (HTTPRoute + DNS `longhorn.internal...`); LVM-LocalPV no tiene equivalente. Se retira sin reemplazo — inspección de volúmenes queda vía `kubectl get lvmvolumes -n openebs` / `lvs`/`vgs` en el nodo.
- **Sin réplicas** (igual que antes: Longhorn ya corría con `replicaCount: 1`, no es una regresión real): un fallo del disco `vdb` es pérdida total de datos. Mitigable con snapshots LVM manuales (`lvcreate --snapshot`), sin automatización todavía — misma deuda de backups que ya existía con Longhorn.
- El footprint de disco de la VM sube de 120GiB a 120+100GiB (root + VG dedicado).
- Se simplifica el ciclo de shutdown: sin iSCSI de por medio, `ansible/tasks/graceful-shutdown.yaml` ya no necesita esperar "volúmenes detached" ni forzar logout — el drenaje normal de Kubernetes basta, porque LVM-LocalPV monta los LVs directo (sin capa NBD/iSCSI).
- El argumento original de ADR-004 contra OpenEBS ("más complejo de configurar") se acepta ahora a cambio de performance en single-node: el chart standalone de un solo motor (LVM) es en la práctica más simple de operar que Longhorn con su UI, su manager y su engine-image por réplica.

---

## ADR-014: Migración de k0s/libvirt/Fedora a Talos Linux/Proxmox VE, y de OpenEBS LVM a OpenEBS ZFS LocalPV

**Estado**: Aceptado
**Fecha**: 2026-09-09

### Contexto

ADR-008 ya había documentado varias fuentes de fragilidad de la VM libvirt/KVM sobre un host generalista: el hang silencioso con firmware UEFI/OVMF (mitigado forzando BIOS legacy), el footegun de `memory` en KiB por defecto del provider `dmacvicar/libvirt`, y la dependencia de NAT (`192.168.122.0/24`) porque bridging sobre WiFi es frágil. A esto se suma que Ansible seguía siendo responsable de aprovisionar el sistema operativo del nodo por SSH (ADR-007): cada drift de paquetes, configuración o estado del host quedaba fuera del control declarativo de Terraform/GitOps, y era la superficie más grande de fallos no reproducibles del proyecto (incluida la causa raíz de ADR-013: iSCSI de Longhorn colgando `k0s reset` en el teardown).

El paso a un hipervisor dedicado (Proxmox VE) con conectividad LAN real vía bridge (`vmbr0`) resuelve la limitación de red de ADR-008. Y Talos Linux — Kubernetes inmutable, sin SSH ni shell, configurado 100% vía API declarativa (`talosctl`/machine config) — elimina por completo la capa de Ansible-sobre-SSH que aprovisionaba el nodo: ya no hay sistema operativo que mantener, parchear ni al que pueda dividergir del estado declarado.

### Decisión

**Talos Linux sobre Proxmox VE**, con Terraform dividido en dos etapas independientes (dos state files, ver `terraform/infra/versions.tf` y `terraform/cluster/versions.tf`):

- **`terraform/infra`** (providers `bpg/proxmox` + `siderolabs/talos`): descarga el ISO de Talos generado por el [Image Factory](https://factory.talos.dev) con un schematic que incluye las extensiones `qemu-guest-agent`, `tailscale` y `zfs` (`terraform/infra/variables.tf`, `talos_schematic_id`); crea la VM en Proxmox con dos discos — uno para la instalación de Talos y uno dedicado, sin formatear, para el zpool de OpenEBS (`terraform/infra/proxmox.tf`); aplica la machine config (incluye `RawVolumeConfig` para particionar el disco de ZFS) y bootstrapea el cluster (`terraform/infra/talos.tf`).
- **`terraform/cluster`** (providers `kubernetes` + `helm`): namespaces, `helm_release` de Cilium y ArgoCD, y los secrets iniciales del cluster (`terraform/cluster/*.tf`) — reemplaza lo que antes hacía Ansible (`site.yaml`) + Helmfile (`bootstrap/helmfile.yaml`).
- **Red**: la VM pasa de la NAT interna de libvirt (`192.168.122.0/24`) a una IP estática real en la LAN del homelab (`192.168.80.0/24`, bridge `vmbr0` de Proxmox) con MAC fija reservada en el DHCP del router (`terraform/infra/variables.tf`, `vm_mac_address`) — ya no hace falta el port-forward de firewalld que exigía ADR-008 (`ansible/host-network.yaml`, eliminado).
- **Ansible** se reduce a lo que no puede resolverse de forma declarativa dentro de Talos ni de Terraform: `preflight.yaml` (valida credenciales antes de que CI gaste tiempo aprovisionando). Ya no existen `site.yaml`, `teardown.yaml`, `host-network.yaml` ni ninguna task que instale paquetes o configure el nodo — Talos no tiene shell (`nsenter`+`chroot` al host falla con "can't execute 'sh'").
  > **Actualización (ADR-015)**: poblar OpenBao dejó de ser un playbook de Ansible (`vault-populate.yaml`/`load-extra-secrets.yaml`) — es un script standalone (`scripts/load-secrets-to-openbao.sh`) que corre manual, nunca en CI.
- **Storage: OpenEBS LVM (ADR-013) → OpenEBS ZFS LocalPV** (`zfs-localpv` 2.11.1, `platform/storage/openebs/`): la elección de LVM en ADR-013 asumía un host donde Ansible podía correr `pvcreate`/`vgcreate` por SSH — imposible en Talos, que no expone shell ni permite instalar paquetes arbitrarios en el host. ZFS sí es viable porque el módulo de kernel se carga declarativamente vía la extensión `zfs` del schematic y `machine.kernel.modules` (`terraform/infra/talos.tf`); el zpool se crea con un `Job` de Kubernetes (`kubernetes_job_v1.openebs_zpool_create`, `terraform/cluster/storage.tf`) que corre las herramientas de ZFS *dentro* de un contenedor privilegiado montando `/dev` del host, ya que Talos no trae `zfs`/`blkid` en el host y no corre `udev` (se resuelve el device real vía `blkid -t PARTLABEL=`, no `/dev/disk/by-partlabel/`). Nuevas StorageClasses: `openebs-zfs` (default) y `openebs-zfs-retain`.
- **Rename**: la VM y el cluster pasan de `talos-01` a `talos` (un solo nodo, sufijo numérico sin objeto).

### Consecuencias

- **Menos superficie de drift**: no hay sistema operativo del nodo que mantener/parchear/divergir — Talos se actualiza reemplazando la imagen completa (`talosctl upgrade`), no con `apt`/`dnf`.
- **CI/CD (ADR-009) cambia de variables, no de forma**: `TF_VAR_proxmox_endpoint`, `TF_VAR_proxmox_api_token`, `TF_VAR_talos_schematic_id`, `TF_VAR_vm_static_ip`, `TF_VAR_vm_gateway` reemplazan a las variables de libvirt/Fedora en `.github/workflows/deploy.yml` y `terraform-plan.yml`. El flujo de dos `terraform apply` secuenciales (infra → cluster) y el gate de aprobación manual no cambian.
- **Troubleshooting cambia de herramientas**: ya no hay `ssh`/`journalctl`/`k0s ctr` contra el nodo — el equivalente es `talosctl` (logs, dashboard, `talosctl upgrade`) contra la IP del nodo, con el `talosconfig` que genera `terraform/infra/talos.tf` (`local_file.talosconfig`).
- **Deuda pendiente identificada durante esta revisión**: varios manifiestos de `platform/networking/` (Gateway, `CiliumLoadBalancerIPPool`, DNS interno) seguían hardcodeados a la subred vieja de libvirt (`192.168.122.x`) después de la migración — corregido a `192.168.80.x` como parte de este ADR. `docs/ARCHITECTURE.md`, `docs/INSTALL.md` y `docs/OPERATIONS.md` seguían describiendo k0s/libvirt/Fedora — actualizados junto con este ADR.
- **Storage sin réplicas** (igual que con LVM/Longhorn): sigue siendo copia única, local al nodo — no es una regresión de esta migración, es una decisión ya aceptada en ADR-004/013.

---

## ADR-015: Carga de secretos en OpenBao sale de CI/CD, siempre manual

**Estado**: Aceptado
**Fecha**: 2026-09-09

### Contexto

`vault-populate.yaml` y `load-extra-secrets.yaml` corrían automáticamente en cada push a `master` (`.github/workflows/deploy.yml`), escribiendo en OpenBao las credenciales de infraestructura y de aplicaciones (`ansible/group_vars/all.yaml`, cifrado con `ansible-vault` y commiteado; `ansible/extra-secrets.yaml`, plano y gitignored). El operador decidió que la carga de secretos reales en el cluster **nunca** debe depender de un runner de CI, sin importar qué tan controlado esté el pipeline — quiere ejecutarlo a mano siempre. También pidió sacar la dependencia de Ansible específicamente para esta tarea (ansible sigue en uso para `preflight.yaml`).

### Opciones consideradas

| Opción | Razón de descarte |
|--------|-------------------|
| Mantener Ansible pero solo invocarlo a mano | El operador pidió explícitamente no depender de Ansible para esto — prefiere un script sin esa dependencia |
| Dos archivos de secretos separados (infra cifrada con vault + apps en plano) | El operador prefirió unificar en un único archivo plano — más simple de mantener, a costa de perder el respaldo cifrado-en-git de los 5 secretos de infra |

### Decisión

- **`secrets/homelab.env`** (gitignored) + `secrets/homelab.env.example` (commiteado): único archivo con todas las credenciales, infra y apps, formato `KEY=value`. Reemplaza a `ansible/group_vars/all.yaml` (borrado, ya no hay `ansible-vault` en el repo) y `ansible/extra-secrets.yaml.example` (borrado).
- **`scripts/load-secrets-to-openbao.sh`**: bash standalone, sin Ansible. Espera OpenBao/`openbao-init`, hace port-forward, y escribe cada path de KV vía `curl`+`jq`. Reemplaza a `vault-populate.yaml`, `load-extra-secrets.yaml` y `tasks/openbao-kv-write.yaml` (los tres borrados). Se ejecuta a mano, nunca en CI.
- **`.github/workflows/deploy.yml`**: se quitan los steps que corrían esos playbooks. El preflight de credenciales (`ansible/preflight.yaml`, sigue en Ansible) ahora toma sus valores desde GitHub Actions secrets/vars inyectados como env vars del step, en vez de `group_vars/all.yaml` + `ANSIBLE_VAULT_PASSWORD`.
- Las Applications de ArgoCD que dependen de esos secretos (webhook de ArgoCD, `cloudflared`, bases de datos, SonarQube, OpenMemory, Flow) quedan en `Progressing`/`Degraded` hasta que el operador corra el script manualmente — comportamiento esperado, no un fallo del pipeline (los sync-waves ya ordenan OpenBao antes que sus consumidores, y `ExternalSecret` reintenta por `refreshInterval`).

### Consecuencias

- Ningún secreto real puede terminar en el cluster por un push accidental a `master` — requiere una acción manual explícita del operador.
- Se pierde el respaldo cifrado-en-git de los 5 secretos de infra que antes vivían en `group_vars/all.yaml`: si se pierde el `secrets/homelab.env` local sin backup aparte, hay que regenerar/rotar esos tokens.
- Un solo lenguaje (bash) para todo el script en vez de YAML+Jinja de Ansible — más fácil de leer de punta a punta, a costa de perder el manejo de errores/retries estructurado que Ansible daba gratis (reimplementado a mano con `set -euo pipefail` + loops de espera).

> **Actualización (2026-09-09, mismo día):** la primera versión de este ADR hacía que el preflight de CI validara los 6 secretos (incluidos `cloudflare_api_token`, `cloudflared_token`, `argocd_webhook_secret`), exigiendo 3 GitHub Actions secrets nuevos solo para eso. Al revisar antes de desplegar se confirmó que **CI no consume esos 3 valores en ningún paso** — solo los usa `scripts/load-secrets-to-openbao.sh`, que ya los valida por su cuenta antes de escribir en OpenBao. El preflight de CI quedó acotado a lo que Terraform realmente necesita (`argocd_github_pat`, `openbao_static_seal_key`, más `argocd_repo_url` para el chequeo de acceso al repo) — ya no hace falta crear esos 3 secrets en GitHub. De paso se corrigió un bug real: `lookup('env', 'VAR') | default('x')` en Ansible no cae al default cuando la env var existe pero está vacía (que es lo que pasa si un secret de GitHub no está configurado) — hace falta `default('x', true)`.

---

## ADR-016: Servicios de datos fuera del cluster, en LXC de Proxmox — un único PostgreSQL multi-base

**Estado**: Aceptado
**Fecha**: 2026-09-13

### Contexto

El cluster corría cinco servicios de datos dentro de Kubernetes: dos instancias de PostgreSQL gestionadas por **CloudNative-PG** (la del app `homelab` y una dedicada a SonarQube), **MongoDB** vía Percona PSMDB Operator, **Qdrant** y **Redis** — en total dos operadores, seis Applications de ArgoCD y varios PVCs de OpenEBS ZFS con copia única (`openebs-zfs-retain`).

En un cluster de un solo nodo eso no compra ninguna de las ventajas de correr datos en Kubernetes: no hay réplicas, no hay live migration, no hay multitenancy que aislar. Lo que sí suma es superficie — dos operadores y sus CRDs que mantener, NetworkPolicies por servicio, PVCs que compiten con las apps por el zpool del nodo — y, lo peor, **el ciclo de vida de los datos queda atado al del cluster**: cada `talosctl upgrade`, teardown o rebuild del cluster (el propio ADR-014 migró de plataforma completa) arriesga justo lo que debería sobrevivirle.

Proxmox VE ya es el hipervisor del proyecto; un LXC es la forma natural de correr un servicio con estado que no necesita nada de Kubernetes.

### Opciones consideradas

| Opción | Razón de descarte |
|--------|-------------------|
| **Mantener los datos en el cluster** | Sigue acoplando el ciclo de vida de los datos al del cluster; operadores y PVCs consumen el único nodo sin dar nada a cambio (single-node = sin réplicas) |
| **Una VM completa por servicio** | Cuatro VMs con kernel propio para servicios livianos — overhead de RAM/disco innecesario frente a un contenedor de sistema |
| **Un LXC por servicio, PostgreSQL separado por consumidor** | Duplica instancia, RAM, disco y backups de un mismo motor para dos bases pequeñas, sin ganar aislamiento real (mismo hipervisor, mismo host de Proxmox) |

### Decisión

**Cuatro LXC de Debian 13** creados de forma declarativa por Terraform (`terraform/infra/lxc.tf`) — bridge `vmbr0`, datastore `local-lvm`, IP estática en la LAN. Proxmox no soporta cloud-init para LXC (cicustom es exclusivo de QEMU), así que los contenedores se entregan **sin motor instalado**: la instalación de cada motor y sus credenciales (`TF_VAR_*` desde `secrets/homelab.env`) quedan como aprovisionamiento posterior, registrado como deuda en una historia propia:

| LXC | vmid | IP | Motor |
|-----|------|----|-------|
| `postgresql` | 121 | `192.168.80.31` | PostgreSQL 17, bases `homelab` y `sonarqube` |
| `mongodb` | 122 | `192.168.80.32` | MongoDB 8.0 |
| `qdrant` | 123 | `192.168.80.33` | Qdrant v1.x |
| `redis` | 124 | `192.168.80.34` | Redis 8 |

- **Un único PostgreSQL multi-base** reemplaza las dos instancias separadas de antes (la de `homelab` y la de SonarQube): un solo motor que actualizar y respaldar, dos bases lógicas.
- Los consumidores los alcanzan por hostname a través de `private-dns`, con cuatro registros nuevos en el Corefile: `postgres.internal.cristianpuenguenan.online`, `mongodb.internal...`, `qdrant.internal...`, `redis.internal...`. SonarQube apunta a `jdbc:postgresql://postgres.internal.cristianpuenguenan.online:5432/sonarqube`; OpenMemory a `qdrant.internal.cristianpuenguenan.online:6333`; las URLs de Flow ya viven en OpenBao (`secret/apps/flow`) como valores planos — solo se actualizan ahí. Reloader reinicia los Deployments afectados por el cambio de env.
- **Desaparecen del repositorio** los operadores CloudNative-PG y Percona PSMDB, los manifiestos de las instancias y las seis Applications de ArgoCD que los desplegaban, junto con los namespaces que los albergaban. Al mergear, la root app poda las Applications eliminadas y sus finalizers cascaden a los clusters CNPG/PSMDB, Services y NetworkPolicies.
- El ExternalSecret de credenciales de la base de SonarQube se conserva: sigue alimentando `SONAR_JDBC_USERNAME`/`SONAR_JDBC_PASSWORD`, ahora contra la instancia externa compartida.

### Consecuencias

- Los datos sobreviven a upgrades, teardowns y rebuilds del cluster — el cluster vuelve a ser efímero por diseño, tal como lo quiere el enfoque GitOps.
- **Un solo punto de falla compartido**: un upgrade o restart del PostgreSQL LXC afecta a `homelab` y `sonarqube` a la vez. Aceptado a escala homelab (un operador, dos bases pequeñas); si una base llegara a necesitar aislamiento real, se separa en su propio LXC.
- Los backups pasan de `kubectl exec` en pods a herramientas estándar contra la red (`pg_dump`/`mongodump` apuntando a los hostnames `*.internal`), con el backup a nivel de contenedor de Proxmox (`vzdump`) como complemento.
- El cluster libera ~35Gi del zpool de OpenEBS y la RAM/CPU de operadores e instancias; el disco de los LXC vive en `local-lvm` del host de Proxmox, fuera del cluster.
- Las NetworkPolicies de Kubernetes dejaban de aplicar: el perímetro de las bases pasa a ser la LAN del homelab (los LXC viven en `vmbr0`) — la misma confianza que ya asumen los Gateway de Cilium en esa red.
- **La instalación de los motores dentro de los LXC queda pendiente** (deuda registral): hasta ese aprovisionamiento, SonarQube y OpenMemory no tienen base de datos operativa — ventana aceptada por el operador, los datos arrancan desde cero de todos modos.

---

## ADR-017: Reemplazo de OpenBao por 1Password como backend de secretos

**Estado**: Aceptado
**Fecha**: 2026-09-16

### Contexto

Se terminó de desplegar OpenBao en su propia LXC externa (`secrets_lxc`, 192.168.80.35) como sucesor del OpenBao in-cluster (ver ADR-016). En el proceso salieron a la luz varios problemas reales, nunca antes ejercitados porque el playbook nunca se había corrido de punta a punta:

- `ansible/openbao.yaml` pedía `-recovery-shares=1 -recovery-threshold=1` en el init, flags que solo aplican con un `seal` de auto-unseal configurado (no es el caso, seal Shamir plano) — se ignoraban en silencio y el init caía al default de 5 shares / umbral 3, rompiendo el diseño de una sola clave.
- El `Environment=BAO_LOCAL_CONFIG={...}` del Quadlet tenía JSON crudo sin escapar: systemd interpreta las comillas dobles como parte de su propia sintaxis de quoting, así que el contenedor recibía el JSON sin comillas.
- El entrypoint de la imagen inyecta `-dev-listen-address=0.0.0.0:8200` cada vez que el comando es literalmente `server`, sin importar si `-dev` está activo — eso duplicaba el bind del listener y reventaba con "address already in use".
- `ExecStartPost` desellaba inmediatamente al arrancar el contenedor, sin esperar a que el server estuviera realmente escuchando ("connection refused"), y además era fatal en el primer arranque (antes de que existiera `bao operator init`), lo que tumbaba toda la unit antes de llegar a inicializar.
- El storage bind-mounteado quedaba `root:root` pero el proceso dropea privilegios a un usuario no-root (`openbao`, uid 100/gid 1000) — permission denied.
- `bao write auth/kubernetes/config` intentaba autodetectar el CA cert del filesystem estándar de un pod in-cluster, que no existe fuera del clúster.
- Las LXC son `unprivileged` sin `features { nesting, fuse }` — Podman no puede montar overlayfs vía fuse-overlayfs sin eso, afectando también a las LXC de datos.

Todos estos bugs se corrigieron y OpenBao terminó funcionando de punta a punta (init con una sola clave, auto-unseal vía Podman secret en cada arranque, auth de Kubernetes configurado). Pero el operador, después de ver cuánta ceremonia hace falta para un vault funcional en un homelab de un solo operador (seal/unseal, Shamir, backend de auth, policies, roles) — decidió que no vale la pena mantenerlo: prefiere delegar todo eso a un servicio gestionado.

### Opciones consideradas

| Opción | Razón de descarte |
|--------|-------------------|
| Mantener OpenBao con auto-unseal vía AWS KMS (`seal "awskms"`) | Resuelve solo el unseal (deja de ser una clave cruda en un Podman secret) por ~$1/mes, pero no elimina el resto de la ceremonia (init, auth backend, policies, roles) — mejora parcial, no la simplificación que busca el operador. |
| Cloudflare como KMS/secret store | No existe: Cloudflare no tiene un servicio de KMS comparable a AWS KMS, y su "Secrets Store" es exclusivo para bindings de Workers/Pages, sin API externa que ESO pueda consumir. |
| 1Password Connect (self-hosted) | Requiere correr un servidor adicional (API + sync) — más infraestructura a mantener, no menos. Descartado a favor de Service Accounts. |

### Decisión

- **1Password** como backend de secretos, vault dedicado **"Homelab"**, vía un **Service Account** con acceso de solo lectura a ese único vault (no Connect server — sin infraestructura adicional que correr).
- `ClusterSecretStore` usa el provider `onepasswordSDK` (`platform/secret-management/external-secrets/cluster-secret-store.yaml`), autenticado con el token del Service Account guardado en el Secret de Kubernetes `onepassword-service-account-token` (namespace `secret-management`).
- Los 10 `ExternalSecret` del repo pasan a `secretStoreRef.name: onepassword` — el `remoteRef.key`/`property` no cambia: 1Password matchea el título del item con `key` y la label del campo con `property`, y se mantuvieron los mismos strings que ya usaba el árbol KV de Vault (`argocd`, `devtools/openmemory`, `infra/cloudflare`, etc.) para minimizar el diff.
- `scripts/migrate-openbao-to-1password.sh` reemplaza a `migrate-openbao-secrets.sh` y `load-secrets-to-openbao.sh`: camina el árbol KV del OpenBao in-cluster (que sigue vivo, ver ADR-016) y crea/actualiza un item por path en el vault "Homelab" vía `op item create`/`op item edit`. Manual, nunca en CI — mismo criterio que ADR-015.
- Se destruye la LXC 125 (`openbao`, 192.168.80.35): se elimina el recurso de `terraform/infra/lxc.tf`, `ansible/openbao.yaml`, `ansible/templates/openbao.container.j2`, el grupo `secrets_lxc` del inventario, y las referencias a `OPENBAO_STATIC_SEAL_KEY` en Terraform/CI/preflight (quedaba del mecanismo de sellado estático del OpenBao in-cluster viejo, ya retirado).
- Se limpiaron 3 `ExternalSecret` huérfanos (`mongodb-app-secret`, `postgresql-app-secret`, `redis-secret`, namespace `infra`) que quedaron del refactor de ADR-016 sin manifiesto en git — el `ClusterSecretStore` roto (ver más abajo) nunca los podó.

### Consecuencias

- Desaparece toda la ceremonia de Vault-family: no hay init, no hay seal/unseal, no hay backend de auth de Kubernetes que configurar, no hay policies ni roles.
- Se depende de la disponibilidad de la API de 1Password (SaaS) para que ExternalSecrets sincronice — antes esa dependencia era 100% self-hosted (la LXC). Con `deletionPolicy: Retain` en todos los ExternalSecrets, una caída de 1Password no borra los Secrets de Kubernetes ya sincronizados, solo congela las actualizaciones.
- El Service Account de 1Password tiene rate limits más estrictos que un Connect server (que cachea localmente) — no debería importar al refresh interval de 1h/1m que ya usan estos ExternalSecrets, pero es un límite a tener presente si se agregan muchos más secrets.
- Se pierde el control total self-hosted sobre el backend de secretos a cambio de simplicidad operativa — trade-off consciente para un homelab de un solo operador.
