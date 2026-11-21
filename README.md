# Dual Mac LLM Cluster｜双 Mac 本地 AI 集群 v1.2

**更新：2026-11-21** · 中文部署资料 · 面向 **Mac mini M4 Pro 24GB + Mac mini M6 24GB + Thunderbolt 5 线缆**。

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
只支持 GGUF，视觉配套文件和其他格式尚未纳入此入口。

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
- zip 源码没有构建号，`setup` 已用 `-DLLAMA_USE_PREBUILT_UI=OFF` 避免下载不匹配的 Web UI 资源；`llama-server` 只提供 API。

**3. 模型与启动**

| 步骤 | 主节点（M4 Pro） | 子节点（M6） |
|---|---|---|
| 安装编译 | `scripts/master/master.sh setup` | `scripts/worker/worker.sh setup` |
| 模型 | `MODELS_DIR` 下放分布式 GGUF（**只需主节点有**） | 不需要模型文件 |
| 启动 | **后**：`scripts/master/master.sh start` | **先**：`scripts/worker/worker.sh start` |
| 状态/日志 | `master.sh status` / `master.sh logs` | `worker.sh status` / `worker.sh logs` |
| 停止 | `master.sh stop` | `worker.sh stop` |

- 主节点 API：`http://127.0.0.1:8083/v1`（OpenAI 兼容），健康检查 `/health`；子节点 RPC：`M6_IP:50052`。
- `master.sh start` 会检查模型文件和子节点端口，worker 未就绪时拒绝启动（返回码 4）。
- **worker 重启后 master 必须重启**（RPC 为长连接，否则推理报 `Compute error`）。`stop` 会等端口真正关闭。
- 启动后确认两边打印的 llama.cpp commit 相同。

## 配置（`config/cluster.env`，两台各自一份，已被 git 忽略）

| 变量 | 说明 | 默认 |
|---|---|---|
| `M4_IP` / `M6_IP` | Thunderbolt 桥接地址；worker 绑定 `M6_IP` | 192.168.100.1 / .2 |
| `RPC_PORT` / `DISTRIBUTED_PORT` | worker RPC 端口 / master API 端口 | 50052 / 8083 |
| `DISTRIBUTED_MODEL_REPO` / `_FILE` | 分布式模型（主节点读取） | 见模板 |
| `CTX_SIZE` | 上下文长度 | 4096 |
| `AI_ROOT` | llama.cpp、日志、venv 所在目录 | `$HOME/AI` |
| `MODELS_DIR` | 模型目录，可在外置盘，如 `/Volumes/LaCie/AI/models`（未挂载会明确报错） | `$AI_ROOT/models` |
| `M6_AI_ROOT` / `M6_MODELS_DIR` | 仅 `legacy/` 的 SSH 脚本使用 | `$HOME/AI` |

模型目录布局为 **`MODELS_DIR/<owner>/<repo>/<file>.gguf`**（与 Hugging Face 仓库名一致）。

## 故障排查

| 现象 | 原因与处理 |
|---|---|
| `llama-ui-assets` 编译失败 | zip 源码构建号为 0，Web UI 资源下载不匹配；确认用的是当前 `bootstrap.sh`（已关闭预编译 UI）并 `rm -rf ~/AI/llama.cpp/build/tools/ui` 后重编 |
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

