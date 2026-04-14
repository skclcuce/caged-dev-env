#!/bin/bash
# ============================================================================
# ignite-llm.sh — LLM M2M 인증 파이프라인 점화 스크립트
# ============================================================================
#
# 목적: 사람(관리자)이 OIDC 인증 후, LLM 에이전트를 위한 1h 시한부 SecretID를
#       발급하고 Vault Agent를 (재)기동하여 동적 K8s 인증을 활성화한다.
#
# 워크플로우:
#   1. OIDC 인증 상태 확인 (또는 자동 로그인)
#   2. 1h SecretID 발급
#   3. SecretID 파일 덮어쓰기 (chmod 600)
#   4. Vault Agent systemd 서비스 (재)기동
#   5. /dev/shm/llm-kubeconfig 생성 확인
#   6. kubectl 읽기 권한 검증
#
# 사용법:
#   ignite-llm              # 신규 점화 또는 재점화
#   ignite-llm --status     # 현재 상태 확인만
#
# 보안:
#   - SecretID는 1h TTL (무한 SecretID 폐지)
#   - 발급 즉시 파일에 쓰여지고 화면에 표시하지 않음
#   - bao login stdout 억제: admin 토큰이 LLM 컨텍스트에 유출되는 것을 방지
#   - 이전 SecretID는 덮어쓰기로 자동 교체
#
# ============================================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
fail()  { echo -e "${RED}[FAIL]${NC}  $*" >&2; exit 1; }

ANTI_DIR="$HOME/.config/llm-agent"
SERVICE_NAME="vault-agent"

# --- 상태 확인 모드 ---
if [[ "${1:-}" == "--status" ]]; then
    echo ""
    echo -e "${BOLD}=== LLM M2M 인증 상태 ===${NC}"
    echo ""

    if systemctl --user is-active "$SERVICE_NAME" &>/dev/null; then
        ok "Vault Agent: 실행 중"
        UPTIME=$(systemctl --user show "$SERVICE_NAME" --property=ActiveEnterTimestamp --value)
        echo "  시작 시각: $UPTIME"
    else
        warn "Vault Agent: 중지됨"
    fi

    if [[ -f "/dev/shm/llm-kubeconfig" ]]; then
        AGE=$(( $(date +%s) - $(stat -c %Y /dev/shm/llm-kubeconfig) ))
        MINS=$((AGE / 60))
        ok "kubeconfig: 존재 (${MINS}분 전 갱신)"
        [[ $MINS -gt 55 ]] && warn "⚠️  TTL 만료 임박 — 재점화 필요: ignite-llm"
    else
        warn "kubeconfig: 없음"
    fi

    if [[ -f "$ANTI_DIR/vault-secret-id" ]]; then
        AGE=$(( $(date +%s) - $(stat -c %Y "$ANTI_DIR/vault-secret-id") ))
        MINS=$((AGE / 60))
        if [[ $MINS -gt 55 ]]; then
            warn "SecretID: ${MINS}분 경과 (만료 가능성 높음)"
        else
            ok "SecretID: ${MINS}분 전 발급 ($((60 - MINS))분 남음)"
        fi
    else
        warn "SecretID: 없음"
    fi
    exit 0
fi

# ============================================================================
# 점화 (Ignition)
# ============================================================================
echo -e "\n${BOLD}🔥 LLM M2M 인증 파이프라인 점화${NC}"
echo "============================================================================"

# --- 사전 점검 ---
command -v bao >/dev/null 2>&1 || fail "bao CLI가 설치되어 있지 않습니다."
[[ -n "${BAO_ADDR:-}" ]] || export BAO_ADDR="https://<YOUR_VAULT_DOMAIN>"
[[ -f "$ANTI_DIR/vault-role-id" ]] || fail "RoleID 없음: $ANTI_DIR/vault-role-id"

# Step 1: OpenBao 인증 확인
info "OpenBao 인증 상태 확인..."
if bao token lookup &>/dev/null; then
    ok "기존 OpenBao 토큰 유효"
else
    info "🌐 브라우저가 열립니다. OIDC 로그인하세요."
    # ⚠️ bao login 출력을 억제: admin 토큰(8h)이 stdout에 평문 노출됨
    # LLM이 이 스크립트를 대행 실행할 경우 토큰이 컨텍스트에 유출되는 것을 방지
    bao login -method=oidc > /dev/null || fail "OIDC 인증 실패"
    ok "OIDC 인증 완료"
fi

# Step 2: 1h SecretID 발급
info "1h 시한부 SecretID 발급..."
SECRET_ID=$(bao write -field=secret_id -f auth/approle/role/llm-agent/secret-id) \
    || fail "SecretID 발급 실패"
echo "$SECRET_ID" > "$ANTI_DIR/vault-secret-id"
chmod 600 "$ANTI_DIR/vault-secret-id"
ok "SecretID 발급 완료 (TTL: 1h)"

# Step 3: Vault Agent (재)기동
info "Vault Agent 서비스 (재)기동..."
if systemctl --user is-active "$SERVICE_NAME" &>/dev/null; then
    info "기존 Agent 감지 — 재시작 (Top-up 모드)"
    systemctl --user restart "$SERVICE_NAME"
else
    systemctl --user start "$SERVICE_NAME"
fi
ok "Vault Agent 기동 완료"

# Step 4: kubeconfig 생성 대기
info "kubeconfig 렌더링 대기 (최대 15초)..."
for i in $(seq 1 15); do
    if [[ -f "/dev/shm/llm-kubeconfig" ]]; then
        AGE=$(( $(date +%s) - $(stat -c %Y /dev/shm/llm-kubeconfig) ))
        if [[ $AGE -lt 30 ]]; then
            ok "kubeconfig 렌더링 성공!"
            break
        fi
    fi
    sleep 1
done

[[ -f "/dev/shm/llm-kubeconfig" ]] || { warn "kubeconfig 미생성 — journalctl --user -u vault-agent -n 20"; exit 1; }

# Step 5: kubectl 읽기 권한 검증
if command -v kubectl &>/dev/null; then
    info "kubectl 권한 검증..."
    if KUBECONFIG=/dev/shm/llm-kubeconfig kubectl get namespaces &>/dev/null; then
        ok "✅ kubectl 읽기 테스트 성공 (llm-agent-readonly)"
    else
        warn "kubectl 테스트 실패 — SSH 터널(localhost:6443)이 열려있는지 확인"
    fi
fi

# 완료
echo -e "\n${GREEN}🔥 점화 완료! LLM M2M 인증 파이프라인 활성화됨${NC}"
echo "  KUBECONFIG=/dev/shm/llm-kubeconfig"
echo "  유효 시간: ~1시간 ($(date -d '+1 hour' '+%H:%M') 경 만료)"
echo "  상태 확인: ignite-llm --status"
echo "  재점화:    ignite-llm"
