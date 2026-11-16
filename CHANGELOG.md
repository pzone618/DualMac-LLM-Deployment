# 版本记录

## v1.1 · 2026-11-16

- **新增模型源选择**：`--source official|mirror|auto`，分别访问 huggingface.co、hf-mirror.com 或自动回退。
- **新增 aria2 续传**：公开 GGUF 默认使用 aria2c；保留 `.aria2` 状态，支持失败重试及换源续传（取决于远端 HTTP Range 支持）。
- **固定模型 revision**：两节点下载同一 repo 时先解析固定 commit SHA，避免把不同版本拼接。
- **完整性校验**：模型大小、本地 SHA256、可用时的 Hugging Face 上游 LFS SHA256；允许传入可信 `--sha256`。
- **分片 GGUF**：按 pattern 下载完整分片，拒绝遗漏分片/混合量化结果。
- **双机模型同步**：SSH + rsync `--append-verify --partial`，传输后在 M6 再检验 SHA256。
- **鉴权保护**：私有/gated 仅通过官方站和 HF 官方下载器；不会向第三方镜像发送令牌。
- **独立文档**：新增 `docs/04-模型下载与镜像切换.md`。
- **自动化检查**：10 项离线单元测试、Python 编译、所有 Bash 文件语法检查。

## v1.0 · 初始设计

- 1 份总体方案、2 份 Mac 节点部署指南；双独立模式、llama.cpp RPC 分布式模式与基础 SSH 控制脚本。

### 已知限制

- 尚未在两台实体 Mac 上实测。llama.cpp RPC 仍是实验性功能。没有在本包中自动部署 llamactl Web Dashboard。
- 镜像站可能不同步、不可用或不支持 HTTP Range；无法保证所有情况下无损断点续传。
- HF Hub 当前使用包括 Xet 在内的多种对象存储方式；受限模型使用 `--engine hf` 时的断点恢复由 Hugging Face 官方库控制。
- 若无法从可信仓库元数据取得 SHA256，脚本只能证明文件大小及本地 SHA256，不能保证镜像内容一定与官方完全一致。
