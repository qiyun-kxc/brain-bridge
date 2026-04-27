# 🧠🌉 Brain Bridge

Claude Code 大脑续接工具 — 压缩前自动备份上下文，压缩后自动注入。

## 工作流

```
上下文快满 → PreCompact hook
  ├ 备份完整 transcript（保留最近5份）
  └ 截取最后几轮对话（保留工具调用摘要，跳过大段输出）→ pins/pre-compact-context.once

压缩完成 → SessionStart compact hook
  ├ 优先注入自动快照（pre-compact-context.once）
  ├ 再注入其他 .once 和手动 .pin
  └ 输出 JSON 格式供 Claude Code hook 系统消费

Claude 继续工作，关键上下文还在。
```

## 安装

```bash
curl -sL https://qiyun.cloud/dl/brain-bridge-v2.tar.gz | tar xz -C ~/.claude/
chmod +x ~/.claude/brain-bridge/bridge.sh ~/.claude/brain-bridge/snapshot.py
sudo ln -sf ~/.claude/brain-bridge/bridge.sh /usr/local/bin/bridge
bridge install
```

## 使用

自动功能无需手动操作。手动 pin 作为可选补充：

```bash
bridge pin arch -m "FastAPI + PG15"          # 持久 pin
bridge pin task --once -m "重构 auth 模块"    # 一次性 pin
bridge list                                   # 查看
bridge status                                 # 状态
bridge backups                                # 备份列表
```

Tag 命名：仅允许字母、数字、下划线、短横线。

## Pin 模式

- `.pin` — 每次压缩后都注入，直到手动删除
- `.once` — 注入一次后自动删除（删除前会备份为 `.once.bak`）

## 注入策略

- 总预算 30KB（`BRAIN_BRIDGE_MAX_BYTES` 可调）
- 自动快照占 70%，手动 pin 占 30%
- 注入优先级：`pre-compact-context.once` → 其他 `.once` → `.pin`
- 输出格式：JSON `hookSpecificOutput.additionalContext`

## ⚠️ 安全提醒

**transcript 备份可能包含敏感信息**。备份存储在 `~/.claude/brain-bridge/backups/` 下，可能含有 API key、密码、私有代码等对话中出现的内容。请注意：

- **不要**将 `backups/` 目录提交到 git
- **不要**将备份文件打包、上传或外发
- 备份仅保留最近 5 份，自动轮换
- 如需手动清理：`rm ~/.claude/brain-bridge/backups/*`

建议在 `.gitignore` 中添加：
```
.claude/brain-bridge/backups/
.claude/brain-bridge/pins/
.claude/brain-bridge/inject.log
```

## 文件结构

```
~/.claude/brain-bridge/
├── bridge.sh          # 主脚本
├── snapshot.py        # transcript 解析
├── pins/              # pin 存储
│   ├── arch.pin       # 持久 pin
│   ├── pre-compact-context.once      # 自动截取
│   └── pre-compact-context.once.bak  # 注入后的备份
├── backups/           # transcript 完整备份（最近5份）
└── inject.log         # 注入日志
```

## 致谢

由克栖迟设计开发，晦测试并修复 Claude Code transcript 格式解析。

## License

MIT
