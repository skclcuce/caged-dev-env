#!/bin/bash
# ============================================================================
# ssh-admin — 관리자용 SSH 접속 래퍼 (Showcase Version)
# ============================================================================
#
# 목적: OpenBao OIDC 인증 → SSH 인증서 발급 → 서버 접속을 한 번에 처리
# 특성: LLM 에이전트는 사용 불가능한 "사람 전용" 인프라 진입점
#
# 사용법:
#   ssh-admin                    # 인터랙티브 셸 접속 (포트포워딩 포함)
#   ssh-admin 'kubectl get pods' # 원격 명령 실행
#   ssh-admin --tunnel-only      # 포트포워딩 터널만 열기 (bootstrap 등에서 사용)
#
# ============================================================================
set -euo pipefail

export BAO_ADDR="${BAO_ADDR:-https://bao.yourdomain.com}"

SERVER_HOST="<YOUR_SERVER_IP>"
SERVER_PORT="<SSH_PORT>"
SERVER_USER="ubuntu"

# --- 키 우선순위: YubiKey > 소프트 키 ---
YUBIKEY="$HOME/.ssh/id_ed25519_sk"
SOFTKEY="$HOME/.ssh/id_ed25519"

if [[ -f "$YUBIKEY" ]]; then
    SSH_KEY="$YUBIKEY"
    echo "🔑 YubiKey 감지 — 하드웨어 키 사용 (터치 필요)"
elif [[ -f "$SOFTKEY" ]]; then
    SSH_KEY="$SOFTKEY"
    echo "🔓 소프트 키 사용"
else
    echo "❌ SSH 키가 없습니다."
    exit 1
fi
SSH_CERT="${SSH_KEY}-cert.pub"

# --- 인증서 유효성 (만료 5분 전 갱신) 및 키-매칭 확인 로직 (생략) ---
cert_is_valid() {
    [[ -f "$SSH_CERT" ]] || return 1
    # ... 인증서 만료 및 공개키 매칭 검증 ...
    return 1 # 데모용 무조건 재발급 시뮬레이션
}

if cert_is_valid; then
    echo "✅ 기존 인증서 유효 — 재사용"
else
    if ! bao token lookup &>/dev/null; then
        echo "🔐 OpenBao OIDC 인증 중..."
        bao login -method=oidc >/dev/null 2>&1 || exit 1
    fi

    echo "✍️  SSH 인증서 발급 중 (admin-role, TTL: 1h)..."
    bao write -field=signed_key ssh/sign/admin-role \
        public_key=@"${SSH_KEY}.pub" \
        valid_principals="ubuntu,<YOUR_USERNAME>" > "$SSH_CERT"
    chmod 600 "$SSH_CERT"
fi

# --- OpenBao ClusterIP 자동 조회 (SSH 터널링 목적) ---
BAO_CLUSTER_IP=$(ssh -i "$SSH_KEY" -o CertificateFile="$SSH_CERT" \
    -p "$SERVER_PORT" "${SERVER_USER}@${SERVER_HOST}" \
    "kubectl get svc -n openbao openbao -o jsonpath='{.spec.clusterIP}'" 2>/dev/null || echo "")

BAO_FORWARD=""
[[ -n "$BAO_CLUSTER_IP" ]] && BAO_FORWARD="-L 8200:${BAO_CLUSTER_IP}:8200"

# --- 터널 전용 모드 ---
if [[ "${1:-}" == "--tunnel-only" ]]; then
    ssh -N -f \
        -i "$SSH_KEY" -o CertificateFile="$SSH_CERT" \
        -p "$SERVER_PORT" "${SERVER_USER}@${SERVER_HOST}" \
        -L 6443:localhost:6443 \
        -L 8080:localhost:30443 \
        -L 2222:localhost:30022 \
        $BAO_FORWARD
    echo "✅ 백그라운드 SSH 터널 수립 완료 (K3s, Traefik, Git)"
    exit 0
fi

# --- SSH 접속 (인터랙티브 + 로컬 포트포워딩) ---
exec ssh -i "$SSH_KEY" -o CertificateFile="$SSH_CERT" \
    -p "$SERVER_PORT" "${SERVER_USER}@${SERVER_HOST}" \
    -L 6443:localhost:6443 \
    -L 8080:localhost:30443 \
    -L 2222:localhost:30022 \
    $BAO_FORWARD \
    "$@"
