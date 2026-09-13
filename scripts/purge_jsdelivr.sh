#!/usr/bin/env bash
#
# 刷新 jsDelivr 缓存
#
# 用法：
#   bash scripts/purge_jsdelivr.sh [owner/repo] [ref] [文件...]
#
# 默认：
#   Brandon-LIs/paper   refs/heads/main   paper.webp lite.webp
#
# 关于限流（重要）：
#   jsDelivr 对**同一路径**的刷新每约 1 小时只放行一次。重复请求会返回
#     { "throttled": true, "throttlingReset": <剩余秒数> }
#   这表示该路径刚刚已经刷新过（缓存本来就是新的），属于正常情况而非失败，
#   本脚本只提示、不报错。本工作流每天只跑一次，正常情况下不会触发限流。
#
# 环境变量：
#   JSDELIVR_UA    请求 UA，默认见下方 DEFAULT_UA
#   PURGE_RETRIES  网络类失败的重试次数，默认 3
#   PURGE_GRACE    首次刷新前的等待秒数，默认 5（等 GitHub 侧同步完成）

set -euo pipefail

SLUG="${1:-Brandon-LIs/paper}"
REF="${2:-refs/heads/main}"
if [ "$#" -gt 2 ]; then
  shift 2
  FILES=("$@")
else
  FILES=(paper.webp lite.webp)
fi

DEFAULT_UA="Mozilla/5.0 (compatible; BingWallpaperAction/1.0; +https://github.com/${SLUG})"
UA="${JSDELIVR_UA:-$DEFAULT_UA}"
PURGE_RETRIES="${PURGE_RETRIES:-3}"
PURGE_GRACE="${PURGE_GRACE:-5}"

log()  { printf '[jsdelivr-purge] %s\n' "$*"; }
warn() { printf '[jsdelivr-purge] 警告：%s\n' "$*" >&2; }
die()  { printf '[jsdelivr-purge] 错误：%s\n' "$*" >&2; exit 1; }

command -v curl    >/dev/null 2>&1 || die "未找到 curl"
command -v python3 >/dev/null 2>&1 || die "未找到 python3"

# 解析 purge 接口返回，输出 "status|throttled|reset|providers"
parse_fields() {
  python3 -c '
import json, sys
try:
    d = json.loads(sys.stdin.read())
except Exception:
    print("parse_error||||")
    sys.exit(0)
paths = d.get("paths") or {}
entry = next(iter(paths.values()), {}) if paths else {}
providers = ",".join(sorted(k for k, v in (entry.get("providers") or {}).items() if v))
print("|".join([
    str(d.get("status", "")),
    str(entry.get("throttled", "")),
    str(entry.get("throttlingReset", "")),
    providers,
]))
'
}

log "仓库：${SLUG}   引用：${REF}"
log "目标：${FILES[*]}"
log "UA：${UA}"

# jsDelivr 从 GitHub 拉取，push 后稍等片刻再刷新更稳妥
if [ "$PURGE_GRACE" -gt 0 ]; then
  log "等待 ${PURGE_GRACE}s 让 GitHub 侧同步…"
  sleep "$PURGE_GRACE"
fi

TMP="$(mktemp "${TMPDIR:-/tmp}/purge.XXXXXX")"
trap 'rm -f "$TMP"' EXIT

PURGED=()
THROTTLED=()
FAILED=()

for f in "${FILES[@]}"; do
  url="https://purge.jsdelivr.net/gh/${SLUG}@${REF}/${f}"
  log "刷新：${url}"

  outcome=""
  for attempt in $(seq 1 "$PURGE_RETRIES"); do
    code="$(curl -sS -A "$UA" --max-time 30 -o "$TMP" -w '%{http_code}' "$url" 2>/dev/null || echo 000)"

    if [ "$code" = "200" ]; then
      IFS='|' read -r status throttled reset providers < <(parse_fields < "$TMP")
      if [ "$status" = "finished" ]; then
        if [ "$throttled" = "True" ]; then
          warn "${f}：已被 jsDelivr 限流，约 ${reset}s 后才会再次放行"
          warn "  （说明该路径近期刚刷新过，缓存已是新的，本次无需重复刷新）"
          outcome="throttled"
        else
          log "  ✓ 刷新成功 (providers: ${providers:-无})"
          outcome="purged"
        fi
        break
      fi
      warn "  ${f}：接口返回 status=${status}（第 ${attempt} 次）"
    else
      warn "  ${f}：HTTP ${code}（第 ${attempt} 次）"
    fi

    if [ "$attempt" -lt "$PURGE_RETRIES" ]; then
      sleep $(( attempt * 5 ))
    fi
  done

  case "$outcome" in
    purged)    PURGED+=("$f") ;;
    throttled) THROTTLED+=("$f") ;;
    *)         FAILED+=("$f") ;;
  esac
done

# ---------------------------------------------------------------- 汇总
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "## jsDelivr 缓存刷新"
    echo ""
    echo "| 文件 | 结果 |"
    echo "| --- | --- |"
    for f in "${PURGED[@]:-}";    do [ -n "$f" ] && echo "| \`${f}\` | ✅ 已刷新 |"; done
    for f in "${THROTTLED[@]:-}"; do [ -n "$f" ] && echo "| \`${f}\` | ⏳ 被限流（近期已刷新过） |"; done
    for f in "${FAILED[@]:-}";    do [ -n "$f" ] && echo "| \`${f}\` | ❌ 刷新失败 |"; done
    echo ""
    echo "刷新地址示例：\`https://purge.jsdelivr.net/gh/${SLUG}@${REF}/<文件>\`"
  } >> "$GITHUB_STEP_SUMMARY"
fi

log "结果：已刷新 ${#PURGED[@]} 个，限流 ${#THROTTLED[@]} 个，失败 ${#FAILED[@]} 个"

if [ "${#FAILED[@]}" -gt 0 ]; then
  die "以下文件刷新失败：${FAILED[*]}"
fi

log "完成"
