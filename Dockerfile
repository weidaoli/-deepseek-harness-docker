# syntax=docker/dockerfile:1

# ============================================================================
# DeepSeek Harness (dsh) — npm 分发版
#
# 直接安装 npm 上的 @deepseek-ai/dsh（含完整 Web UI 资源），无需 clone 源码、
# 无需 pnpm/tsc/tsdown 全量构建。镜像大幅缩小、构建秒级完成。
#
# 注意：dsh 的 Web UI 故意只绑定 127.0.0.1（拒绝 --host 0.0.0.0，避免暴露
# 远程代码执行）。通过可选的 socat 回环转发（DSH_RELAY_PORT）配合 -p 发布，
# 或纯 Linux 下用 --network host，详见 README.md。
# ============================================================================

ARG NODE_IMAGE=node:24-bookworm-slim
FROM ${NODE_IMAGE}

# dsh 版本：默认 latest（RC 阶段迭代很快），可用 --build-arg 固定，
# 例如 --build-arg DSH_VERSION=0.1.0-rc.6
ARG DSH_VERSION=latest

# 系统依赖：git/python3/curl/procps 供 agent 任务与健康检查；socat 回环转发；
# make/g++/python3 兜底原生模块（node-pty 等）的 node-gyp 构建。
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl git python3 procps socat make g++ \
 && rm -rf /var/lib/apt/lists/* \
 # UID 1000 被基础镜像的 `node` 用户占用，dsh 用 1001。
 && useradd --create-home --uid 1001 dsh

# 全局安装 dsh CLI。npm 11 会对依赖的原生构建脚本给出 allow-scripts 提示，
# 但脚本仍会执行；其中 node-pty 在 Linux 上无预编译，靠 make/g++/python3
# 经 node-gyp 本地编译（见 README 排错一节）。
RUN npm install -g @deepseek-ai/dsh@${DSH_VERSION} \
 && dsh --version

# 共享工作目录（宿主 bind mount 到 /workspace）
RUN mkdir -p /workspace && chown dsh:dsh /workspace \
 # 预建 dsh home，让全新卷挂载后（copy-up）保留 dsh 属主，否则 dsh 用户
 # 无法在 ~/.dsh 下创建 profiles/。
 && mkdir -p /home/dsh/.dsh && chown -R dsh:dsh /home/dsh

# 不写 USER：默认以 root 启动，entrypoint 自动修复 bind mount 目录属主
# 后通过 setpriv 降权到 dsh(1001) 运行，宿主侧无需手动 chown。

ENV DSH_TELEMETRY_DISABLED=1 \
    DSH_HOME=/home/dsh/.dsh \
    DSH_WORKSPACE=/workspace

COPY --chown=dsh:dsh entrypoint.sh /usr/local/bin/dsh-entrypoint
RUN chmod +x /usr/local/bin/dsh-entrypoint

# 仅作说明——服务器绑定容器内 127.0.0.1:3080。
EXPOSE 3080

# 仅对 web 模式有意义；其他 profile 显示 unhealthy 属正常。
HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
  CMD curl -fsS http://127.0.0.1:3080/ >/dev/null || exit 1

ENTRYPOINT ["/usr/local/bin/dsh-entrypoint"]
CMD ["web"]
