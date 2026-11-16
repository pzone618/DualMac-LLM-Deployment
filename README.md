# Dual Mac LLM Cluster｜双 Mac 本地 AI 集群 v1.1

**日期：2026-11-16** · 中文部署资料 · 面向 **Mac mini M4 Pro 24GB + Mac mini M6 24GB + Thunderbolt 5 线缆**。

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

## 包含内容

- `docs/01-总体方案.md`：角色与网络、需求、架构、切换方式、安全与验收
- `docs/02-M4Pro-主控节点部署.md`：M4 Pro 上从零执行的流程
- `docs/03-M6-工作节点部署.md`：M6 上从零执行的流程
- `docs/04-模型下载与镜像切换.md`：**v1.1 新增** Hugging Face / hf-mirror.com、断点续传、SHA256、分片与双机同步
- `scripts/`：双机安装、模型管理、模式切换、推理与 RPC 启停脚本
- `config/cluster.env.example`：两台机器各自复制的配置模板
- `tests/`：无需连接真实 Hugging Face 的核心逻辑单元测试

## ⚠️ 硬件和安全

Apple 规格显示，**标准 M6 Mac mini 是 Thunderbolt 4**，M4 Pro 是 Thunderbolt 5。因此采用 **Thunderbolt Bridge + TCP + llama.cpp RPC**，不以 RDMA 为前提。模型权重可以分布在两机，但**24GB + 24GB 不是一块 48GB 统一内存**。RPC 实验性且不适用于开放网络。

## 先复制部署包

两台 Mac 都将本 ZIP 解压到 `$HOME/AI/dual-mac-cluster`，例如从 `~/Downloads` 执行：

```bash
mkdir -p ~/AI
unzip -q ~/Downloads/DualMac-LLM-Deployment-v1.1.zip -d ~/AI
mv ~/AI/DualMac-LLM-Deployment-v1.1 ~/AI/dual-mac-cluster
cd ~/AI/dual-mac-cluster
cp config/cluster.env.example config/cluster.env
nano config/cluster.env
```

如果路径已有目录，先备份，勿直接覆盖个人配置。两台按 02、03 的顺序操作，先网络和 SSH，再 bootstrap、模型下载、独立模式、分布式模式。

## 下载：官方站 / 镜像站 / 自动切换

双机管理命令都在 **M4 Pro** 上运行，M6 可通过 SSH 执行：

```bash
cd ~/AI/dual-mac-cluster

# 自动：先 official，失败再 hf-mirror.com
./scripts/model-manager.sh download both ggml-org/gemma-3-1b-it-GGUF \
  --file gemma-3-1b-it-Q4_K_M.gguf --source auto

# 如果官方站慢/不可达，显式指定 hf-mirror.com
./scripts/model-manager.sh download m4 ggml-org/gemma-3-1b-it-GGUF \
  --file gemma-3-1b-it-Q4_K_M.gguf --source mirror

# 恢复下载：重跑相同命令即可（aria2 源站须支持 Range）
# 下载后检验：
./scripts/model-manager.sh verify both ggml-org/gemma-3-1b-it-GGUF \
  gemma-3-1b-it-Q4_K_M.gguf
```

配置文件中 `HF_SOURCE=auto|official|mirror` 定义默认模式；命令行 `--source` 可临时覆盖。**私有/gated 仓库必须用 `--source official --engine hf`**，镜像站不接收认证 Token。详见 [下载手册](docs/04-模型下载与镜像切换.md)。

## 集群模式

```bash
./scripts/cluster-mode.sh local        # M4 / M6 各自独立推理
./scripts/cluster-mode.sh distributed  # M4 llama-server + M6 RPC Worker
./scripts/cluster-mode.sh status
./scripts/cluster-mode.sh stop
```

独立 HTTP: M4 `127.0.0.1:8081`，M6 `192.168.100.2:8082`。分布式 HTTP: M4 `127.0.0.1:8083`。RPC: M6 `192.168.100.2:50052`。IP/端口可在 `config/cluster.env` 调整。

**验证边界**：脚本已经过语法检查和核心逻辑单元测试，但**没有在两台实体 Mac 的 Apple Metal、Thunderbolt、RPC 环境中运行端到端测试**。先用 1B 模型逐步验收，再测试更大型模型。llamactl/Open WebUI 仍是可选的第二阶段手动集成，不宣称一键配置 Web Dashboard。

## 官方资料

- Apple M6 规格：https://support.apple.com/en-us/128108
- Apple M4 Pro 规格：https://support.apple.com/en-us/121555
- llama.cpp RPC：https://github.com/ggml-org/llama.cpp/blob/master/tools/rpc/README.md
- HF CLI：https://huggingface.co/docs/huggingface_hub/guides/cli
- hf-mirror：https://hf-mirror.com/
- aria2：https://aria2.github.io/manual/en/html/aria2c.html
- llamactl：https://github.com/lordmathis/llamactl
