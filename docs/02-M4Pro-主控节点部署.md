# 02｜Mac mini M4 Pro 24GB：主控节点部署手册

> **仅在 M4 Pro 上执行**，除非明确指出需要 M6 配合。需先读 [`01-总体方案.md`](01-总体方案.md)。
>
> 环境预设：Apple Silicon arm64、M4 Pro 24GB、TB5 端口，**对端 M6 为 TB4，使用 TCP over Thunderbolt**。

## 0. 开始前检查

确认部署包在此目录（两台必须一样）：

```bash
mkdir -p ~/AI
# 从 ZIP 解压后把 DualMac-LLM-Deployment 目录重命名/放置为：
# ~/AI/dual-mac-cluster/
cd ~/AI/dual-mac-cluster
pwd
ls docs scripts config
```

收集环境清单，后续出问题可直接复制到问题报告：

```bash
uname -m
sw_vers
system_profiler SPHardwareDataType | grep -E 'Model Name|Model Identifier|Chip|Memory'
system_profiler SPThunderboltDataType | head -60
df -h "$HOME"
```

预期 `uname -m` 为 `arm64`。如果这台机器仍装有会占用大量显存/统一内存的 Ollama、LM Studio 等模型，部署时先退出运行中的模型。

## 1. 配 Thunderbolt Bridge IP

1. 将雷电 5 线缆插入 **M4 Pro 后部 Thunderbolt 5 端口**，另一头插 M6 后部 Thunderbolt 4 端口。
2. 打开 macOS **系统设置 → 网络 → Thunderbolt Bridge**。若未显示，可根据系统版本在网络设置中添加该服务。
3. M4 的 IPv4 设为 **手动 192.168.100.1**，子网掩码 **255.255.255.0**；不要给这条点对点链路指定默认网关。
4. M6 按其文档设为 **192.168.100.2 /24**。
5. 检查地址：

```bash
ifconfig | grep -A6 -E '^bridge[0-9]+:'
ping -c 4 192.168.100.2
route -n get 192.168.100.2
```

`route -n get` 结果应使用 Thunderbolt Bridge 对应的接口，不要误走 Wi-Fi/VPN。若 `10.77.0.0/24` 已与现有网络冲突，**同时**修改两台网络配置和各自 `config/cluster.env`。

## 2. SSH 到 M6（用于主控命令）

先在 M6 打开 `Remote Login`。在 M4：

```bash
ssh-keygen -t ed25519 -C dual-mac-cluster
# 如果你已经有 key，可直接沿用，不要覆盖已有密钥。
cat ~/.ssh/id_ed25519.pub
```

把输出的公钥**追加**到 M6 上用户的 `~/.ssh/authorized_keys`。建议通过 M6 本机终端配置，完成后：

```bash
ssh <M6的macOS用户名>@192.168.100.2 whoami
ssh -o BatchMode=yes <M6的macOS用户名>@192.168.100.2 'uname -m'
```

第二条需无密码/弹窗地成功；否则 `cluster-mode.sh` 远程模式切换无法非交互执行。

## 3. 编辑共享配置

```bash
cd ~/AI/dual-mac-cluster
cp config/cluster.env.example config/cluster.env
nano config/cluster.env
```

**必改项**（`your_m6_username` 是示例占位，必须换成 `whoami` 返回的真实用户名）：

```bash
M4_IP=192.168.100.1
M6_IP=192.168.100.2
M6_USER=your_m6_username
LLAMA_CPP_REF=master
```

先允许 master 完成第一次 clone；**完成后务必按下一节记录 SHA 并同步到两台**。若无 SSH key，请先完成 SSH 验证。

## 4. 安装依赖与编译

建议 Homebrew 已安装（https://brew.sh），先检查 `brew --version`。本包**不会自动安装 Homebrew**，避免未经检查执行远程 shell 脚本。

```bash
cd ~/AI/dual-mac-cluster
xcode-select -p || xcode-select --install
./scripts/bootstrap.sh
```

此脚本将使用 brew 安装 CMake、Git、tmux、Python；源码位置 `~/AI/llama.cpp`；CMake 参数为 `-DGGML_METAL=ON -DGGML_RPC=ON`；在 `~/AI/.venv` 安装 `huggingface_hub`。

完成后固定版本：

```bash
git -C ~/AI/llama.cpp rev-parse HEAD
~/AI/llama.cpp/build/bin/llama-server --version
```

将完整 **40 位 SHA** 填入 M4 和 M6 的 `config/cluster.env`（不要原样保留示例占位符）：

```bash
LLAMA_CPP_REF=PASTE_FULL_GIT_SHA_HERE
```

然后 **M6 按其手册用完全相同 SHA 编译**。M4 若已在该 SHA，通常无需再次重新编译；想保证环境一致也可重跑 `./scripts/bootstrap.sh`。

## 5. 下载测试模型（M4）

本包 v1.1 支持 `huggingface.co` / `hf-mirror.com`。默认 `HF_SOURCE=auto`；`--source mirror` 显式优先使用镜像。aria2 会保留 `.aria2` 断点数据，网络断开后**重跑相同命令**即可尝试恢复（前提是服务器支持 HTTP Range）。

```bash
cd ~/AI/dual-mac-cluster
# 官方站 -> 镜像站自动切换
./scripts/download-model.sh ggml-org/gemma-3-1b-it-GGUF \
  --file gemma-3-1b-it-Q4_K_M.gguf --source auto

# 需要镜像时：
./scripts/download-model.sh ggml-org/gemma-3-1b-it-GGUF \
  --file gemma-3-1b-it-Q4_K_M.gguf --source mirror

# SHA256 验证已下载文件
./scripts/download-model.sh verify ggml-org/gemma-3-1b-it-GGUF \
  gemma-3-1b-it-Q4_K_M.gguf
```

模型将保存到：

```text
~/AI/models/ggml-org__gemma-3-1b-it-GGUF/gemma-3-1b-it-Q4_K_M.gguf
```

M6 bootstrap/SSH 配置完成后，可在 M4 统一下载：

```bash
./scripts/model-manager.sh download m6 ggml-org/gemma-3-1b-it-GGUF \
  --file gemma-3-1b-it-Q4_K_M.gguf --source mirror
./scripts/model-manager.sh inventory
```

分片模型使用 `--pattern` 下载匹配的全部分片。私有/需申请许可的模型只能使用 `--source official --engine hf`。完整示例与切换源站的安全机制详见 [`04-模型下载与镜像切换.md`](04-模型下载与镜像切换.md)。

## 6. 首次独立运行（手动验证，前台）

```bash
cd ~/AI/dual-mac-cluster
./scripts/run-m4-local.sh
```

打开另一个 Terminal：

```bash
curl -i http://127.0.0.1:8081/health
curl -s http://127.0.0.1:8081/v1/models
```

健康检查变成 `200` 且含 `"status":"ok"` 后，用模型端点实测：

```bash
curl -s http://127.0.0.1:8081/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"messages":[{"role":"user","content":"Say hello in English."}],"max_tokens":64}'
```

完成后按 `Ctrl+C` 退出前台服务，避免和 tmux 启动模式冲突。

## 7. 第一次双机 Independent 模式

前提：M6 已完成 bootstrap、模型下载、SSH、IP；两端 `llama.cpp` SHA 相同。

```bash
cd ~/AI/dual-mac-cluster
./scripts/cluster-mode.sh local
./scripts/cluster-mode.sh status
curl -i http://127.0.0.1:8081/health
curl -i http://192.168.100.2:8082/health
```

脚本将启动两个 tmux 会话：M4 `ai-m4-local`，M6 `ai-m6-local`。检查：

```bash
tmux ls
ssh <M6用户名>@192.168.100.2 'tmux ls'
tail -n 80 ~/AI/logs/m4-local.log
```

模型加载时 `/health` 可短暂返回 503，请等加载完成再测试；不要仅凭 tmux 有会话就判定服务已就绪。

## 8. 首次 Distributed 模式

```bash
cd ~/AI/dual-mac-cluster
./scripts/cluster-mode.sh distributed
./scripts/cluster-mode.sh status
curl -i http://127.0.0.1:8083/health
```

如果失败：

```bash
nc -G 2 -vz 192.168.100.2 50052
tail -n 120 ~/AI/logs/m4-distributed.log
ssh <M6用户名>@192.168.100.2 'tail -n 120 ~/AI/logs/m6-rpc.log'
```

模式脚本检查两端 **Git commit 是否一致**；不一致就拒绝进入分布式模式。

验证实际推理：

```bash
curl -s http://127.0.0.1:8083/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"messages":[{"role":"user","content":"Explain two-node inference in one sentence."}],"max_tokens":96}'
```

这一步仍是**小模型连接测试**。若想证明利用双机内存，在 M4 下载更大的 GGUF，修改两台（至少 M4）的 `DISTRIBUTED_MODEL_REPO` 与 `DISTRIBUTED_MODEL_FILE`，然后重新执行 `cluster-mode.sh distributed`。同时监测两台 Activity Monitor 的内存占用，以及 RPC 日志中的设备分配。

## 9. 模式切换与模型清单

```bash
cd ~/AI/dual-mac-cluster
./scripts/cluster-mode.sh local          # 两台独立运行
./scripts/cluster-mode.sh distributed    # M4 + M6 RPC
./scripts/cluster-mode.sh status         # 显示 tmux、健康状态
./scripts/cluster-mode.sh stop           # 停止本包管理的模式服务
./scripts/model-manager.sh inventory     # 查看双机模型文件
```

**启动新模式不会删除模型文件。** 同一机器同一时间只选择一种主模式，避免 24GB 内存压力变大。

## 10. llamactl Dashboard（第二阶段）

在两种模式验证成功后，访问：

- https://github.com/lordmathis/llamactl/releases/latest
- https://github.com/lordmathis/llamactl

从 Releases 选择适用于 macOS arm64 的包，阅读对应版本的 README 与配置文档，再在 M4 原生运行。先选一个端口不冲突的 Dashboard（通常项目默认 `8080`，以实际版本为准）。**不要直接让它接管已由 tmux 控制的相同 llama-server 端口**；先验证当前版本可否将现有远端 HTTP API 作为外部端点接入。否则使用 Open WebUI 或后续 FastAPI Gateway 汇聚三个 API，保留 llamactl 做模型下载/单机生命周期管理。

## 11. 常见故障

| 故障 | 优先排查 |
|---|---|
| `brew: command not found` | 确认 Homebrew 安装、`/opt/homebrew/bin` 在 PATH |
| `ssh` 提示密码 | M6 `authorized_keys`、Remote Login、用户/SSH 权限 |
| `nc ... 50052` 失败 | M6 RPC 进程、Thunderbolt IP、macOS 防火墙、Local Network 权限 |
| 分布式 Git SHA 不匹配 | 双机 `LLAMA_CPP_REF` 锁定同一 SHA 并重新编译 |
| `failed to allocate` / OOM | 退出 LM Studio/Ollama、缩小 `CTX_SIZE`、换低量化 |
| `/health` 503 | 模型正在加载；先查日志，等待初始化结束 |
| port already in use | `lsof -nP -iTCP:8081 -sTCP:LISTEN` 等检查监听进程 |
| 模型找不到 | `model-manager.sh inventory`，检查 repo/文件名与 `.env` |
| 分布式速度差 | 小模型不适合 RPC，TB4/TCP 链路开销不可忽略 |

## 12. M4 验收记录模板

```text
日期：
M4 macOS：
M4 CPU/GPU/内存：
M6 macOS：
llama.cpp SHA（双机一致）：
Thunderbolt Bridge M4 IP：
Thunderbolt Bridge M6 IP：
SSH 无密码登录：[ ]
M4 单机 API：[ ]
M6 单机 API：[ ]
分布式 API：[ ]
RPC Device 日志：[ ]
模型 ID / 量化 / 文件大小：
TTFT / tokens/s（独立）：
TTFT / tokens/s（分布式）：
异常与日志路径：
```
