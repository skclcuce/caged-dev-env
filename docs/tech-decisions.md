# 기술 선정 근거 (Tech Decisions)

## 왜 Docker Compose가 아닌 K8s인가

대부분의 홈랩은 Docker Compose로 충분하다. 실제로 이 프로젝트도 초기에는 Synology NAS 위에서 Docker Compose로 운영했다. K8s로 전환한 이유는 세 가지다:

1. **RBAC 필수**: LLM 에이전트에게 인프라 제어권을 조건부로 개방하려면 역할 기반 접근 제어가 필요했다. Docker는 소켓 접근 시 권한 세분화가 불가능하여(all-or-nothing), "이 에이전트는 읽기만 가능" 같은 제한을 걸 수 없다. K8s는 API 앞에 RBAC 레이어가 존재하므로, 에이전트별로 네임스페이스·동사(get/list/delete) 단위의 권한 분리가 가능하다.
2. **선언적 시크릿 관리**: ExternalSecret Operator, ArgoCD 등 선언적 시크릿 관리와 GitOps 자동 배포를 활용하려면 K8s API가 전제된다.
3. **운영 비용 역전**: 서비스 수가 증가하면서 Compose 파일 간 의존성 관리, 롤백, 헬스체크 등 운영 부담이 오케스트레이터 도입 비용을 초과했다.

Synology NAS에서는 MinIO(S3 호환 백업 스토리지)와 DB 논리 덤프를 수신하는 스토리지 역할, 그리고 스토리지 직결 성능이 필요한 일부 서비스를 Docker Compose로 병행 운영하고 있다.

---

## 오케스트레이션: K3s

K8s 도입을 결정한 후 배포판으로 K3s, MicroK8s, K0s를 비교했다.

| 배포판 | 장점 | 단점 |
|--------|------|------|
| K3s | 단일 바이너리, ARM64 공식 지원, 내장 Traefik | sqlite 기반 etcd (단일 노드 환경에선 문제 없음) |
| MicroK8s | snap 기반 설치 편의 | ARM64 지원 불안정, 메모리 사용량 높음 |
| K0s | 경량, CNCF 인증 | 생태계/커뮤니티 규모 작음 |

K3s를 선택한 이유: 단일 바이너리 배포로 운영 복잡도가 낮고, ARM64를 공식 지원하며, Oracle Always-Free 인스턴스의 메모리 제약(24GB) 내에서 컨트롤 플레인과 워커를 동시에 구동할 수 있다. 내장 Traefik을 Ingress로 사용하여 별도 Ingress Controller 설치를 생략했다.

---

## 인증: Authelia (OIDC Provider)

퍼블릭 IP에 서비스를 노출하므로 SSO 게이트웨이가 필수였다.

| 솔루션 | 장점 | 단점 |
|--------|------|------|
| Keycloak | 기능 풍부, 엔터프라이즈급 | 메모리 ~500MB+, 무거움 |
| Authentik | 모던 UI, Python 기반 | 메모리 ~300MB |
| Authelia | ~50MB RAM, GitOps 친화 | 파일 기반 사용자 DB (대규모 부적합) |

Authelia가 메모리 사용량이 가장 낮고, 파일 기반 설정으로 GitOps 친화적이며, Traefik ForwardAuth 미들웨어와 네이티브 통합이 가능하여 선택했다. OIDC Provider 기능은 OpenBao 및 ArgoCD의 인증 백엔드로 활용한다.

한계: 자체 사용자 DB가 파일 기반(YAML)이므로 대규모 사용자 관리에는 부적합하다. 현재 단일 관리자 환경에서는 문제되지 않으나, 멀티 유저 확장 시 LDAP 연동 검토가 필요하다.

---

## 시크릿 관리: OpenBao (Vault fork)

인프라 내 시크릿(DB 비밀번호, API 키 등)의 중앙 집중 관리가 필요했다.

| 솔루션 | 장점 | 단점 |
|--------|------|------|
| HashiCorp Vault | 업계 표준, 풍부한 문서 | BSL 라이선스 전환 (오픈소스 아님) |
| Infisical | 모던 UI, 쉬운 도입 | Dynamic Secrets, SSH CA가 유료 전용 |
| OpenBao | Vault API 100% 호환, MPL-2.0 | 커뮤니티 초기 단계 |

OpenBao는 Vault의 MPL-2.0 포크로 기능이 완전 동일(API 100% 호환)하면서 라이선스 제약이나 기능 제한이 없어 최종 선택했다.

Vault 계열 도구는 Unseal 절차, Policy 설계, Secrets Engine 구성 등 운영 복잡도가 높다. 다만 LLM 에이전트에게 인프라 제어권을 조건부로 개방하는 과정에서, 사람과 기계의 자격증명을 별도로 관리해야 할 필요성을 체감했다. 정적 토큰을 파일에 저장하는 방식으로는 토큰 탈취 시 만료 없이 영구적으로 유효한 문제가 있었고, 이를 해결하기 위해 동적 시크릿 발급이 가능한 Vault 계열 도구의 도입이 불가피했다.

---

## 배포: ArgoCD (GitOps)

Git 레포지토리를 Single Source of Truth로 삼아 선언적 배포를 수행한다. 매니페스트의 변경은 Git 커밋을 통해서만 이루어지며, 클러스터 상태가 Git과 불일치(Drift)하면 자동으로 복구한다. 자체 호스팅 Git(Forgejo)과 웹훅으로 연동하여 커밋 즉시 동기화된다.

---

## 백업: Velero + Kopia + MinIO

K8s 리소스와 PV 스냅샷을 정기 백업한다. 백업 대상은 MinIO(자체 호스팅 S3)에 저장하며, 추가로 Synology NAS에 이중화한다.

초기에는 Restic 엔진을 사용했으나, Lock Contention으로 인해 백업이 성공으로 보고되면서도 실제로는 수행되지 않는 침묵의 실패를 경험했다 (인시던트 기록 참조). Kopia 엔진으로 전환하고, 애플리케이션 레벨의 DB 논리 덤프를 이중화하여 DR 신뢰성을 확보했다.

---

## TLS 인증서: cert-manager 중앙 관리

와일드카드 TLS 인증서의 발급과 갱신을 K3s의 cert-manager(Let's Encrypt, DNS-01 Cloudflare)에 일원화했다. NAS에서도 동일 도메인의 HTTPS 인증서가 필요하나, NAS 내부에서 별도로 인증서를 발급하는 대신, K3s에서 발급된 인증서를 Pull 방식으로 동기화하는 구조를 채택했다. 인증서 관리의 Single Source of Truth를 K3s로 통일했다.
