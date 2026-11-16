# 部署检查表（建议打印或边执行边勾选）

## M4 Pro / M6 共用

- [ ] 确认 Apple Silicon / macOS / Thunderbolt 端口 / 磁盘空间
- [ ] 使用 TB 线缆连接两台 Mac；创建 Thunderbolt Bridge
- [ ] M4 Pro = 10.77.0.1/24，M6 = 10.77.0.2/24（若已有网络冲突，一起修改）
- [ ] 路由 `route -n get 10.77.0.2` 经过 Thunderbolt Bridge
- [ ] 两台都解压到 `~/AI/dual-mac-cluster`
- [ ] 分别复制并设置 `config/cluster.env`
- [ ] M6 开启 Remote Login；M4 设置 SSH 公钥
- [ ] M4 可通过 SSH 非交互登录 M6
- [ ] 两台完成 `./scripts/bootstrap.sh`
- [ ] 记录 M4 编译 SHA，并在两台一致固定 `LLAMA_CPP_REF`

## Hugging Face 下载与镜像

- [ ] 模型 repo、确切 GGUF 文件名、许可可用
- [ ] 选择 `HF_SOURCE=auto` 或显式 `--source mirror`
- [ ] 下载 1B 测试模型到 M4
- [ ] 用 `verify` 核实大小和 SHA256
- [ ] 下载或 rsync 同步测试模型到 M6，并验证
- [ ] 有意暂停一个测试下载，再用相同 commit 恢复（可选）
- [ ] 记录模型 commit SHA 与文件哈希

## 推理验收

- [ ] `./scripts/cluster-mode.sh local`，M4 :8081 和 M6 :8082 的 `/health` 正常
- [ ] 两个独立 API 均实际完成 chat 请求
- [ ] `./scripts/cluster-mode.sh distributed` 后 M6 :50052 RPC 可连接
- [ ] M4 :8083 实际推理成功，日志证明远端设备参与
- [ ] 测试 `./scripts/cluster-mode.sh stop` 可停止本包的推理会话
- [ ] 记录双机内存使用、加载时间、TTFT 和 tokens/s

### 安全边界

- [ ] RPC 仅在可信 Thunderbolt 专用网络开放，不暴露公网
- [ ] HF Token 不在 Git / 配置文件 / 参数列表中向镜像站传输
- [ ] 确认 LM Studio / Ollama 没有与集群竞争内存或端口
