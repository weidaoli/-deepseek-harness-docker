# DeepSeek Harness (dsh) — Docker 容器

把 [deepseek-ai/deepseek-harness](https://github.com/deepseek-ai/deepseek-harness) 以 **npm 分发版**（`@deepseek-ai/dsh`）打包成 Docker 容器，
运行其 Web UI（`dsh web`），并通过挂载卷与宿主机**共享一个工作目录**。

镜像直接在官方 npm 包上构建（无需 clone 源码 / pnpm / 全量编译），已实测：`dsh web` 监听 `127.0.0.1:3080` 返回 HTTP 200，终端（node-pty）等原生模块正常。

## 文件说明

| 文件 | 作用 |
|---|---|
| `Dockerfile` | 单阶段：`npm install -g @deepseek-ai/dsh`，秒级构建 |
| `entrypoint.sh` | 容器入口：从共享工作目录启动 `dsh`，参数直通 CLI |
| `docker-compose.yml` | 一键编排（端口发布 + 双卷挂载） |
| `workspace/` | 与容器共享的工作目录（宿主侧） |

## 快速开始

```bash
cd deepseek-harness-docker

# 构建（npm 包方式，约 1 分钟）
docker build -t dsh .

# 运行：Web UI 在 http://127.0.0.1:3080
# 默认启用 socat 回环转发，-p 端口发布即可直达（Docker Desktop / WSL2 / Linux 通用）
mkdir -p workspace dsh-home && sudo chown -R 1001:1001 workspace dsh-home

docker run --rm -p 3080:3080 \
  -e DSH_RELAY_PORT=3080 \
  -v "$PWD/workspace:/workspace" \
  -v "$PWD/dsh-home:/home/dsh/.dsh" \
  dsh
```

或直接用 compose（已内置上述配置）：

```bash
docker compose up -d --build
```

浏览器打开 <http://127.0.0.1:3080>，在 UI 里 **Choose workspace → 选择 `/workspace`**（这是默认位置，直接确认即可），即可开始使用。

## 共享工作目录（重点）

- 容器内工作目录固定为 `/workspace`，通过 `-v "$PWD/workspace:/workspace"` 与宿主共享。
- dsh 把**启动目录**当作默认文件系统位置，entrypoint 从 `/workspace` 启动，因此共享卷就是默认工作区；agent 对文件的读写都发生在这里，宿主机和容器看到同一份文件。
- 想换目录：`-v /any/host/path:/workspace` 即可，或容器内用环境变量 `DSH_WORKSPACE` 覆盖。

**权限**：容器以非 root 用户 `dsh`（uid 1001）运行，bind 挂载的宿主目录若属主不是 1001 会写不进去。宿主侧执行一次：

```bash
sudo chown -R 1001:1001 workspace/   # 或: chmod -R a+rwX workspace/
```

## 状态持久化

- `~/.dsh`（`DSH_HOME`）存放会话、配置、插件等全部用户数据 → 挂载 `dsh-home:/home/dsh/.dsh`（命名卷或宿主目录）。
- 不挂载也可以跑，但重启后会话/配置会丢。

## 为什么需要 socat 转发 / `--network host`，不能直接 `-p 3080:3080`？

**这是项目的有意设计**：`dsh web --host 0.0.0.0` 会被直接拒绝
（`error: --host 0.0.0.0 is intentionally not supported yet for safety: it would expose remote code execution to the network`）。
服务器只绑定容器内回环地址 `127.0.0.1:3080`，而 Docker 的 `-p` 端口发布把流量送到容器 IP，回环绑定收不到。

两种方案：

1. **socat 回环转发（默认，通用）**：entrypoint 在 `DSH_RELAY_PORT` 非空时启动
   `socat TCP-LISTEN:0.0.0.0:3080 -> TCP:127.0.0.1:3080`，容器内 `-p 3080:3080` 的流量经回环进入 dsh。
   Docker Desktop / WSL2 / Linux 都可用（compose 已内置）。
   ⚠️ 注意：此时容器内 3080 对外网可达，仅在可信网络使用。
2. **`--network host`（纯 Linux 原生）**：容器回环即宿主回环，无需转发，`http://127.0.0.1:3080` 直达；
   服务器保持仅回环绑定，最安全。Docker Desktop 的 VM 后端下 host 网络到不了宿主回环，请用方案 1。

## 常用示例

```bash
# 换端口（dsh 的 --port 直通；转发端口也需一致）
docker run --rm -p 8080:8080 -e DSH_RELAY_PORT=8080 -v "$PWD/workspace:/workspace" dsh web --port 8080

# 纯 Linux 原生：host 网络直连，无需转发
# docker run --rm --network host -v "$PWD/workspace:/workspace" dsh

# 一次性执行任务（headless 模式，需要模型 API key）
docker run --rm -e DEEPSEEK_API_KEY=sk-xxx -v "$PWD/workspace:/workspace" dsh --profile headless "run the tests"

# 查看帮助
docker run --rm dsh --help
docker run --rm dsh web --help
```

## 状态与配置文件共享

**所有 dsh 配置都集中在 `DSH_HOME`（容器内 `/home/dsh/.dsh`）**，与 workspace 一样，建议 bind mount 共享给宿主以便直接查看/编辑/备份：

```yaml
volumes:
  - ./workspace:/workspace       # 工作目录
  - ./dsh-home:/home/dsh/.dsh    # 配置目录（settings.yaml / .credentials.yaml / profiles/ 等）
```

首次使用：

```bash
mkdir -p dsh-home && sudo chown -R 1001:1001 dsh-home
# 可选：先删掉插件依赖目录（几百 MB，容器启动时 dsh 会自动重建）
# rm -rf dsh-home/profiles/node_modules
```

`.dsh` 里各文件的作用：

| 路径 | 内容 | 说明 |
|---|---|---|
| `settings.yaml` | Web UI 设置（模型/provider 选择） | 首次配置后生成 |
| `.credentials.yaml` | API keys | **0600 权限 + 敏感**；宿主侧注意别放宽权限 |
| `storages/workspace.json` | UI 状态（选中的工作区） | |
| `profiles/web/cordis.patch.yml` | **用户配置补丁层** | 想手写配置就改这个 |
| `profiles/web/package.json` | profile 清单、插件依赖声明 | |
| `profiles/node_modules/` | 插件依赖 | 可删除，dsh 会重建 |
| `sessions/` | 会话数据 | |

另外：dsh 会从**启动目录（即 `/workspace`）加载 `.env`**——把 `DEEPSEEK_API_KEY` 等写进共享工作目录的 `.env` 就能直接生效，比改 `.credentials.yaml` 更简单。

## 模型凭据

dsh 是 agent harness，需要 LLM 凭据才能干活。Web UI 里的 **Models 页面**可配置 provider/API key（会写入 `~/.dsh` 持久卷）；命令行/headless 方式可导出环境变量，例如默认 deepseek provider：

```bash
docker run -e DEEPSEEK_API_KEY=sk-xxx ...
```

## 构建细节 / 排错

- **npm 包方式**：`npm install -g @deepseek-ai/dsh`（默认 `latest`，RC 阶段迭代很快）。想固定版本：`docker build --build-arg DSH_VERSION=0.1.0-rc.6 -t dsh .`
- 包自带完整 Web UI 资源与全部依赖（61 个），**无需 clone 源码、无需 pnpm/tsc/tsdown 构建**，构建时间约 1 分钟。
- npm 11 会对 node-pty 等原生依赖的构建脚本给出 allow-scripts 提示，但脚本仍会执行。**`make/g++/python3` 在 Linux 上是必需的**：node-pty（终端功能）的 npm 包只带 darwin/win32 预编译，`prebuilds/linux-x64` 不存在，必然走 `node-gyp rebuild` 本地编译（已实测：去掉编译器后 npm install 直接失败）。不要移除。
- 首次启动 `dsh web` 时会在 `$DSH_HOME/profiles/` 自动准备 web profile（需要访问 npm registry 网络）。
- `HEALTHCHECK` 只对 `web` 模式有意义；headless 等模式显示 unhealthy 属正常现象。
- 镜像约 1.6 GB（node:24-bookworm-slim 基础镜像 + 工具链 + 61 依赖）；嫌大可去掉 `make g++` 构建工具（仅 node-pty 无预编译时兜底用）。
