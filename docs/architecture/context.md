# System Context (C4 Level 1)

The homelab as one system: who uses it and the external systems it depends on. Its apps, databases and platform components are in [containers.md](containers.md). Bootstrapped and last updated 2026-10-28 by spec-0015.

```mermaid
graph TB
  owner["Homelab owner<br/>(operates the cluster, reviews changes)"]
  household["Household users<br/>(watch media, use the private apps)"]

  subgraph system["homelab"]
    homelab["Single-node Kubernetes homelab<br/>(media stack, developer tools, data services,<br/>managed by GitOps)"]
  end

  github["GitHub<br/>(repository, Actions, ghcr.io images)"]
  cloudflare["Cloudflare<br/>(DNS and Internet tunnel)"]
  tailscale["Tailscale<br/>(private remote access)"]
  vpn["VPN provider<br/>(egress of the torrent client)"]
  trackers["Torrent trackers and indexers"]
  subtitles["Subtitle providers<br/>(OpenSubtitles, SubDL and others)"]
  deepseek["DeepSeek API<br/>(subtitle translation)"]

  owner -- "pushes changes, operates" --> homelab
  household -- "uses over the LAN, Tailscale or the tunnel" --> homelab
  homelab -- "syncs from, pulls images from" --> github
  homelab -- "publishes selected services through" --> cloudflare
  tailscale -- "reaches the private services of" --> homelab
  homelab -- "routes torrent traffic through" --> vpn
  homelab -- "searches releases on" --> trackers
  homelab -- "searches subtitles on" --> subtitles
  homelab -- "translates subtitles with" --> deepseek
```
