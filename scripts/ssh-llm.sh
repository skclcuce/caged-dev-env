#!/bin/bash
# ============================================================================
# ssh-llm — LLM 에이전트용 SSH 래퍼 (OpenBao SSH CA)
# ============================================================================
#
# 목적: Vault Agent 토큰으로 SSH CA 인증서를 발급받아 서버에 접속한다.
#       사람용 래퍼(ssh-admin)와 완전히 분리된 기계 전용 인증 경로.
#
# 인증 흐름:
#   Vault Agent 토큰 → OpenBao SSH CA sign → 1h 인증서 발급 → SSH 접속
#
# 보안 설계:
#   - llm-role: permit-port-forwarding 의도적 미포함
#     → SSH 터널을 통한 내부 서비스(kubelet, etcd) 피버팅 차단
#   - valid_principals: llm-agent,llm-bot
#     → Forgejo SSH CA 인증 + 서버 ForceCommand 양쪽 충족
#   - admin-role에만 포트 포워딩 허용
#   - 인증서 TTL: 1시간
#
# ============================================================================
set -euo pipefail

export BAO_ADDR="${BAO_ADDR:?BAO_ADDR 환경변수 필요}"

SSH_KEY="$HOME/.ssh/llm-agent-key"
SSH_CERT="$HOME/.ssh/llm-agent-key-cert.pub"
VAULT_AGENT_TOKEN="/dev/shm/vault-agent-token"

SERVER_HOST="<YOUR_SERVER_HOST>"
SERVER_PORT="<SSH_PORT>"
SERVER_USER="llm-agent"

# --- 사전 점검 ---
[[ -f "$SSH_KEY" ]] || { echo "ERROR: LLM 전용 SSH 키 없음: $SSH_KEY" >&2; exit 1; }
[[ -f "$VAULT_AGENT_TOKEN" ]] || { echo "ERROR: Vault Agent 토큰 없음 (ignite-llm 실행 필요)" >&2; exit 1; }

# --- 인증서 유효성 확인 (만료 5분 전 갱신) ---
cert_is_valid() {
    [[ -f "$SSH_CERT" ]] || return 1
    local valid_to
    valid_to=$(ssh-keygen -L -f "$SSH_CERT" 2>/dev/null | grep "Valid:" | sed 's/.*to //')
    [[ -z "$valid_to" ]] && return 1
    local exp_epoch now_epoch
    exp_epoch=$(date -d "$valid_to" +%s 2>/dev/null || echo 0)
    now_epoch=$(date +%s)
    (( exp_epoch > now_epoch + 300 ))
}

if ! cert_is_valid; then
    # Vault Agent 토큰으로 SSH CA 인증서 발급
    VAULT_TOKEN=$(cat "$VAULT_AGENT_TOKEN") bao write -field=signed_key ssh/sign/llm-role \
        valid_principals="llm-agent,llm-bot" \
        public_key=@"${SSH_KEY}.pub" > "$SSH_CERT" 2>/dev/null || {
        echo "ERROR: SSH CA 인증서 발급 실패" >&2
        exit 1
    }
fi

# --- SSH 접속 (ForceCommand에 의해 읽기 전용 명령만 허용) ---
exec ssh -i "$SSH_KEY" -o CertificateFile="$SSH_CERT" \
    -o StrictHostKeyChecking=no \
    -p "$SERVER_PORT" "${SERVER_USER}@${SERVER_HOST}" \
    "$@"
