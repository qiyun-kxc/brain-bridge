# 🧠🌉 Brain Bridge

Claude Code 大脑续接工具 — 压缩前自动备份上下文，压缩后自动注入。

## 工作流

```
上下文快满 → PreCompact hook
  ├ 备份完整 transcript（保留最近5份）
  └ 截取最后几轮对话（跳过大块 tool output）→ pins/pre-compact-context.once

压缩完成 → SessionStart compact hook
  ├ 注入截取的上下文（.once 用完即删）
  ├ 注入手动 pin（如果有）
  └ 提示完整备份位置

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

## Pin 模式

- `.pin` — 每次压缩后都注入，直到手动删除
- `.once` — 注入一次后自动删除

## 注入预算

默认 30KB（`BRAIN_BRIDGE_MAX_BYTES` 可调），自动截取占 70%，手动 pin 占 30%。

## 致谢

由克栖迟设计开发，晦测试并修复 Claude Code transcript 格式解析。
