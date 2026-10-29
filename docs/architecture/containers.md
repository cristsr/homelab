# Containers (C4 Level 2)

The apps, platform components and data services of the homelab and the integrations between them. Bootstrapped and last updated 2026-10-28 by spec-0015, which added the `autosubtitle` node and its edges. The external systems are the ones of [context.md](context.md).

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
      autosubtitle("autosubtitle<br/>(scaled to zero)")
      autosubtitle_daily("autosubtitle-daily<br/>(CronJob, 06:00)")
    end

    subgraph tools["Other workloads"]
      sonarqube("SonarQube")
      kaneo("Kaneo")
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
  autosubtitle_daily -- "POST /run" --> elasti
  elasti -- "wakes and forwards" --> autosubtitle
  autosubtitle -- "REST" --> bazarr
  autosubtitle -- "TCP, ledger" --> redis

  sonarqube --> postgres
  kaneo --> postgres
  hindsight --> postgres
  flow --> postgres
  flow --> mongodb
  hindsight --> qdrant
```
