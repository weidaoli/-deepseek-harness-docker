#!/usr/bin/env bash
# DeepSeek Harness container entrypoint.
#
# 权限模型：容器以 root 启动，自动修复 bind mount 目录（$DSH_HOME /
# $DSH_WORKSPACE）的属主为 uid 1001，然后用 setpriv 降权到 dsh 用户运行。
# 这样宿主侧目录无论是 root 还是其他用户创建的，都无需手动 chown。
#
# 可选 socat 回环转发（DSH_RELAY_PORT）：dsh 拒绝绑定 0.0.0.0（避免暴露
# RCE），在 Docker Desktop / WSL2 下用 socat 把 0.0.0.0:RELAY 转发到
# 127.0.0.1:DSH_PORT，配合 `-p` 端口发布即可访问。
#
# 参数直通 dsh CLI：docker run ... dsh web --port 8080 / dsh --profile headless ...
set -euo pipefail

DSH_HOME="${DSH_HOME:-/home/dsh/.dsh}"
DSH_WORKSPACE="${DSH_WORKSPACE:-/workspace}"
DSH_UID=1001

# ---------------- root 段：修复权限 + 降权重入 ----------------
if [[ "$(id -u)" == "0" ]]; then
  mkdir -p "$DSH_HOME" "$DSH_WORKSPACE"
  for dir in "$DSH_HOME" "$DSH_WORKSPACE"; do
    owner="$(stat -c '%u' "$dir" 2>/dev/null || echo 0)"
    if [[ "$owner" != "$DSH_UID" ]]; then
      echo "dsh-entrypoint: fixing ownership of $dir -> ${DSH_UID}:${DSH_UID}"
      chown -R "$DSH_UID:$DSH_UID" "$dir"
    fi
  done
  # 降权重入（清空继承能力，更安全）
  exec setpriv --reuid="$DSH_UID" --regid="$DSH_UID" --init-groups --inh-caps=-all \
    /usr/local/bin/dsh-entrypoint "$@"
fi

# ---------------- 非 root 段（dsh 用户） ----------------
cd "$DSH_WORKSPACE"

# 兜底告警：以 --user 指定其他用户运行时挂载目录可能不可写
if [[ ! -w . ]]; then
  echo "dsh-entrypoint: WARNING: $(pwd) is not writable by uid $(id -u) — " \
       "run 'chown -R 1001:1001 <host-dir>' (or chmod -R a+rwX) on the host" >&2
fi

# dsh 实际监听端口：`--port N` 优先，否则 $DSH_PORT，默认 3080
DSH_PORT="${DSH_PORT:-3080}"
args=("$@")
IS_WEB=0
for ((i = 0; i < ${#args[@]}; i++)); do
  if [[ "${args[$i]}" == "--port" && $((i + 1)) -lt ${#args[@]} ]]; then
    DSH_PORT="${args[$((i + 1))]}"
  fi
  if [[ "${args[$i]}" == "web" || ( "${args[$i]}" == "--profile" && $((i + 1)) -lt ${#args[@]} && "${args[$((i + 1))]}" == "web" ) ]]; then
    IS_WEB=1
  fi
  # 用户已显式传 --trusted-host 时不再追加
  if [[ "${args[$i]}" == "--trusted-host" ]]; then
    TRUSTED_HOST_GIVEN=1
  fi
done

# HTTPS 反代（Caddy/nginx）场景：浏览器 Host 是域名/IP，不在 dsh 的
# browser-trust 信任列表会导致 /api 全部 403。用 DSH_TRUSTED_HOST 声明
# 该 authority（逗号/空格分隔多个，host 或 host:port）。仅 web 模式生效。
if [[ "$IS_WEB" == "1" && -n "${DSH_TRUSTED_HOST:-}" && -z "${TRUSTED_HOST_GIVEN:-}" ]]; then
  IFS=', ' read -r -a extra_hosts <<< "$DSH_TRUSTED_HOST"
  for h in "${extra_hosts[@]}"; do
    [[ -n "$h" ]] && args+=("--trusted-host" "$h")
  done
fi

# 可选回环转发（--network host 时不要设置 DSH_RELAY_PORT）。
# 只绑定容器主网卡 IP（-p DNAT 的目标），避免与 dsh 的回环绑定冲突。
if [[ -n "${DSH_RELAY_PORT:-}" && "${DSH_RELAY_PORT}" != "0" ]]; then
  RELAY_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
  if [[ -n "$RELAY_IP" && "$RELAY_IP" != "127.0.0.1" ]]; then
    socat "TCP-LISTEN:${DSH_RELAY_PORT},bind=${RELAY_IP},fork,reuseaddr" "TCP:127.0.0.1:${DSH_PORT}" &
  else
    echo "dsh-entrypoint: warning: could not determine container IP, relay disabled" >&2
  fi
fi

exec dsh "${args[@]}"
