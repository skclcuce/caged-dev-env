pid_file = "/tmp/vault-agent.pid"

vault {
  # BAO_ADDR 환경변수로 런타임에 결정됨. (systemd unit 참고)
}

# ─── Auto-Auth: AppRole ───
# 기계 전용 동적 인증 구성
auto_auth {
  method "approle" {
    mount_path = "auth/approle"
    config = {
      role_id_file_path                   = "/home/user/.config/llm-agent/vault-role-id"
      secret_id_file_path                 = "/home/user/.config/llm-agent/vault-secret-id"
      remove_secret_id_file_after_reading = false  # 재인증 시 재사용 필요
    }
  }

  # Vault 토큰을 메모리(tmpfs)에만 저장 (디스크 미기록)
  sink "file" {
    config = {
      path = "/dev/shm/vault-agent-token"
      mode = 0600
    }
  }
}

# ─── Template: 동적 kubeconfig 렌더링 ───
# OpenBao K8s Secrets Engine에서 동적 SA 토큰을 발급받아
# kubectl이 사용할 수 있는 kubeconfig 형식으로 렌더링
template {
  source      = "/home/user/.config/llm-agent/kubeconfig.ctmpl"
  destination = "/dev/shm/llm-kubeconfig"
  perms       = "0600"
  error_on_missing_key = true
}

# ─── Template Config: 전역 설정 ───
template_config {
  exit_on_retry_failure = true  # 렌더링 실패 시 데몬 종료 (fail-fast, 수동 재점화 요구)
}
