# Containers (C4 Level 2)

The apps, platform components and data services of the homelab and the integrations between them. Bootstrapped and last updated 2026-10-28 by spec-0015, which added the `relay` node and its edges. The external systems are the ones of [context.md](context.md).

```mermaid
graph TB
  users["Household users"]
  github["GitHub<br/>(repository, Actions, ghcr.io)"]
  cloudflare["Cloudflare"]
  trackers["Torrent trackers and indexers"]
  subtitles["Subtitle providers"]
  deepseek["DeepSeek API"]

  subgraph cluster["Talos Kubernetes cluster (single node)"]
    subgraph platform["Platform"]
      argocd("ArgoCD")
      envoy("Envoy Gateway")
      cloudflared("cloudflared")
      elasti("KubeElasti resolver")
      sops("SOPS secrets operator")
      prometheus("Prometheus and Grafana")
    end

    subgraph media["Namespace media"]
      jellyfin("Jellyfin")
      sonarr("Sonarr")
      radarr("Radarr")
      prowlarr("Prowlarr")
      qbittorrent("qBittorrent with VPN sidecar")
      bazarr("Bazarr")
      lingarr("Lingarr")
      relay("relay<br/>(scaled to zero)")
      relay_daily("relay-subtitles-daily<br/>(CronJob, 06:00)")
    end

    subgraph tools["Other workloads"]
      sonarqube("SonarQube")
      kaneo("Kaneo")
      nexus("Nexus<br/>(recurring tasks)")
      hindsight("Hindsight")
      flow("Flow API")
    end
  end

  subgraph data["Data services (Proxmox LXCs, outside the cluster)"]
    postgres[("PostgreSQL")]
    mongodb[("MongoDB")]
    qdrant[("Qdrant")]
    redis[("Redis")]
    mysql[("MySQL")]
  end

  users -- "HTTPS" --> envoy
  cloudflare -- "tunnel" --> cloudflared
  cloudflared --> envoy
  envoy --> jellyfin
  envoy --> sonarqube
  envoy --> kaneo

  github -- "manifests" --> argocd
  github -- "images" --> media
  argocd -- "syncs" --> cluster
  sops -- "creates secrets" --> media
  prometheus -- "scrapes" --> envoy

  prowlarr -- "searches" --> trackers
  sonarr -- "indexers" --> prowlarr
  radarr -- "indexers" --> prowlarr
  sonarr -- "downloads through" --> qbittorrent
  radarr -- "downloads through" --> qbittorrent
  jellyfin -- "reads the library" --> sonarr
  bazarr -- "episode sync" --> sonarr
  bazarr -- "searches" --> subtitles
  bazarr -- "translation" --> lingarr
  lingarr -- "translates with" --> deepseek

  sonarr -- "webhook POST /run" --> elasti
  relay_daily -- "POST /subtitles/run" --> elasti
  elasti -- "wakes and forwards" --> relay
  relay -- "REST" --> bazarr
  relay -- "TCP, ledger" --> redis
  sonarr -- "webhook on grab" --> relay
  relay -- "REST, refresh series" --> sonarr

  sonarqube --> postgres
  kaneo --> postgres
  nexus -- "REST, creates tasks" --> kaneo
  nexus --> mongodb
  github -- "image" --> nexus
  hindsight --> postgres
  flow --> postgres
  flow --> mongodb
  hindsight --> qdrant
```
