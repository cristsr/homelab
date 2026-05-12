# Post-Mortem: Desconexión abrupta del cluster (WiFi roaming + QUIC timeout)

## Metadata
| Campo | Valor |
|-------|-------|
| **Fecha del incidente** | 2026-05-12 |
| **Hora de inicio** | 01:08:36 UTC |
| **Hora de recuperación** | 01:45:02 UTC |
| **Duración total** | ~37 minutos |
| **Componentes afectados** | Cloudflared (4 túneles), acceso externo a aplicaciones |
| **Severidad** | Alta (indisponibilidad total de servicios expuestos) |
| **Autor del reporte** | cristsr |
| **Estado** | Resuelto |

---

## Resumen Ejecutivo (TL;DR)

El cluster dejó de ser accesible desde Internet debido a un **roaming WiFi** de 5 segundos que provocó que Cilium recompilara sus programas BPF. Tras esto, Cloudflared no pudo reestablecer sus túneles QUIC durante ~37 minutos hasta que su fallback a HTTP2 se activó. La red interna del cluster nunca falló.

---

## Impacto

- **Usuarios afectados:** 100% (todos los servicios expuestos vía Cloudflare Tunnel).
- **Servicios impactados:** Todas las aplicaciones detrás del túnel.
- **Datos perdidos/corruptos:** Ninguno.
- **SLA/SLO:** N/A (homelab).

---

## Timeline (Zona horaria: UTC)

| Hora | Evento |
|------|--------|
| 01:08:36 | `wpa_supplicant` reporta desconexión del AP `f8:e5:a4:5e:d2:d5` (reason=8, roaming del cliente) |
| 01:08:36 | `systemd-networkd` pierde carrier y lease DHCP en `wlx9c532220ba75` |
| 01:08:41 | WiFi se reasocia al AP `f8:e5:a4:5d:22:c5` (mismo SSID, BSSID diferente) |
| 01:08:41 | DHCP readquiere IP `192.168.80.20/24` |
| 01:08:46 | Cilium detecta cambio de dispositivo, recompila y reattacha BPF a todas las interfaces |
| 01:08:47 - 01:11:07 | Cloudflared pierde las 4 conexiones de túnel QUIC |
| 01:09:14 - 01:45:02 | Cloudflared intenta reconectar vía QUIC pero falla consistentemente (timeout en handshake) |
| 01:34:03 - 01:45:02 | Cloudflared hace fallback progresivo a HTTP2 (TCP). Todos los túneles recuperados. |

---

## Root Cause

### Causa inmediata (Trigger)
**Roaming WiFi del cliente** (5 segundos) entre dos nodos de una red mesh (`NULL/CMD-5G`).

### Causa contribuyente 1: Reacción de Cilium
Cilium detectó el cambio de IP en `wlx9c532220ba75` y ejecutó un **reload completo del datapath BPF** (recompilación + tcx reattach para 59 endpoints y todas las interfaces). Este es comportamiento esperado en `routingMode: native` con `autoDirectNodeRoutes: true`.

### Causa raíz: Fragilidad de QUIC tras cambio de red
Cloudflared perdió sus túneles QUIC (UDP). Al cambiar la IP de origen, los estados de NAT/conntrack quedaron obsoletos, haciendo imposible el handshake QUIC. Cloudflared reintentó durante ~37 minutos antes de que su lógica interna hiciera fallback a HTTP2.

> **Nota:** Los certificados (cert-manager, SPIRE) no estuvieron involucrados.

---

## Detección y Respuesta

| Aspecto | Detalle |
|---------|---------|
| **¿Cómo se detectó?** | El usuario no pudo acceder a las aplicaciones. |
| **¿Quién respondió?** | Usuario (homelab). |
| **Tiempo de detección** | Inmediato (acceso falló). |
| **Tiempo de respuesta** | N/A (espera a recuperación automática). |
| **¿Se escalaron alertas?** | No (sin sistema de alertas). |

---

## Recuperación

- **Método:** Recuperación automática por fallback de cloudflared a HTTP2.
- **Acciones manuales:** Ninguna.
- **Tiempo de recuperación:** ~37 minutos (excesivo para un roam de 5 segundos).

---

## Lecciones Aprendidas

### Lo que funcionó bien
- Cilium recuperó el datapath rápidamente (~10 segundos).
- El cluster interno (k8s, pods, servicios) permaneció estable.
- Cloudflared eventualmente se recuperó sin intervención humana.

### Lo que funcionó mal
- QUIC es extremadamente frágil ante cambios de IP/NAT, especialmente en conexiones WiFi.
- 37 minutos de indisponibilidad por un roam de 5 segundos es inaceptable.
- Falta de alertas para detectar caídas del túnel rápidamente.

---

## Acciones Correctivas

| # | Acción | Prioridad | Responsable | Estado |
|---|--------|-----------|-------------|--------|
| 1 | Forzar `--protocol http2` en cloudflared para eliminar dependencia de QUIC | Alta | cristsr | Pendiente |
| 2 | Evaluar conexión Ethernet cableada para eliminar fragilidad del WiFi | Media | cristsr | Pendiente |
| 3 | Implementar healthcheck/alerta si el túnel está caído >60s | Baja | cristsr | Pendiente |
| 4 | Documentar este post-mortem en el repositorio | Alta | cristsr | Completado |

---

## Datos Técnicos de Soporte

### WiFi
- **Interfaz:** `wlx9c532220ba75` (USB, MAC `9c:53:22:20:ba:75`)
- **Señal al momento del análisis:** -47 dBm (excelente)
- **Power save:** Off
- **AP original:** `f8:e5:a4:5e:d2:d5`
- **AP destino (roam):** `f8:e5:a4:5d:22:c5`
- **SSID:** `NULL/CMD-5G` (red mesh)
- **Regulatory domain:** CO (Colombia), DFS-FCC

### Cilium
- **Versión:** 1.19.3
- **Routing mode:** native
- **autoDirectNodeRoutes:** true
- **Datapath mode:** veth
- **enable-tcx:** true

### Cloudflared
- **Versión:** 2026.3.0
- **Protocolo durante incidente:** auto (QUIC por defecto)
- **Túneles:** 4 conexiones
- **Edge POPs afectados:** Miami (mia04, mia09), Bogotá (bog04)
- **IPs de edge:** 198.41.200.43, 198.41.192.107, 198.41.200.13, 198.41.192.27, etc.
- **Protocolo de recuperación:** HTTP2 (TCP)

---

## Referencias
- [Cloudflare Tunnel Run Parameters - protocol](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/configure-tunnels/tunnel-run-parameters/#protocol)
- [The Road to QUIC - Cloudflare Blog](https://blog.cloudflare.com/the-road-to-quic/)
- [wpa_supplicant CTRL-EVENT-DISCONNECTED reason codes](https://w1.fi/wpa_supplicant/devel/ctrl_iface_page.html)
