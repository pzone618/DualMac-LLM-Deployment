# Dual Mac LLM Cluster｜双 Mac 本地 AI 集群 v1.2

**更新：2026-11-27** · 中文部署资料 · 面向 **Mac mini M4 Pro 24GB + Mac mini M6 24GB + Thunderbolt 5 线缆**。

## 仅准备模型下载（暂不部署双机）

在本工程根目录执行，不需要集群配置、SSH 或 llama.cpp：

```bash
bash scripts/setup-download.sh
# 已选定的四模型组合（含 Qwen3.5 视觉配套文件）：
bash scripts/download-starter-models.sh
# 模型确定后，将下面的仓库和文件名替换为真实值：
bash scripts/download-model.sh OWNER/REPO --file MODEL.gguf --source mirror --revision FULL_COMMIT_SHA
```

下载环境位于工程 `.venv-download`；默认模型目录为 `~/AI/models`，可以通过
`AI_ROOT=/磁盘路径/AI bash scripts/download-model.sh ...` 调整。无配置时默认使用镜像；
已有 `cluster.env` 的 `HF_SOURCE` 仍会生效，显式 `--source mirror` 可覆盖。
下载入口支持 GGUF，包括上述视觉模型配套的 mmproj GGUF 文件。

首次可省略 `--revision`；保存日志中的 40 位 pinned SHA，后续续传使用该 SHA。
中断后重跑同一命令，保留模型文件、`.aria2` 和隐藏的 `.source.json`。
进度每 10 秒保存一次；服务器不支持续传时终止，不自动清空文件重下。
四模型脚本将各仓库固定版本保存于 `.download-state/`，续传时也需保留该目录。
完成后自动验证大小和上游 SHA256（如有）。更多边界见下载手册。

## 当前部署状态（实测）

M4 Pro（主节点）+ M6（子节点）已按本工程跑通分布式推理：**gemma-4-31B-it Q4_0（17GB）约 8.5 tok/s**，
权重按内存比例分到两台，子节点约占 10GB。

- **M4 单机放不下该模型**：Metal 默认只能用约 2/3 统一内存（24GB 机器约 16GB），实测报 `Insufficient Memory`，只有分布式能跑。
- 分布式比单机慢（每个 token 要经 Thunderbolt 往返）：它的价值是**放得下更大的模型**，不是更快。M4 单机跑 8B 级模型实测约 44 tok/s。
- 推理型模型会先输出 `reasoning_content`，`max_tokens` 设太小时 `content` 为空，这是模型行为。
- 尚未做：Thunderbolt 带宽/RDMA 调优、长时间稳定性、`--tensor-split` 调参。

## ⚠️ 硬件和安全

标准 **M6 Mac mini 是 Thunderbolt 4**，M4 Pro 是 Thunderbolt 5，因此采用 **Thunderbolt Bridge + TCP + llama.cpp RPC**，
不以 RDMA 为前提（脚本设置 `GGML_RPC_NO_RDMA=1`）。**24GB + 24GB 不是一块 48GB 统一内存。**
RPC 实验性、**无鉴权**：worker 只绑定 Thunderbolt 桥接地址（`M6_IP`），不要暴露到局域网或公网；
`llama-server` 默认仅监听 `127.0.0.1`，且未设 API key。

## 从零打通 M4 与 M6（完整流程）

两台全新的 Mac 按下面顺序做。标 **[M4]** 只在主节点做，**[M6]** 只在子节点做，**[两台]** 各做一遍。其中 SSH 一步是可选的，运行分布式服务不依赖它。每一步的细节见后面的"快速开始"。

**1. [两台] 基础软件**：macOS 在 Apple Silicon 上，装好 [Homebrew](https://brew.sh/)，再 `brew install node`（编译 Web UI 要用，`setup` 会装其余依赖）。

**2. [两台] 连线并配置 Thunderbolt Bridge**：用 Thunderbolt 线连接两台。系统设置 → 网络 → Thunderbolt Bridge，IPv4 选"手动"，掩码 `255.255.255.0`，不填路由器和 DNS。也可以命令行设置：

```bash
sudo networksetup -setmanual "Thunderbolt Bridge" 192.168.100.1 255.255.255.0   # M4
sudo networksetup -setmanual "Thunderbolt Bridge" 192.168.100.2 255.255.255.0   # M6
```

验证：M4 上 `ping -c 3 192.168.100.2`，M6 上 `ping -c 3 192.168.100.1`，都应通（延迟 1ms 内）。

**3. [两台] 取得工程并写配置**：

```bash
git clone https://github.com/pzone618/DualMac-LLM-Deployment.git ~/AI/dual-mac-cluster
cd ~/AI/dual-mac-cluster && cp config/cluster.env.example config/cluster.env
```

两边 `cluster.env` 的 `M4_IP`、`M6_IP`、`RPC_PORT` 必须一致。M4 额外设 `DISTRIBUTED_MODEL_REPO` / `_FILE`，必要时设 `MODELS_DIR`。

**4. [两台] 同一版本的 llama.cpp 并编译**：先放好同一份源码（联网 clone，或用 zip 并写 `.commit`，见快速开始第 2 步），再各自编译：

```bash
scripts/master/master.sh setup     # M4
scripts/worker/worker.sh setup     # M6
```

两边输出的 `llama.cpp commit` 必须相同。

**5. [M4] 下载模型**：只有 M4 需要模型文件，M6 不需要。

```bash
scripts/download-model.sh ggml-org/gemma-4-31B-it-GGUF --file gemma-4-31B-it-Q4_0.gguf --source auto
```

**6. 先启动 M6，再启动 M4**：

```bash
scripts/worker/worker.sh start     # M6
scripts/master/master.sh start     # M4，worker 不通时会返回 4 并拒绝启动
```

**7. [M4] 验证**：

```bash
scripts/master/master.sh status                 # Worker RPC ... reachable，Health ok
curl -fsS http://127.0.0.1:8083/health          # 大模型要等几分钟，直到 status: ok
curl -fsS http://127.0.0.1:8083/v1/chat/completions -H 'Content-Type: application/json' \
  -d '{"messages":[{"role":"user","content":"1+1=?"}],"max_tokens":256}'
open http://127.0.0.1:8083/                     # Web UI
```

通过标准：M6 的内存占用明显上升（子节点约 10GB），推理返回结果，速度约 8 tok/s 是正常的（31B 模型）。

**8. [可选] 配置 M4 到 M6 的免密 SSH**：只用于从 M4 远程查看或控制 M6（先开启 M6 的"远程登录"）。

```bash
ssh-copy-id <M6用户名>@192.168.100.2        # 在 M4 上，输入一次 M6 密码
ssh <M6用户名>@192.168.100.2 'cd ~/AI/dual-mac-cluster && scripts/worker/worker.sh status'
```

**9. 关停顺序**：先 `master.sh stop`（M4），最后 `worker.sh stop`（M6）。worker 重启后，master 也必须重启。

## 快速开始（两台各自执行，互相不依赖 SSH）

**1. 取得工程（两台都做）**

```bash
mkdir -p ~/AI && git clone https://github.com/pzone618/DualMac-LLM-Deployment.git ~/AI/dual-mac-cluster
cd ~/AI/dual-mac-cluster
cp config/cluster.env.example config/cluster.env && nano config/cluster.env
```

两边 `cluster.env` 的 IP、端口必须一致。工程放在别处时，用软链接指向 `~/AI/dual-mac-cluster`。
先配好 Thunderbolt Bridge（M4 `192.168.100.1`，M6 `192.168.100.2`，见 `docs/01`）。

**2. 准备 llama.cpp（两台必须是同一个 commit）**

- 联网：`master.sh setup` / `worker.sh setup` 会 clone 并编译（`LLAMA_CPP_REF` 可固定版本）。
- 网络慢：下载 GitHub 的 `llama.cpp-master.zip`，解压为 `~/AI/llama.cpp`，并把 zip 注释里的 commit
  写入 `~/AI/llama.cpp/.commit`（`unzip -z llama.cpp-master.zip` 可见），再运行 `setup` 编译。
  脚本检测到 `.commit` 时直接使用该源码，不再联网，且 **`.commit` 优先于 git HEAD** 参与一致性比较。
- `setup` 用 `-DLLAMA_BUILD_UI=ON -DLLAMA_USE_PREBUILT_UI=OFF` 在本机用 npm 构建并嵌入 Web UI（需要 Node/npm，`brew install node`），不下载预编译资源（zip 源码没有构建号，预编译资源会不匹配）。启动后浏览器打开 `http://127.0.0.1:8083/`（单机为 8081）即可聊天；API 在 `/v1`。

**3. 启动双机服务**

首次部署时，先分别运行 M6 的 `scripts/worker/worker.sh setup` 和 M4 Pro 的 `scripts/master/master.sh setup`。以下命令均从各自的工程根目录执行。

**先在 M6 启动 RPC worker**。所有模型共用这个服务，M6 只需配置桥接地址和 RPC 端口，模型文件放在 M4 Pro。

```bash
scripts/worker/worker.sh start
scripts/worker/worker.sh status
```

**再在 M4 Pro 选择模型并启动 API**。例如，在主节点的 `config/cluster.env` 中设置以下三项。其他量化版本可直接复制实测表中的完整仓库名和文件名。[12 个模型的配置值与实测速度](docs/05-双机模型启停实测.md)

```bash
DISTRIBUTED_MODEL_REPO=ggml-org/gemma-4-31B-it-GGUF
DISTRIBUTED_MODEL_FILE=gemma-4-31B-it-Q4_0.gguf
CTX_SIZE=4096
```

```bash
scripts/master/master.sh start
scripts/master/master.sh status
curl -fsS http://127.0.0.1:8083/health
```

**启动前需要指定模型吗？** 首次启动 master 前，在 M4 Pro 确认一次 `DISTRIBUTED_MODEL_REPO` 和 `DISTRIBUTED_MODEL_FILE`，并确认文件位于 `MODELS_DIR/<仓库>/<文件名>`。之后重启同一个模型只需运行启动命令，脚本会读取已保存的配置。M6 的 worker 和 SSH 隧道都无需指定模型。

核对两端打印的 llama.cpp commit。大模型加载需要时间，等 `/health` 返回 `status: ok` 后再发送请求。8083 是默认主节点 API 端口。查看日志分别运行 `scripts/master/master.sh logs` 和 `scripts/worker/worker.sh logs`。

**换模型或停止**：先在 M4 Pro 运行 `scripts/master/master.sh stop`。换文本生成模型时，只需修改主节点的仓库和文件名，再启动 master，M6 worker 可以继续运行。整套关停时，最后在 M6 运行 `scripts/worker/worker.sh stop`。如果 worker 重启，也要重启 master 以重新建立 RPC 连接。

### 单机启动（仅 M4，不需要 M6）

模型能放进 M4 时，单机更快（8B 级约 40+ tok/s）。在主节点 `cluster.env` 设 `MODEL_REPO` / `MODEL_FILE`，并先停掉 master（两者内存会冲突），然后前台运行：

```bash
scripts/master/master.sh stop
scripts/legacy/run-m4-local.sh        # 监听 127.0.0.1:$M4_LOCAL_PORT（默认 8081），Ctrl-C 停止
curl -fsS http://127.0.0.1:8081/health
```

浏览器打开 `http://127.0.0.1:8081/` 即 Web UI。该脚本已实测（Qwen3-VL-8B Q4_K_M：健康 ok、UI 200、约 43 tok/s）。想后台运行可用 `tmux new -d -s ai-m4-local scripts/legacy/run-m4-local.sh`。不要用 `legacy/cluster-mode.sh local`：它要求 SSH 到 M6，并会让 M6 也起一个独立服务；其 stop 逻辑也不认识新的 `ai-master` 会话。

### 在 M6 通过 SSH 隧道调用 M4 的 API

先按上文启动两端服务。M4 需开启 macOS「远程登录」，并允许 M6 上的用户通过 SSH 登录。下面以 M4 的桥接地址 `192.168.100.1` 和登录用户 `leonyu` 为例，请按实际配置替换。

**在 M6 的第一个终端**建立隧道，并保持终端开启。此命令将 M6 的本地端口转发到 M4 的 API 端口。

```bash
ssh -N -o ExitOnForwardFailure=yes \
  -L 127.0.0.1:8083:127.0.0.1:8083 \
  leonyu@192.168.100.1
```

**在 M6 的第二个终端**检查模型是否就绪，并取得客户端需要的模型 ID。

```bash
curl -fsS http://127.0.0.1:8083/health
curl -fsS http://127.0.0.1:8083/v1/models
```

健康状态为 `ok` 后，M6 的 OpenAI 兼容客户端将 **Base URL** 填为 `http://127.0.0.1:8083/v1`，**模型名**填写模型列表返回的 `data[0].id`。M4 切换模型后，重新查询该 ID 即可沿用原隧道。[llama.cpp 模型列表接口](https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md)

如果 M6 的 8083 已被占用，把转发参数改为 `-L 127.0.0.1:18083:127.0.0.1:8083`，并把 M6 上的检查地址和客户端地址都改用 18083。若 M4 的 `DISTRIBUTED_PORT` 已改动，最后一个端口也要对应修改。用完在第一个终端按 Ctrl-C 关闭隧道，两端推理服务可继续运行。

### 各模型的启动参数怎么选

文本生成模型共用上述流程。本轮统一使用 `-ngl 99 -c 4096`，由 llama.cpp 分配负载。这个配置是比较各模型的起点；最佳上下文长度和两机分配比例还需用目标任务分别测量。35B-A3B MTP Q8_0 在此配置下出现 M6 内存不足。

两个文本嵌入模型在实测时额外使用了 `--embedding`。当前 `master.sh start` 使用文本生成参数。要复现实测，在主节点配置里选好嵌入模型，停止现有 master，保持 M6 worker 运行，再在 M4 Pro 前台执行：

```bash
bash -c '
  source scripts/common/common.sh
  export GGML_RPC_NO_RDMA=1
  exec "$BIN/llama-server" -m "$(model_path "$DISTRIBUTED_MODEL_REPO" "$DISTRIBUTED_MODEL_FILE")" \
    -ngl 99 -c "$CTX_SIZE" --rpc "$M6_IP:$RPC_PORT" --embedding \
    --host 127.0.0.1 --port "$DISTRIBUTED_PORT"
'
```

从另一终端发送嵌入请求，结束时在前台按 Ctrl-C：

```bash
curl -fsS http://127.0.0.1:8083/v1/embeddings -H 'Content-Type: application/json' \
  -d '{"input":"双机检索测试","encoding_format":"float"}'
```

视觉模型的文本入口沿用文本生成命令。启用图像输入时，主节点还需用 `--mmproj` 加载与该模型匹配的视觉投影文件；本轮仅测试文本输入。[llama.cpp server 参数说明](https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md)

低质量 PDF、EPUB 和图片的解析、模型分工及检索验收见[本地知识库建设方案](docs/06-本地知识库建设方案.md)。

## 逐模型双机启停测试

在主节点运行，需能通过 SSH 免交互登录 `M6_USER@M6_IP`，子节点的 RPC 程序位于
`~/AI/llama.cpp/build/bin/`。测试使用独立进程，默认 API 端口为 8183，RPC 端口为 50152。
运行时两台机器都需要为待测模型留出内存。

```bash
bash -c 'set -a; source config/cluster.env; set +a; exec python3 scripts/test-dual-models.py'
```

脚本扫描 `MODELS_DIR`，每个量化文件单独测试，分片模型从第一片启动。
每轮启动 worker 和 master，等待健康检查，发起文本生成或嵌入请求，再停止两端并检查端口关闭。
视觉模型只测文本入口，跳过 mmproj 配套文件、EAGLE3 草稿和隐藏文件。
终端首行给出临时结果目录，内有每轮日志和 `results.jsonl`。任一模型失败时，脚本最终返回非零。

## 配置（`config/cluster.env`，两台各自一份，已被 git 忽略）

| 变量 | 说明 | 默认 |
|---|---|---|
| `M4_IP` / `M6_IP` | Thunderbolt 桥接地址；worker 绑定 `M6_IP` | 192.168.100.1 / .2 |
| `RPC_PORT` / `DISTRIBUTED_PORT` | worker RPC 端口 / master API 端口 | 50052 / 8083 |
| `DISTRIBUTED_MODEL_REPO` / `_FILE` | 分布式模型（主节点读取） | 见模板 |
| `CTX_SIZE` | 上下文长度 | 4096 |
| `AI_ROOT` | llama.cpp、日志、venv 所在目录 | `$HOME/AI` |
| `MODELS_DIR` | 模型目录，可在外置盘，如 `/Volumes/LaCie/AI/models`（未挂载会明确报错） | `$AI_ROOT/models` |
| `MODEL_REPO` / `MODEL_FILE` | 单机模型（仅 M4 本机运行时使用） | 见模板 |
| `M4_LOCAL_PORT` / `M6_LOCAL_PORT` | 单机模式 API 端口（M4 / M6） | 8081 / 8082 |
| `M6_AI_ROOT` / `M6_MODELS_DIR` | 仅 `legacy/` 的 SSH 脚本使用 | `$HOME/AI` |

模型目录布局为 **`MODELS_DIR/<owner>/<repo>/<file>.gguf`**（与 Hugging Face 仓库名一致）。

## 故障排查

| 现象 | 原因与处理 |
|---|---|
| `llama-ui-assets` 编译失败 | 缺 Node/npm，或误用了预编译 UI（zip 源码构建号为 0，资源不匹配）；`brew install node`，确认用的是当前 `bootstrap.sh`，`rm -rf ~/AI/llama.cpp/build/tools/ui` 后重编 |
| 打开 `/` 返回 404 | 该 `llama-server` 编译时没带 UI；重新运行 `setup` |
| `curl /` 返回 415 `gzip is not supported` | 正常：UI 资源以 gzip 嵌入，curl 加 `--compressed`，浏览器不受影响 |
| 推理 `Compute error` / `Insufficient Memory` | 单机放不下模型，或 worker 重启后 master 没重启 |
| `master.sh start` 返回 4 | worker 未启动或端口不通：先 `worker.sh start`，再 `nc -z $M6_IP 50052` |
| `M6_IP ... is not an address of this Mac` | Thunderbolt Bridge 未配置或 `cluster.env` 写错 |
| `content` 为空 | 推理型模型先输出 `reasoning_content`，加大 `max_tokens` |
| `MODELS_DIR ... not mounted` | 外置盘未挂载 |

## 下载：官方站 / 镜像站 / 自动切换

分布式只需**主节点**有模型，在主节点本机下载即可（已有模型直接放进 `MODELS_DIR/<owner>/<repo>/` 也行）：

```bash
cd ~/AI/dual-mac-cluster
# 自动：先 official，失败再 hf-mirror.com
scripts/download-model.sh ggml-org/gemma-4-31B-it-GGUF --file gemma-4-31B-it-Q4_0.gguf --source auto
# 官方站慢/不可达：指定 hf-mirror.com
scripts/download-model.sh OWNER/REPO --file MODEL.gguf --source mirror
# 恢复下载：重跑相同命令即可（aria2 源站须支持 Range）；检验：
scripts/download-model.sh verify OWNER/REPO MODEL.gguf
```

手动放入的模型没有 `.source.json` 清单，`verify` 不会通过，但不影响运行。
需要在两台之间 SSH 同步/批量下载时，可选用 `scripts/legacy/model-manager.sh`（`download m4|m6|both`、`sync`、`inventory`），其用法见 `docs/04`。

配置文件中 `HF_SOURCE=auto|official|mirror` 定义默认模式；命令行 `--source` 可临时覆盖。**私有/gated 仓库必须用 `--source official --engine hf`**，镜像站不接收认证 Token。详见 [下载手册](docs/04-模型下载与镜像切换.md)。

## 官方资料

- Apple M6 规格：https://support.apple.com/en-us/128108
- Apple M4 Pro 规格：https://support.apple.com/en-us/121555
- llama.cpp RPC：https://github.com/ggml-org/llama.cpp/blob/master/tools/rpc/README.md
- HF CLI：https://huggingface.co/docs/huggingface_hub/guides/cli
- hf-mirror：https://hf-mirror.com/
- aria2：https://aria2.github.io/manual/en/html/aria2c.html
- llamactl：https://github.com/lordmathis/llamactl

## 脚本目录结构

```
scripts/
  master/   主节点专用：master.sh（setup/start/stop/status/logs）、run-distributed.sh
  worker/   子节点专用：worker.sh（setup/start/stop/status/logs）、run-rpc.sh
  common/   两边共用：common.sh（读取 config/cluster.env）、bootstrap.sh（安装与编译）
  legacy/   旧的 SSH 一键切换、独立模式脚本、model-manager.sh（可选，暂不维护）
  download-*.sh / setup-download.sh / hf_download.py   模型下载（两边共用）
docs/       01 总体方案 · 02 M4 部署 · 03 M6 部署 · 04 模型下载与镜像切换
config/     cluster.env.example（模板）；cluster.env 为本机私有配置，不入库
tests/      下载器核心逻辑单元测试：python3 -I -m unittest discover -s tests
```

`docs/02`、`docs/03` 是早期 SSH/独立模式流程，仅路径已更新；**以本 README 的快速开始为准**。
**验证边界**：分布式流程已在 M4 Pro + M6 实机验证；`legacy/` 的 SSH 切换与独立模式在新目录结构下未重新实测。
llamactl / Open WebUI 仍是可选的第二阶段手动集成。

