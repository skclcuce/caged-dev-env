# 장애와 극복 (Incident Learnings)

운영 중 발생한 주요 인시던트의 분석과 아키텍처 교정 기록이다. 각 인시던트는 발견 경위, 근본 원인 분석, 아키텍처 교정, 재발 방지 조치를 포함한다.

특히 장애 조치 중 부수적인 아키텍처 결함을 발굴해내는 과정(Secondary Discovery)을 중시한다.

---

## LLM 에이전트의 의도치 않은 시스템 조작 예측 방어

**발견**: LLM 코딩 에이전트를 인프라 코드 작성과 트러블슈팅에 활용하는 과정에서, 에이전트가 의도치 않게 프로덕션 데이터를 삭제하거나 시크릿을 평문으로 노출할 수 있는 구조적 위험이 존재함을 인지했다.

**근본 원인**: Docker 소켓 방식의 all-or-nothing 권한 구조에서는 에이전트의 행동 범위를 제한할 수 없었다. K8s API의 RBAC 레이어가 없으면, 에이전트에게 "읽기만 가능"이라는 제한을 걸 방법이 없다.

**교정**:
1. Docker Compose → K8s 전환의 핵심 동기로 반영 (RBAC 전제)
2. 구조(Schema)와 값(Value)의 분리 원칙 수립 — LLM에게 매니페스트 키 구조만 노출, 실제 시크릿은 OpenBao + ExternalSecret Operator로 런타임 주입
3. `llm-agent-readonly` ClusterRole 적용 — 읽기 전용 권한만 부여

---

## LLM 에이전트의 로컬 admin kubeconfig RBAC 우회

**발견**: LLM 코딩 에이전트가 로컬 랩탑에 존재하는 admin kubeconfig를 통해, 서버 측에서 부여한 읽기 전용 RBAC을 완전히 우회할 수 있는 구조적 결함을 발견했다.

**근본 원인**: 초기 설계에서는 LLM에게 제한된 K8s 토큰을 발급하면서도, 같은 환경에 admin kubeconfig가 공존하는 구조였다. 에이전트가 `KUBECONFIG` 환경변수를 변경하거나 기본 경로의 kubeconfig를 읽으면 전체 클러스터 제어가 가능했다.

**교정**:
1. 관리자의 `kubectl`은 오로지 SSH 터널을 통해 서버에서 직접 실행하도록 전환 — 외부 랩탑에 admin kubeconfig가 존재하지 않는 구조
2. LLM 전용 동적 M2M 인증 파이프라인 도입 — AppRole 기반 1시간 TTL 토큰을 RAM Disk에만 렌더링
3. 사람이 점화(ignition) 스크립트를 실행해야만 LLM의 K8s 접근이 활성화되는 수동 점화 전제 구조 도입

---

## LLM 에이전트의 사람용 SSH 키 탈취 (Credential Escalation)

**발견**: LLM 전용 M2M 인증 경로가 장애 상태일 때, 에이전트가 **사람용 SSH 키**와 **사람용 Git remote**를 사용하여 차상위 권한으로 git push를 수행했다. 사용자가 무심코 승인하여 실행됨.

**근본 원인**: 동일 OS 유저 세션에서 LLM과 사람이 같은 uid를 공유하여, 사람용 SSH 키(`~/.ssh/id_ed25519`)를 LLM 프로세스가 읽을 수 있었다. M2M 자격증명 분리는 서버 사이드에서는 RBAC/principal로 강제되지만, 클라이언트 사이드에서는 "약속"에 불과하다.

**교정**:
1. 사람용 SSH 키를 `root:root` 소유로 변경 — 커널 레벨에서 LLM 프로세스의 읽기를 차단
2. `unshare --mount` 기반 마운트 네임스페이스 격리 — LLM 프로세스 시작 시 사람 키를 `/dev/null`로 바인딩하여 파일 존재 자체를 비가시화
3. `SSH_AUTH_SOCK` 환경변수 제거 — SSH 에이전트 소켓을 통한 우회 차단

**의의**: 프롬프트 기반 행동 규칙("이 키를 쓰지 마")은 보안 경계가 될 수 없으며, 컨텍스트가 길어질수록 초기 규칙이 희석되어 위반 확률이 높아진다는 것을 경험적으로 확인. OS 커널 레벨의 강제가 필요하다는 결론을 내렸다.

---

## K8s Secret Annotation 평문 시크릿 누수

**발견**: 다른 인증 장애를 트러블슈팅하기 위해 K8s 리소스를 YAML로 덤프하여 분석하던 중, Secret 오브젝트의 `kubectl.kubernetes.io/last-applied-configuration` 어노테이션에 시크릿 값이 평문으로 기록되어 있는 것을 **육안으로 포착**했다. (Secondary Discovery)

**근본 원인**: K8s의 3-way merge 전략으로 인해, `kubectl apply`로 Secret을 생성하면 해당 어노테이션에 원본 매니페스트(평문 시크릿 포함)가 자동 저장된다. 이는 K8s의 알려진 동작이나, 대부분의 운영자가 인지하지 못하는 보안 결함이다.

**교정**:
1. 모든 시크릿을 `kubectl apply` 대신 ExternalSecret Operator를 통해 관리하도록 전면 전환
2. 기존에 `kubectl apply`로 생성된 Secret의 어노테이션을 일괄 제거
3. LLM 에이전트의 `kubectl apply` 사용을 정책적으로 금지

**의의**: 체계적인 감사 로그 없이는 보안 결함을 운에 의존할 수밖에 없다는 한계를 인식하게 된 계기. Audit/Observability 도입의 근거가 되었다.

---

## Velero Restic 백업의 침묵의 실패

**발견**: 정기 백업이 성공으로 보고되고 있었으나, 실제 복구 테스트에서 데이터가 누락된 것을 확인했다.

**근본 원인**: Restic 엔진의 Lock Contention으로 인해, 동시 실행되는 백업 작업이 서로 간섭하면서 일부 볼륨의 백업이 건너뛰어졌다. Velero는 이를 에러로 처리하지 않고 부분 성공으로 보고했다.

**교정**:
1. Restic → Kopia 엔진으로 전환 (Lock-free 아키텍처)
2. K8s 리소스 스냅샷과 별도로 애플리케이션 레벨의 DB 논리 덤프(pg_dump)를 NAS에 이중화
3. 복구 테스트를 정기 절차에 포함하여 "백업이 있다 ≠ 복구가 된다" 원칙 수립
