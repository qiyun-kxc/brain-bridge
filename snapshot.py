#!/usr/bin/env python3
"""
brain-bridge snapshot — 从 transcript 中提取最后几轮对话
PreCompact hook 调用，自动存为 .once pin

用法：
  echo '{"transcript_path": "..."}' | snapshot.py
  snapshot.py --transcript /path/to/transcript.jsonl
"""

import json
import sys
import os
import shutil
from pathlib import Path
from datetime import datetime

BRIDGE_DIR = Path(os.environ.get("BRAIN_BRIDGE_DIR", Path.home() / ".claude" / "brain-bridge"))
PINS_DIR = BRIDGE_DIR / "pins"
BACKUP_DIR = BRIDGE_DIR / "backups"
MAX_INJECT_BYTES = int(os.environ.get("BRAIN_BRIDGE_MAX_BYTES", 30000))

# 大块 tool output 的截断阈值（超过这个长度的 content 只保留摘要）
TOOL_OUTPUT_TRIM = 200

PINS_DIR.mkdir(parents=True, exist_ok=True)
BACKUP_DIR.mkdir(parents=True, exist_ok=True)


def find_transcript_path():
    """从 stdin 的 PreCompact hook JSON 输入中提取 transcript_path"""
    try:
        hook_input = json.load(sys.stdin)
        return hook_input.get("transcript_path", "")
    except (json.JSONDecodeError, EOFError):
        return ""


def parse_transcript(path: str) -> list:
    """解析 JSONL transcript 文件"""
    messages = []
    try:
        with open(path, "r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    msg = json.loads(line)
                    messages.append(msg)
                except json.JSONDecodeError:
                    continue
    except FileNotFoundError:
        print(f"Transcript not found: {path}", file=sys.stderr)
    return messages


def extract_readable(messages: list) -> list:
    """
    从消息列表中提取人类可读的对话内容。
    跳过大块 tool output，只保留 user/assistant 的文字部分。
    """
    readable = []

    for msg in messages:
        # Claude Code transcript 格式: {"type":"user","message":{"role":"user","content":"..."}}
        msg_type = msg.get("type", "")
        if msg_type in ("user", "assistant"):
            inner = msg.get("message", {})
            role = inner.get("role", msg_type)
            content = inner.get("content", "")
        else:
            # 兼容扁平格式
            role = msg.get("role", "")
            if role not in ("user", "assistant"):
                continue
            content = msg.get("content", "")

        # content 可能是字符串或数组
        if isinstance(content, str):
            text = content.strip()
        elif isinstance(content, list):
            # 提取 text 类型的 block，跳过 tool_use/tool_result/image
            parts = []
            for block in content:
                if isinstance(block, dict):
                    btype = block.get("type", "")
                    if btype == "text":
                        parts.append(block.get("text", ""))
                    elif btype == "tool_use":
                        tool_name = block.get("name", "unknown")
                        parts.append(f"[调用工具: {tool_name}]")
                    elif btype == "tool_result":
                        # tool output 只保留摘要
                        result_content = str(block.get("content", ""))
                        if len(result_content) > TOOL_OUTPUT_TRIM:
                            result_content = result_content[:TOOL_OUTPUT_TRIM] + "...(截断)"
                        parts.append(f"[工具结果: {result_content}]")
                    # 跳过 image, document 等
                elif isinstance(block, str):
                    parts.append(block)
            text = "\n".join(parts).strip()
        else:
            continue

        if text:
            readable.append({"role": role, "text": text})

    return readable


def tail_to_budget(readable: list, max_bytes: int) -> list:
    """从后往前截取，控制在字节预算内"""
    result = []
    total = 0

    for msg in reversed(readable):
        entry = f"[{msg['role']}]: {msg['text']}\n\n"
        entry_bytes = len(entry.encode("utf-8"))

        if total + entry_bytes > max_bytes:
            break

        result.append(msg)
        total += entry_bytes

    result.reverse()
    return result


def format_output(messages: list) -> str:
    """格式化为注入文本"""
    lines = []
    for msg in messages:
        role_label = "🧑 User" if msg["role"] == "user" else "🤖 Assistant"
        lines.append(f"**{role_label}**:\n{msg['text']}\n")
    return "\n".join(lines)


def main():
    # 获取 transcript 路径
    transcript_path = ""

    # 优先从命令行参数
    if len(sys.argv) > 2 and sys.argv[1] == "--transcript":
        transcript_path = sys.argv[2]
    else:
        # 从 stdin（hook 输入）
        if not sys.stdin.isatty():
            try:
                hook_input = json.load(sys.stdin)
                transcript_path = hook_input.get("transcript_path", "")
            except (json.JSONDecodeError, EOFError):
                pass

    if not transcript_path:
        print("No transcript_path found", file=sys.stderr)
        sys.exit(1)

    # 1. 备份完整 transcript
    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    backup_path = BACKUP_DIR / f"transcript_{timestamp}.jsonl"
    try:
        shutil.copy2(transcript_path, str(backup_path))
    except Exception as e:
        print(f"Backup failed: {e}", file=sys.stderr)

    # 只保留最近 5 份备份
    backups = sorted(BACKUP_DIR.glob("transcript_*.jsonl"))
    for old in backups[:-5]:
        old.unlink(missing_ok=True)

    # 2. 解析并提取可读内容
    messages = parse_transcript(transcript_path)
    readable = extract_readable(messages)

    if not readable:
        print("No readable messages found", file=sys.stderr)
        sys.exit(0)

    # 3. 倒着截取，控制在预算内
    # 注入预算：总预算的 70%，留 30% 给手动 pin
    inject_budget = int(MAX_INJECT_BYTES * 0.7)
    tail = tail_to_budget(readable, inject_budget)

    if not tail:
        sys.exit(0)

    # 4. 存为 .once pin
    output = format_output(tail)
    pin_path = PINS_DIR / "pre-compact-context.once"
    pin_path.write_text(output, encoding="utf-8")

    # 5. 记录日志
    log_path = BRIDGE_DIR / "inject.log"
    with open(log_path, "a") as f:
        f.write(f"[{datetime.now().isoformat()}] Snapshot: {len(tail)} messages, "
                f"{len(output.encode('utf-8'))}B from {transcript_path}\n")

    print(f"Snapshot saved: {len(tail)} messages, {len(output.encode('utf-8'))}B", file=sys.stderr)


if __name__ == "__main__":
    main()
