#!/bin/bash
# ============================================================================
# bootstrap.sh — 단일 스크립트 기반 Dynamic Auth 환경 구축 (Showcase Version)
# ============================================================================
#
# 목적: 깡통 PC 원격 접속 후 단일 명령어로 개발 환경을 자동 셋업한다.
#       모든 시크릿은 Vault에서 동적으로 주입받으며, 디스크에 장기 보관하지 않는다.
#
# 특징:
#   - SSH CA: 사람과 기계(LLM)의 인증 경로 완전 분리
#   - Dynamic Auth & TTL: 정적 토큰 없음. 모든 접근은 TTL(1h) 기반 단기 인증
#   - 수동 활성화: 사람의 OIDC 로그인 후 점화(ignition)해야만 M2M 활성화
#
# ============================================================================
set -euo pipefail

# ... (로깅 함수 생략: info, ok, warn, fail) ...
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
fail()  { echo -e "${RED}[FAIL]${NC}  $*" >&2; exit 1; }

echo -e "${BOLD}🚀 caged-dev-env Bootstrap 시작${NC}"

# ============================================================================
# Step 1: 환경 변수 및 의존성 확인
# ============================================================================
BAO_ADDR=${BAO_ADDR:-"https://<YOUR_VAULT_DOMAIN>"}
GIT_HOST=${GIT_HOST:-"https://<YOUR_GIT_DOMAIN>"}
INFRA_DIR="$HOME/repos/infra"

info "필수 도구 확인 (bao, kubectl, jq)..."
# OS 판단 후 자동 설치 로직 (apt/pacman/dnf) 포함 (생략)
ok "의존성 설치 완료"

# ============================================================================
# Step 2: 인프라 코드 Clone (임시 토큰 사용)
# ============================================================================
if [[ ! -d "$INFRA_DIR" ]]; then
    info "GitHub/GitLab에서 인프라 리포지토리 Clone..."
    # 토큰은 변수에만 존재하며, clone 직후 메모리에서 파기됨
    read -s -p "HTTPS Clone 토큰 (1회성): " GIT_TOKEN; echo ""
    git clone "https://oauth2:${GIT_TOKEN}@<YOUR_GIT_DOMAIN>/user/infra.git" "$INFRA_DIR" || fail "Clone 실패"
    unset GIT_TOKEN
    ok "Clone 완료"
fi

# ============================================================================
# Step 3: 동적 M2M 인증 파이프라인 구성 (Vault Agent)
# ============================================================================
info "M2M 인증을 위한 Vault Agent 구성 중..."
ANTI_DIR="$HOME/.config/llm-agent"
mkdir -p "$ANTI_DIR"

# 사용자가 Vault AppRole RoleID 입력
if [[ ! -f "$ANTI_DIR/vault-role-id" ]]; then
    read -p "Vault AppRole RoleID: " ROLE_ID
    echo "$ROLE_ID" > "$ANTI_DIR/vault-role-id"
    chmod 600 "$ANTI_DIR/vault-role-id"
fi

# systemd 데몬 등록 (실행은 점화 스크립트에서 수행)
ln -sf "${INFRA_DIR}/scripts/vault-agent.service" "$HOME/.config/systemd/user/vault-agent.service"
systemctl --user daemon-reload
ok "Vault Agent 준비 완료"

# ============================================================================
# Step 4: 사람/기계 인증 경로 분리 (SSH CA 래퍼)
# ============================================================================
info "SSH CA 기반 접근 래퍼 배치 중..."
# 사람용: OIDC 인증 후 SSH 접속 (admin 권한 가능)
ln -sf "${INFRA_DIR}/scripts/ssh-admin" "$HOME/.local/bin/ssh-admin"
# 기계용: Vault Agent 토큰 기반 자동 접속 (port-forwarding 차단)
ln -sf "${INFRA_DIR}/scripts/ssh-llm" "$HOME/.local/bin/ssh-llm"
# LLM 기계 전용 점화 스크립트
ln -sf "${INFRA_DIR}/scripts/ignite-llm.sh" "$HOME/.local/bin/ignite-llm"
ok "SSH 인증 래퍼 구성 완료"

# ============================================================================
# Step 5: M2M 파이프라인 점화 (수동 인가 기반)
# ============================================================================
info "🔥 점화 스크립트(ignite-llm) 실행 — OIDC 인증 연결..."
# ignite-llm.sh 내에서 브라우저 OIDC 로그인 유도 → 1h SecretID 발급 → Vault Agent 기동
ignite-llm

# ============================================================================
# Step 6: E2E 격리 검증
# ============================================================================
info "인프라 격리 상태 자동 검증(E2E) 중..."
KUBECONFIG="/dev/shm/llm-kubeconfig"

# 1. API 상호작용
$KUBECONFIG kubectl get pods &>/dev/null || fail "kubectl 접근 차단됨"
ok "kubectl 읽기 권한 확인"

# 2. RBAC 격리
if $KUBECONFIG kubectl get secrets &>/dev/null; then
    fail "보안 위반: LLM이 Secret을 읽을 수 있습니다!"
else
    ok "Secrets 읽기 권한 차단 확인 (구조와 값 분리 적용됨)"
fi

echo -e "\n${GREEN}🎉 모든 환경 구축이 완료되었습니다! (소요 시간: ~1분)${NC}"
echo "철수 시에는 teardown.sh를 실행하여 로컬에 남는 파일 없이 깔끔하게 클리닝하십시오."
