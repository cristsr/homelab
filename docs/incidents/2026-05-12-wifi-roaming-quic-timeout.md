# Post-Mortem: Abrupt Cluster Disconnection (WiFi Roaming + QUIC Timeout)

## Metadata
| Field | Value |
|-------|-------|
| **Incident date** | 2026-05-12 |
| **Start time** | 01:08:36 UTC |
| **Recovery time** | 01:45:02 UTC |
| **Total duration** | ~37 minutes |
| **Affected components** | Cloudflared (4 tunnels), external access to applications |
| **Severity** | High (total unavailability of exposed services) |
| **Report author** | cristsr |
| **Status** | Resolved |

---

## Executive Summary (TL;DR)

The cluster stopped being accessible from the Internet due to a 5-second **WiFi roam** that caused Cilium to recompile its BPF programs. After this, Cloudflared was unable to re-establish its QUIC tunnels for ~37 minutes until its fallback to HTTP2 kicked in. The cluster's internal network never failed.

---

## Impact

- **Users affected:** 100% (all services exposed via Cloudflare Tunnel).
- **Services impacted:** All applications behind the tunnel.
- **Data lost/corrupted:** None.
- **SLA/SLO:** N/A (homelab).

---

## Timeline (Time zone: UTC)

| Time | Event |
|------|-------|
| 01:08:36 | `wpa_supplicant` reports disconnection from AP `f8:e5:a4:5e:d2:d5` (reason=8, client roaming) |
| 01:08:36 | `systemd-networkd` loses carrier and DHCP lease on `wlx9c532220ba75` |
| 01:08:41 | WiFi reassociates to AP `f8:e5:a4:5d:22:c5` (same SSID, different BSSID) |
| 01:08:41 | DHCP reacquires IP `192.168.80.20/24` |
| 01:08:46 | Cilium detects the device change, recompiles and reattaches BPF to all interfaces |
| 01:08:47 - 01:11:07 | Cloudflared loses all 4 QUIC tunnel connections |
| 01:09:14 - 01:45:02 | Cloudflared attempts to reconnect via QUIC but consistently fails (handshake timeout) |
| 01:34:03 - 01:45:02 | Cloudflared progressively falls back to HTTP2 (TCP). All tunnels recovered. |

---

## Root Cause

### Immediate Cause (Trigger)
**Client WiFi roaming** (5 seconds) between two nodes of a mesh network (`NULL/CMD-5G`).

### Contributing Cause 1: Cilium's Reaction
Cilium detected the IP change on `wlx9c532220ba75` and executed a **full BPF datapath reload** (recompilation + tcx reattach for 59 endpoints and all interfaces). This is expected behavior with `routingMode: native` and `autoDirectNodeRoutes: true`.

### Root Cause: QUIC Fragility After a Network Change
Cloudflared lost its QUIC (UDP) tunnels. When the source IP changed, the NAT/conntrack states became stale, making the QUIC handshake impossible. Cloudflared retried for ~37 minutes before its internal logic fell back to HTTP2.

> **Note:** Certificates (cert-manager, SPIRE) were not involved.

---

## Detection and Response

| Aspect | Detail |
|---------|---------|
| **How was it detected?** | The user was unable to access the applications. |
| **Who responded?** | User (homelab). |
| **Detection time** | Immediate (access failed). |
| **Response time** | N/A (waited for automatic recovery). |
| **Were alerts escalated?** | No (no alerting system). |

---

## Recovery

- **Method:** Automatic recovery via cloudflared's fallback to HTTP2.
- **Manual actions:** None.
- **Recovery time:** ~37 minutes (excessive for a 5-second roam).

---

## Lessons Learned

### What Went Well
- Cilium recovered the datapath quickly (~10 seconds).
- The internal cluster (k8s, pods, services) remained stable.
- Cloudflared eventually recovered without human intervention.

### What Went Wrong
- QUIC is extremely fragile to IP/NAT changes, especially on WiFi connections.
- 37 minutes of unavailability from a 5-second roam is unacceptable.
- Lack of alerting to quickly detect tunnel outages.

---

## Corrective Actions

| # | Action | Priority | Owner | Status |
|---|--------|-----------|-------------|--------|
| 1 | Force `--protocol http2` in cloudflared to remove the QUIC dependency | High | cristsr | Pending |
| 2 | Evaluate a wired Ethernet connection to eliminate WiFi fragility | Medium | cristsr | Pending |
| 3 | Implement a healthcheck/alert if the tunnel is down for >60s | Low | cristsr | Pending |
| 4 | Document this post-mortem in the repository | High | cristsr | Completed |

---

## Supporting Technical Data

### WiFi
- **Interface:** `wlx9c532220ba75` (USB, MAC `9c:53:22:20:ba:75`)
- **Signal at time of analysis:** -47 dBm (excellent)
- **Power save:** Off
- **Original AP:** `f8:e5:a4:5e:d2:d5`
- **Destination AP (roam):** `f8:e5:a4:5d:22:c5`
- **SSID:** `NULL/CMD-5G` (mesh network)
- **Regulatory domain:** CO (Colombia), DFS-FCC

### Cilium
- **Version:** 1.19.3
- **Routing mode:** native
- **autoDirectNodeRoutes:** true
- **Datapath mode:** veth
- **enable-tcx:** true

### Cloudflared
- **Version:** 2026.3.0
- **Protocol during incident:** auto (QUIC by default)
- **Tunnels:** 4 connections
- **Affected edge POPs:** Miami (mia04, mia09), Bogotá (bog04)
- **Edge IPs:** 198.41.200.43, 198.41.192.107, 198.41.200.13, 198.41.192.27, etc.
- **Recovery protocol:** HTTP2 (TCP)

---

## References
- [Cloudflare Tunnel Run Parameters - protocol](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/configure-tunnels/tunnel-run-parameters/#protocol)
- [The Road to QUIC - Cloudflare Blog](https://blog.cloudflare.com/the-road-to-quic/)
- [wpa_supplicant CTRL-EVENT-DISCONNECTED reason codes](https://w1.fi/wpa_supplicant/devel/ctrl_iface_page.html)
