# 인프라 구성도 (Infrastructure Overview)

## 전체 구성

```mermaid
flowchart TB
    subgraph CLOUD["☁️ Oracle Cloud Always-Free (4 OCPU, 24GB RAM)"]
        subgraph K3S["K3s 클러스터 (단일 노드)"]
            subgraph INFRA["🔧 인프라 서비스"]
                AUTHELIA["Authelia (SSO/OIDC)"]
                OPENBAO["OpenBao (시크릿/SSH CA)"]
                ARGOCD["ArgoCD (GitOps)"]
                FORGEJO["Forgejo (Git 서버)"]
                CERTMGR["cert-manager (TLS 자동화)"]
                ESO["ExternalSecret Operator"]
            end

            subgraph APPS["📱 애플리케이션"]
                N8N["n8n (워크플로우 자동화)"]
                MATRIX["Matrix (메신저)"]
                VAULTWARDEN["Vaultwarden (비밀번호 관리)"]
                OTHERS["기타 서비스..."]
            end

            subgraph BACKUP_K["💾 백업"]
                VELERO["Velero + Kopia"]
            end

            TRAEFIK["Traefik Ingress (내장)"]
        end
    end

    subgraph NAS["🏠 Synology NAS"]
        MINIO["MinIO (S3)"]
        CERTSYNCER["cert-syncer (인증서 동기화)"]
        NAS_COMPOSE["Docker Compose (스토리지 직결 서비스)"]
    end

    subgraph EXTERNAL["🌐 외부"]
        CF["Cloudflare (DNS/DDNS)"]
        LE["Let's Encrypt (TLS 발급)"]
    end

    %% TLS 흐름
    CERTMGR -->|"DNS-01 챌린지"| CF
    CF --> LE
    LE -->|"인증서 발급"| CERTMGR
    CERTSYNCER -->|"Pull 동기화"| CERTMGR

    %% 시크릿 흐름
    OPENBAO --> ESO
    ESO -->|"런타임 주입"| APPS

    %% GitOps 흐름
    FORGEJO -->|"Webhook"| ARGOCD
    ARGOCD -->|"Sync"| K3S

    %% 백업 흐름
    VELERO -->|"S3 백업"| MINIO

    %% Ingress
    TRAEFIK -->|"라우팅"| INFRA
    TRAEFIK -->|"라우팅"| APPS

    style CLOUD fill:#0f3460,stroke:#16213e,color:#e2e2e2
    style K3S fill:#1a1a2e,stroke:#16213e,color:#e2e2e2
    style INFRA fill:#16213e,stroke:#0f3460,color:#e2e2e2
    style APPS fill:#1b4332,stroke:#2d6a4f,color:#e2e2e2
    style NAS fill:#533483,stroke:#16213e,color:#e2e2e2
    style EXTERNAL fill:#6a040f,stroke:#9d0208,color:#e2e2e2
```

## 네트워크 흐름

```
인터넷 → Cloudflare (DNS/프록시) → Oracle Cloud 퍼블릭 IP
    → Traefik Ingress (K3s 내장)
        → Authelia ForwardAuth 미들웨어 (SSO 게이트)
            → 각 서비스 (인증 통과 시)
```

## 하이브리드 구성 (K3s + NAS)

| 위치 | 역할 | 이유 |
|------|------|------|
| K3s (Cloud) | 모든 컨테이너 오케스트레이션, RBAC, GitOps | K8s API 기반 권한 분리 필요 |
| NAS (Docker Compose) | MinIO, 스토리지 직결 서비스 | S3 백업 수신, 디스크 I/O 성능 |
| NAS → K3s | cert-syncer가 인증서를 Pull | NAS 방화벽 인바운드 개방 불필요 |
