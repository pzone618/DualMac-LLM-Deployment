# Dual Mac LLM Cluster 部署包

**版本：v1.0 · 2026-11-16 · 语言：中文**

适用于 **Mac mini M4 Pro 24GB（主控）+ Mac mini M6 24GB（工作节点）+ Thunderbolt 5 线缆**。实现两种运行模式：

- 独立：M4 Pro 与 M6 各运行自己的 `llama-server`。
- 分布式：M4 Pro 运行 `llama-server --rpc`，M6 运行 `ggml-rpc-server`。

**已核对的硬件限制**：M4 Pro 具备 Thunderbolt 5，但 **M6 标准版只有 Thunderbolt 4**。雷电 5 线缆不等于两端都具备雷电 5 硬件。本包明确采用 **Thunderbolt Bridge TCP**；不执行 `rdma_ctl enable`。

## 从哪里开始

1. 双机都先读 [`docs/01-总体方案.md`](docs/01-总体方案.md)。
2. M4 Pro 专用：[`docs/02-M4Pro-主控节点部署.md`](docs/02-M4Pro-主控节点部署.md)。
3. M6 专用：[`docs/03-M6-工作节点部署.md`](docs/03-M6-工作节点部署.md)。
4. 两台 Mac 的部署包统一存放在：`~/AI/dual-mac-cluster/`（必须保持相同路径，方便远程管理）。
5. 复制 `config/cluster.env.example` 到 `config/cluster.env`，按需修改 `M6_USER` 和版本锁定 `LLAMA_CPP_REF`。

本包的脚本是基于官方文档制作的部署起点，尚未在你的两台真实 Mac 上运行验证。首轮必须先测试小模型；RPC 在官方标记为实验性，请仅在可信网络运行。

## 主要命令（全部在 M4 Pro 执行）

```bash
cd ~/AI/dual-mac-cluster
./scripts/cluster-mode.sh local
./scripts/cluster-mode.sh distributed
./scripts/cluster-mode.sh status
./scripts/cluster-mode.sh stop
./scripts/model-manager.sh inventory
./scripts/model-manager.sh download m4 ggml-org/gemma-3-1b-it-GGUF gemma-3-1b-it-Q4_K_M.gguf
./scripts/model-manager.sh download m6 ggml-org/gemma-3-1b-it-GGUF gemma-3-1b-it-Q4_K_M.gguf
```

说明：`local` 只影响此部署包创建的 tmux 会话。服务可通过 `tmux ls` 检查，日志在 `~/AI/logs/`。

## 官方资料

- Apple M6 ports: https://support.apple.com/en-us/128108
- Apple M4 Pro ports: https://support.apple.com/en-us/121555
- Apple RDMA TN3205: https://developer.apple.com/documentation/technotes/tn3205-low-latency-communication-with-rdma-over-thunderbolt
- llama.cpp RPC: https://github.com/ggml-org/llama.cpp/blob/master/tools/rpc/README.md
- llama.cpp Server: https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md
- Hugging Face CLI: https://huggingface.co/docs/huggingface_hub/guides/cli
- llamactl: https://github.com/lordmathis/llamactl
