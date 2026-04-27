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

# 大块 tool output 的截断阈值
TOOL_OUTPUT_TRIM = 200

PINS_DIR.mkdir(parents=True, exist_ok=True)
BACKUP_DIR.mkdir(parents=True, exist_ok=True)


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
    保留工具调用摘要（#9），跳过大块 tool output。
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
            parts = []
            for block in content:
                if isinstance(block, dict):
                    btype = block.get("type", "")
                    if btype == "text":
                        parts.append(block.get("text", ""))
                    elif btype == "tool_use":
                        # #9 保留工具名和简要输入
                        tool_name = block.get("name", "unknown")
                        tool_input = str(block.get("input", ""))
                        if len(tool_input) > TOOL_OUTPUT_TRIM:
                            tool_input = tool_input[:TOOL_OUTPUT_TRIM] + "..."
                        parts.append(f"[调用工具: {tool_name}({tool_input})]")
                    elif btype == "tool_result":
                        # #9 tool output 保留前200字符摘要
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
    """
    从后往前截取，控制在字节预算内。
    #4 如果最后一条消息超预算，截断保留尾部内容而非整条丢弃。
    """
    result = []
    total = 0

    for msg in reversed(readable):
        entry = f"[{msg['role']}]: {msg['text']}\n\n"
        entry_bytes = len(entry.encode("utf-8"))

        if total + entry_bytes > max_bytes:
            # #4 如果 result 为空（即最后一条就超预算），截断这条消息
            if not result:
                remaining = max_bytes - total - 50  # 留 50 bytes 给标记
                if remaining > 200:
                    text_bytes = msg["text"].encode("utf-8")
                    # 从尾部截取 remaining 字节，找到合法 UTF-8 边界
                    truncated = text_bytes[-remaining:]
                    # 跳过可能的不完整 UTF-8 字符
                    for i in range(min(4, len(truncated))):
                        try:
                            truncated_text = truncated[i:].decode("utf-8")
                            break
                        except UnicodeDecodeError:
                            continue
                    else:
                        truncated_text = truncated.decode("utf-8", errors="replace")
                    result.append({
                        "role": msg["role"],
                        "text": f"...(前文截断)\n{truncated_text}"
                    })
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
    transcript_path = ""

    if len(sys.argv) > 2 and sys.argv[1] == "--transcript":
        transcript_path = sys.argv[2]
    else:
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
