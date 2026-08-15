#!/usr/bin/env bash
# DeepSeek Harness container entrypoint.
#
# - Starts dsh from the shared workspace directory: dsh uses its invoking
#   directory as the default filesystem location, so $DSH_WORKSPACE (the
#   mounted /workspace volume) becomes the default.
# - Optional loopback relay (DSH_RELAY_PORT): dsh refuses to bind 0.0.0.0
#   (it would expose RCE), so on Docker Desktop / WSL2 where `--network host`
#   does not reach the host loopback, a socat relay makes plain `-p 3080:3080`
#   port publishing work: 0.0.0.0:RELAY -> 127.0.0.1:DSH_PORT inside the
#   container.
# - Arguments are passed straight to the dsh launcher, e.g.
#     docker run --rm dsh web --port 8080
#     docker run --rm dsh headless "run the tests"
set -euo pipefail

cd "${DSH_WORKSPACE:-/workspace}"

# Warn early when the shared workspace is not writable by the dsh user
# (typical for bind mounts owned by the host user; fix: chown 1001 on host).
if [[ ! -w . ]]; then
  echo "dsh-entrypoint: WARNING: $(pwd) is not writable by uid $(id -u) — " \
       "run 'chown -R 1001:1001 <host-dir>' (or chmod -R a+rwX) on the host" >&2
fi

# The port dsh will actually listen on: `--port N` wins, else $DSH_PORT, else 3080.
DSH_PORT="${DSH_PORT:-3080}"
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  if [[ "${args[$i]}" == "--port" && $((i + 1)) -lt ${#args[@]} ]]; then
    DSH_PORT="${args[$((i + 1))]}"
  fi
done

# Optional loopback relay (opt-in). With --network host you do NOT want this.
# Binds the container's primary non-loopback IP ONLY (that is the address `-p`
# DNAT targets): a wildcard 0.0.0.0 bind would collide with dsh's loopback
# bind (EADDRINUSE) and would expose the port on every interface.
if [[ -n "${DSH_RELAY_PORT:-}" && "${DSH_RELAY_PORT}" != "0" ]]; then
  RELAY_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
  if [[ -n "$RELAY_IP" && "$RELAY_IP" != "127.0.0.1" ]]; then
    socat "TCP-LISTEN:${DSH_RELAY_PORT},bind=${RELAY_IP},fork,reuseaddr" "TCP:127.0.0.1:${DSH_PORT}" &
  else
    echo "dsh-entrypoint: warning: could not determine container IP, relay disabled" >&2
  fi
fi

exec node /opt/deepseek-harness/apps/cli/lib/bin.js "$@"
