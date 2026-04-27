#!/usr/bin/env bash
# brain-bridge — Claude Code 大脑续接工具
# 压缩前自动备份上下文，压缩后自动注入最后几轮对话 + 手动 pin 的内容
#
# 两层 hook:
#   PreCompact  → bridge.sh snapshot  (备份 transcript，截取尾部存为 .once)
#   SessionStart compact → bridge.sh inject (注入所有 pin 到新上下文)

set -euo pipefail

BRIDGE_DIR="${BRAIN_BRIDGE_DIR:-$HOME/.claude/brain-bridge}"
PINS_DIR="$BRIDGE_DIR/pins"
LOG_FILE="$BRIDGE_DIR/inject.log"
MAX_INJECT_BYTES="${BRAIN_BRIDGE_MAX_BYTES:-30000}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TAG_PATTERN='^[A-Za-z0-9_-]+$'

mkdir -p "$PINS_DIR"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
DIM='\033[2m'
RESET='\033[0m'

usage() {
  cat <<'EOF'
brain-bridge — Claude Code 大脑续接工具 🧠🌉

自动:
  bridge.sh snapshot                  PreCompact hook 调用，备份并截取上下文
  bridge.sh inject                    SessionStart hook 调用，注入所有 pin

手动:
  bridge.sh pin <tag> -m "内容"        pin 一段文字（持久）
  bridge.sh pin <tag> --once -m "..."  注入一次后自动删除
  bridge.sh pin <tag> [file]           pin 文件内容（省略从 stdin）
  bridge.sh list                       列出所有 pin
  bridge.sh show <tag>                 查看某个 pin 的内容
  bridge.sh rm <tag>                   删除某个 pin
  bridge.sh clear                      清空所有 pin

管理:
  bridge.sh install                    安装双层 hook 配置
  bridge.sh status                     查看状态统计
  bridge.sh backups                    列出 transcript 备份

Tag 命名规则: 仅允许字母、数字、下划线、短横线

工作流:
  压缩即将发生 → PreCompact hook → snapshot（备份+截取尾部）
  压缩完成     → SessionStart hook → inject（注入截取的上下文+手动pin）
  晦继续工作，关键上下文还在。需要更多细节可 Read 完整备份。
EOF
}

# ── 校验 tag ──
validate_tag() {
  local tag="$1"
  if [[ ! "$tag" =~ $TAG_PATTERN ]]; then
    echo -e "${RED}错误: tag 只允许字母、数字、下划线、短横线，收到: '${tag}'${RESET}" >&2
    return 1
  fi
}

# ── snapshot (PreCompact hook) ──
cmd_snapshot() {
  if [[ ! -f "$SCRIPT_DIR/snapshot.py" ]]; then
    echo "snapshot.py not found in $SCRIPT_DIR" >&2
    exit 1
  fi
  python3 "$SCRIPT_DIR/snapshot.py"
}

# ── pin ──
cmd_pin() {
  if [[ $# -lt 1 ]]; then
    echo -e "${RED}错误: 需要 tag 名称${RESET}" >&2
    return 1
  fi

  local tag="$1"; shift
  validate_tag "$tag" || return 1

  local mode="pin"
  local message=""
  local source_file=""

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --once) mode="once"; shift ;;
      -m) shift; message="$*"; break ;;
      *) source_file="$1"; shift ;;
    esac
  done

  local file="$PINS_DIR/${tag}.${mode}"

  if [[ -n "$message" ]]; then
    echo "$message" > "$file"
  elif [[ -n "$source_file" ]]; then
    [[ ! -f "$source_file" ]] && { echo -e "${RED}文件不存在: $source_file${RESET}" >&2; return 1; }
    cp "$source_file" "$file"
  else
    cat > "$file"
  fi

  if [[ "$mode" == "pin" ]] && [[ -f "$PINS_DIR/${tag}.once" ]]; then
    rm "$PINS_DIR/${tag}.once"
  elif [[ "$mode" == "once" ]] && [[ -f "$PINS_DIR/${tag}.pin" ]]; then
    rm "$PINS_DIR/${tag}.pin"
  fi

  local size=$(wc -c < "$file")
  local mode_label="持久"
  [[ "$mode" == "once" ]] && mode_label="一次性"
  echo -e "${GREEN}📌 Pinned${RESET}: ${CYAN}${tag}${RESET} (${size} bytes, ${mode_label})"
  check_total_size
}

# ── list ──
cmd_list() {
  local found=0
  for f in "$PINS_DIR"/*.pin "$PINS_DIR"/*.once; do
    [[ -f "$f" ]] || continue
    found=1
    local basename=$(basename "$f")
    local tag="${basename%.*}"
    local ext="${basename##*.}"
    local size=$(wc -c < "$f")
    local preview=$(head -1 "$f" | cut -c1-60)
    local mode_icon="📌"
    [[ "$ext" == "once" ]] && mode_icon="⏳"
    echo -e "${mode_icon} ${CYAN}${tag}${RESET} ${DIM}(${size}B, ${ext})${RESET}: ${preview}"
  done
  [[ $found -eq 0 ]] && echo -e "${DIM}没有 pin。${RESET}"
}

# ── show ──
cmd_show() {
  local tag="${1:?需要 tag 名称}"
  validate_tag "$tag" || return 1
  if [[ -f "$PINS_DIR/${tag}.pin" ]]; then cat "$PINS_DIR/${tag}.pin"
  elif [[ -f "$PINS_DIR/${tag}.once" ]]; then cat "$PINS_DIR/${tag}.once"
  else echo -e "${RED}Pin '${tag}' 不存在${RESET}" >&2; return 1; fi
}

# ── rm ──
cmd_rm() {
  local tag="${1:?需要 tag 名称}"
  validate_tag "$tag" || return 1
  local removed=0
  for ext in pin once; do
    [[ -f "$PINS_DIR/${tag}.${ext}" ]] && { rm "$PINS_DIR/${tag}.${ext}"; removed=1; }
  done
  [[ $removed -eq 1 ]] && echo -e "${GREEN}已删除${RESET}: ${tag}" || { echo -e "${RED}Pin '${tag}' 不存在${RESET}" >&2; return 1; }
}

# ── clear ──
cmd_clear() {
  local count=0
  for f in "$PINS_DIR"/*.pin "$PINS_DIR"/*.once; do
    [[ -f "$f" ]] && { rm "$f"; count=$((count + 1)); }
  done
  echo -e "${GREEN}已清空${RESET} ${count} 个 pin"
}

# ── inject (SessionStart compact hook) ── #1 JSON输出 #2 备份.once #3 注入顺序
cmd_inject() {
  local total_size=0
  local context_parts=""

  # #3 优先级: pre-compact-context.once → 其他 .once → .pin
  local ordered_files=()

  # 第一优先: 自动快照
  if [[ -f "$PINS_DIR/pre-compact-context.once" ]]; then
    ordered_files+=("$PINS_DIR/pre-compact-context.once")
  fi

  # 第二优先: 其他 .once 文件
  for f in "$PINS_DIR"/*.once; do
    [[ -f "$f" ]] || continue
    [[ "$(basename "$f")" == "pre-compact-context.once" ]] && continue
    ordered_files+=("$f")
  done

  # 第三优先: 持久 .pin 文件
  for f in "$PINS_DIR"/*.pin; do
    [[ -f "$f" ]] || continue
    ordered_files+=("$f")
  done

  [[ ${#ordered_files[@]} -eq 0 ]] && return 0

  for f in "${ordered_files[@]}"; do
    local basename=$(basename "$f")
    local tag="${basename%.*}"
    local ext="${basename##*.}"
    local size=$(wc -c < "$f")
    total_size=$((total_size + size))

    if [[ $total_size -gt $MAX_INJECT_BYTES ]]; then
      context_parts+="### ⚠️ ${tag} (跳过: 超出注入上限)\n\n"
      continue
    fi

    local content=$(cat "$f")
    local mode_label=""
    [[ "$ext" == "once" ]] && mode_label=" ⏳一次性"
    context_parts+="### 📌 ${tag}${mode_label}\n${content}\n\n"
  done

  # 组装完整注入内容
  local full_context=""
  full_context+="## 🧠 Brain Bridge: 大脑续接\n\n"
  full_context+="以下是压缩前的上下文快照和手动 pin 的内容。\n"
  full_context+="如需更多细节，完整备份在 ~/.claude/brain-bridge/backups/ 下。\n\n"
  full_context+="$(echo -e "$context_parts")"
  full_context+="\n---\n_共注入 ${total_size} bytes。_"

  # #1 输出 JSON 格式供 SessionStart hook 消费
  local escaped_context
  escaped_context=$(echo -e "$full_context" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))')

  cat <<ENDJSON
{
  "hookSpecificOutput": {
    "hookEventName": "SessionStart",
    "additionalContext": ${escaped_context}
  }
}
ENDJSON

  # #2 .once 文件: 备份后再删除
  for f in "$PINS_DIR"/*.once; do
    if [[ -f "$f" ]]; then
      cp "$f" "${f}.bak"
      rm "$f"
    fi
  done

  echo "[$(date -Iseconds)] Injected: total=${total_size}B" >> "$LOG_FILE" 2>/dev/null || true
}

# ── install ── #5 精确匹配
cmd_install() {
  local settings_file="$HOME/.claude/settings.json"
  local bridge_path="$SCRIPT_DIR/$(basename "$0")"

  echo -e "${CYAN}安装 Brain Bridge 双层 hook...${RESET}"

  if [[ ! -f "$settings_file" ]]; then
    echo -e "${YELLOW}settings.json 不存在: $settings_file${RESET}"
    echo "请先运行一次 Claude Code 生成配置文件。"
    return 1
  fi

  if ! command -v jq &>/dev/null; then
    echo -e "${YELLOW}需要 jq${RESET}"
    return 1
  fi

  # #5 精确检测: command 必须包含 bridge 路径且包含对应子命令
  local has_precompact=false has_sessionstart=false
  jq -e ".hooks.PreCompact[]? | select(.hooks[]?.command | (contains(\"brain-bridge\") and contains(\"snapshot\")))" "$settings_file" &>/dev/null && has_precompact=true
  jq -e ".hooks.SessionStart[]? | select(.matcher == \"compact\" and (.hooks[]?.command | (contains(\"brain-bridge\") and contains(\"inject\"))))" "$settings_file" &>/dev/null && has_sessionstart=true

  if $has_precompact && $has_sessionstart; then
    echo -e "${GREEN}✓ 双层 hook 已安装${RESET}"
    return 0
  fi

  local precompact_hook=$(cat <<HOOKJSON
{
  "hooks": [
    {
      "type": "command",
      "command": "${bridge_path} snapshot"
    }
  ]
}
HOOKJSON
)

  local sessionstart_hook=$(cat <<HOOKJSON
{
  "matcher": "compact",
  "hooks": [
    {
      "type": "command",
      "command": "${bridge_path} inject"
    }
  ]
}
HOOKJSON
)

  local tmp=$(mktemp)
  local jq_expr='. | .hooks //= {}'

  if ! $has_precompact; then
    jq_expr="$jq_expr | .hooks.PreCompact //= [] | .hooks.PreCompact += [\$precompact]"
  fi
  if ! $has_sessionstart; then
    jq_expr="$jq_expr | .hooks.SessionStart //= [] | .hooks.SessionStart += [\$sessionstart]"
  fi

  if jq --argjson precompact "$precompact_hook" \
       --argjson sessionstart "$sessionstart_hook" \
       "$jq_expr" "$settings_file" > "$tmp"; then
    cp "$settings_file" "${settings_file}.bak"
    mv "$tmp" "$settings_file"
    echo -e "${GREEN}✓ 双层 hook 已安装！${RESET}"
    echo "  PreCompact   → snapshot（备份+截取）"
    echo "  SessionStart → inject（注入到新上下文）"
    echo -e "  ${DIM}备份: ${settings_file}.bak${RESET}"
  else
    rm -f "$tmp"
    echo -e "${RED}安装失败${RESET}"
    return 1
  fi
}

# ── backups ──
cmd_backups() {
  local backup_dir="$BRIDGE_DIR/backups"
  if [[ ! -d "$backup_dir" ]] || [[ -z "$(ls -A "$backup_dir" 2>/dev/null)" ]]; then
    echo -e "${DIM}没有备份。${RESET}"
    return
  fi
  echo -e "${CYAN}Transcript 备份:${RESET}"
  for f in "$backup_dir"/transcript_*.jsonl; do
    [[ -f "$f" ]] || continue
    local size=$(du -h "$f" | cut -f1)
    echo -e "  ${DIM}${size}${RESET}  $(basename "$f")"
  done
  echo -e "\n  ${DIM}路径: $backup_dir${RESET}"
}

# ── status ──
cmd_status() {
  echo -e "${CYAN}🧠 Brain Bridge 状态${RESET}"
  echo ""

  local pin_count=0 once_count=0 total_bytes=0
  for f in "$PINS_DIR"/*.pin; do
    [[ -f "$f" ]] && { pin_count=$((pin_count + 1)); total_bytes=$((total_bytes + $(wc -c < "$f"))); }
  done
  for f in "$PINS_DIR"/*.once; do
    [[ -f "$f" ]] && { once_count=$((once_count + 1)); total_bytes=$((total_bytes + $(wc -c < "$f"))); }
  done

  echo "  持久 pin: ${pin_count}"
  echo "  一次性 pin: ${once_count}"
  echo "  总大小: ${total_bytes} / ${MAX_INJECT_BYTES} bytes"

  if [[ $MAX_INJECT_BYTES -gt 0 ]]; then
    local pct=$((total_bytes * 100 / MAX_INJECT_BYTES))
    local color=$GREEN
    [[ $pct -gt 70 ]] && color=$YELLOW
    [[ $pct -gt 90 ]] && color=$RED
    printf "  使用率: ${color}%d%%${RESET}\n" "$pct"
  fi

  local settings_file="$HOME/.claude/settings.json"
  if [[ -f "$settings_file" ]] && command -v jq &>/dev/null; then
    local pre="✗" post="✗"
    jq -e '.hooks.PreCompact[]? | select(.hooks[]?.command | (contains("brain-bridge") and contains("snapshot")))' "$settings_file" &>/dev/null && pre="✓"
    jq -e '.hooks.SessionStart[]? | select(.matcher == "compact" and (.hooks[]?.command | (contains("brain-bridge") and contains("inject"))))' "$settings_file" &>/dev/null && post="✓"
    echo ""
    echo -e "  PreCompact hook:  $([ "$pre" = "✓" ] && echo "${GREEN}✓${RESET}" || echo "${RED}✗${RESET}")"
    echo -e "  SessionStart hook: $([ "$post" = "✓" ] && echo "${GREEN}✓${RESET}" || echo "${RED}✗${RESET}")"
    [[ "$pre" = "✗" || "$post" = "✗" ]] && echo -e "  ${DIM}运行 bridge.sh install 安装${RESET}"
  fi

  local backup_count=0
  if [[ -d "$BRIDGE_DIR/backups" ]]; then
    backup_count=$(ls "$BRIDGE_DIR/backups"/transcript_*.jsonl 2>/dev/null | wc -l)
  fi
  echo ""
  echo "  Transcript 备份: ${backup_count} 份"

  if [[ -f "$LOG_FILE" ]]; then
    echo -e "\n  ${DIM}最近活动:${RESET}"
    tail -3 "$LOG_FILE" | while read -r line; do echo "    $line"; done
  fi
}

# ── 辅助 ──
check_total_size() {
  local total=0
  for f in "$PINS_DIR"/*.pin "$PINS_DIR"/*.once; do
    [[ -f "$f" ]] && total=$((total + $(wc -c < "$f")))
  done
  if [[ $total -gt $MAX_INJECT_BYTES ]]; then
    echo -e "${YELLOW}⚠️  总大小 ${total}B 超出注入上限 ${MAX_INJECT_BYTES}B${RESET}"
  fi
}

# ── 主入口 ──
case "${1:-help}" in
  snapshot) cmd_snapshot ;;
  pin)      shift; cmd_pin "$@" ;;
  list|ls)  cmd_list ;;
  show)     shift; cmd_show "$@" ;;
  rm)       shift; cmd_rm "$@" ;;
  clear)    cmd_clear ;;
  inject)   cmd_inject ;;
  install)  cmd_install ;;
  status)   cmd_status ;;
  backups)  cmd_backups ;;
  help|-h|--help) usage ;;
  *)        echo -e "${RED}未知命令: $1${RESET}" >&2; usage >&2; exit 1 ;;
esac
