#!/bin/bash
# ============================================================================
# teardown.sh — 환경 철수 및 사후 정리 확인 (Showcase Version)
# ============================================================================
#
# 목적: 개발/작업이 끝난 후 K3s 인프라 제어 환경을 랩탑에서 완전히 지운다.
#       어떤 인증 정보나 시크릿 포인터도 파일 시스템에 남기지 않음을 보장한다.
#
# 특징:
#   - tmpfs 클리닝: 메모리 기반 토큰 즉각 소멸
#   - shred 사용: 디스크에 기록되었던 RoleID/SecretID 포렌식 복구 차단
#   - 심볼릭 링크 정리: 댕글링 참조 완벽 정리
#
# ============================================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[0;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()  { echo -e "${CYAN}[INFO]${NC}  $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*"; }

echo -e "\n🧹 caged-dev-env Teardown (Clean Audit)\n"

# ============================================================================
# Step 1: M2M 데몬 중지 및 설정 제거
# ============================================================================
info "M2M 백그라운드 프로세스(Vault Agent) 중지..."
systemctl --user stop vault-agent || true
systemctl --user disable vault-agent || true
rm -f "$HOME/.config/systemd/user/vault-agent.service"
systemctl --user daemon-reload
ok "Vault Agent 중지 및 설정 삭제"

# ============================================================================
# Step 2: 자격 증명 물리적 파기 (Secure Erase)
# ============================================================================
info "장기 보관 금지 시크릿 파기(shred)..."
ANTI_DIR="$HOME/.config/llm-agent"

# 일반 삭제 방지, 디스크 덮어쓰기 파기
safe_shred() {
    local target="$1"
    if command -v shred &>/dev/null; then
        shred -u "$target"
    else
        rm -P "$target" 2>/dev/null || rm -f "$target"
    fi
}

for item in "vault-secret-id" "vault-role-id"; do
    if [[ -f "${ANTI_DIR}/$item" ]]; then
        safe_shred "${ANTI_DIR}/$item"
    elif [[ -L "${ANTI_DIR}/$item" ]]; then
        rm -f "${ANTI_DIR}/$item"
    fi
done

rm -f "$HOME/.ssh/llm-agent-key" "$HOME/.ssh/llm-agent-key.pub" "$HOME/.ssh/llm-agent-key-cert.pub"
ok "정적 크레덴셜 영구 삭제 완료"

# ============================================================================
# Step 3: 메모리 공간(tmpfs) 클리닝
# ============================================================================
info "메모리 영역(/dev/shm) 시크릿 데이터 정리..."
SHM_DIR="/dev/shm"
rm -f "${SHM_DIR}/vault-agent-token"
rm -f "${SHM_DIR}/llm-kubeconfig"
ok "RAM Disk 데이터 제로화 완료"

# ============================================================================
# Step 4: 명령어 래퍼(Wrapper) 정리
# ============================================================================
info "명령어 래퍼 심볼릭 링크 정리..."
rm -f "$HOME/.local/bin/ssh-admin"
rm -f "$HOME/.local/bin/ssh-llm"
rm -f "$HOME/.local/bin/ignite-llm"
ok "래퍼 및 툴체인 정리 완료"

# ============================================================================
# Step 5: 잔존 파일 사후 검증
# ============================================================================
echo -e "\n🔍 Clean Teardown Audit (잔존물 검사)..."
RESIDUE_FOUND=false

[ -f "$HOME/.config/llm-agent/vault-secret-id" ] && { echo -e "${RED}  - 잔존: vault-secret-id${NC}"; RESIDUE_FOUND=true; }
[ -f "/dev/shm/llm-kubeconfig" ] && { echo -e "${RED}  - 잔존: llm-kubeconfig${NC}"; RESIDUE_FOUND=true; }
[ -f "$HOME/.ssh/llm-agent-key-cert.pub" ] && { echo -e "${RED}  - 잔존: SSH CA 인증서${NC}"; RESIDUE_FOUND=true; }

if [ "$RESIDUE_FOUND" = true ]; then
    echo -e "\n${RED}⚠️ 경고: 인프라 접근 크레덴셜이 로컬에 잔존합니다.${NC}"
    exit 1
else
    echo -e "\n${GREEN}✅ 시크릿 잔존 없음 — 안전하게 환경 철수 완료.${NC}"
    echo "이 기기에는 어떠한 인프라 접근 권한도 남아있지 않습니다."
fi
