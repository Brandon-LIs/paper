#!/usr/bin/env bash
#
# 抓取 Bing 每日壁纸并转为 WebP
#
#   1. 归档到  wallpapers/YYYY/MM/YYYYMMDD.webp   （全分辨率）
#   2. 根目录 paper.webp  最新一张，全分辨率
#   3. 根目录 lite.webp   最新一张的轻量版，缩放 + 更高压缩，适合网页加载
#
# 时区统一使用北京时间（Asia/Shanghai），保证“当日”的判定与国内一致：
#   工作流在 UTC 16:30 触发 = 北京时间次日 00:30，若按 UTC 取日期会差一天。
#
# 环境变量（均可选）：
#   BING_MKT         市场，默认 zh-CN（跟随中国区 Bing 的当日图）
#   BING_RESOLUTION  源图分辨率，默认 UHD（4K），失败自动回退 1920x1080
#   WALLPAPER_DIR    归档目录，默认 wallpapers
#   PAPER_FILE       全分辨率文件名，默认 paper.webp
#   LITE_FILE        轻量版文件名，默认 lite.webp
#   WP_QUALITY       paper 的 WebP 质量，默认 80
#   LITE_QUALITY     lite 的 WebP 质量，默认 75
#   LITE_WIDTH       lite 的缩放宽度，默认 1920（设为 0 表示不缩放）
#   GITHUB_OUTPUT    由 Actions 注入，用于回传 changed=true/false

set -euo pipefail

MKT="${BING_MKT:-zh-CN}"
RESOLUTION="${BING_RESOLUTION:-UHD}"
WALLPAPER_DIR="${WALLPAPER_DIR:-wallpapers}"
PAPER_FILE="${PAPER_FILE:-paper.webp}"
LITE_FILE="${LITE_FILE:-lite.webp}"
WP_QUALITY="${WP_QUALITY:-80}"
LITE_QUALITY="${LITE_QUALITY:-75}"
LITE_WIDTH="${LITE_WIDTH:-1920}"

# 固定北京时间：本项目的「当日」定义即为北京时间当天，不随运行环境漂移
export TZ="Asia/Shanghai"

API_URL="https://www.bing.com/HPImageArchive.aspx?format=js&idx=0&n=1&mkt=${MKT}"

log() { printf '[bing-wallpaper] %s\n' "$*"; }
warn() { printf '[bing-wallpaper] 警告：%s\n' "$*" >&2; }
die() { printf '[bing-wallpaper] 错误：%s\n' "$*" >&2; exit 1; }

# 字节数 -> 人类可读
human() {
  awk -v b="$1" 'BEGIN{
    split("B KB MB GB", u, " ");
    i = 1;
    while (b >= 1024 && i < 4) { b /= 1024; i++ }
    printf (i == 1 ? "%d %s" : "%.1f %s"), b, u[i];
  }'
}

# ---------------------------------------------------------------- JSON 取值
# 优先使用 jq；没有 jq 时回退到 python3，便于本地调试。
json_get() {
  local json="$1" expr="$2"   # expr 形如 images[0].url
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$json" | jq -r ".$expr // empty"
  else
    printf '%s' "$json" | python3 -c '
import json, re, sys
data = json.load(sys.stdin)
for key in sys.argv[1].split("."):
    m = re.match(r"(\w+)\[(\d+)\]$", key)
    if m:
        data = data[m.group(1)][int(m.group(2))]
    else:
        data = data[key]
print("" if data is None else data)
' "$expr"
  fi
}

# ---------------------------------------------------------------- 转换工具探测
# 优先 cwebp（libwebp 官方工具，参数最可控）；回退 ImageMagick。
CONVERTER=""
if command -v cwebp >/dev/null 2>&1; then
  CONVERTER="cwebp"
elif command -v magick >/dev/null 2>&1; then
  CONVERTER="magick"
elif command -v convert >/dev/null 2>&1; then
  CONVERTER="convert"
fi
if [ -z "$CONVERTER" ]; then
  die "未找到 WebP 转换工具。Ubuntu: apt-get install -y webp；macOS: brew install webp"
fi
log "转换工具：${CONVERTER}"

# 转 WebP，并校验容器头 RIFF....WEBP
#   $1=输入  $2=输出  $3=质量  $4=缩放宽度（0 表示保持原尺寸）
to_webp() {
  local in="$1" out="$2" quality="$3" width="${4:-0}"

  if [ "$CONVERTER" = "cwebp" ]; then
    local args=(-q "$quality" -m 6 -mt)
    if [ "$width" -gt 0 ] 2>/dev/null; then
      args+=(-resize "$width" 0)
    fi
    # 保留 ICC 色彩描述文件，避免广色域图在浏览器中偏色
    args+=(-metadata icc -o "$out" "$in")
    if ! cwebp "${args[@]}" >/dev/null 2>&1; then
      return 1
    fi
  else
    # ImageMagick：-resize 是操作符，必须排在输入文件之后
    local im=(-quiet "$in")
    if [ "$width" -gt 0 ] 2>/dev/null; then
      im+=(-resize "${width}x")
    fi
    im+=(-quality "$quality" "$out")
    if ! "$CONVERTER" "${im[@]}" >/dev/null 2>&1; then
      return 1
    fi
  fi

  if [ ! -s "$out" ]; then
    return 1
  fi
  local riff webp
  riff="$(od -An -tx1 -N4 "$out" | tr -d ' \n')"
  webp="$(od -An -tx1 -j8 -N4 "$out" | tr -d ' \n')"
  if [ "$riff" != "52494646" ] || [ "$webp" != "57454250" ]; then
    rm -f "$out"
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------- 取接口数据
log "请求 Bing 接口：${API_URL}"
JSON="$(curl -fsSL --retry 3 --retry-delay 5 --max-time 30 "${API_URL}")"

IMG_PATH="$(json_get "$JSON" 'images[0].url')"
IMG_ENDDATE="$(json_get "$JSON" 'images[0].enddate')"
IMG_COPYRIGHT="$(json_get "$JSON" 'images[0].copyright')"
IMG_TITLE="$(json_get "$JSON" 'images[0].title')"

if [ -z "$IMG_PATH" ]; then
  die "接口未返回图片地址"
fi

# ---------------------------------------------------------------- 确定日期
# 以 Bing 返回的 enddate 为“当日”的权威来源（zh-CN 市场即北京时间当天），
# 拿不到时退回北京时间当天的日期。
if printf '%s' "$IMG_ENDDATE" | grep -Eq '^[0-9]{8}$'; then
  DATE_STR="$IMG_ENDDATE"
else
  DATE_STR="$(date +%Y%m%d)"
  warn "未取到 enddate，改用北京时间当天日期 ${DATE_STR}"
fi
YEAR="${DATE_STR:0:4}"
MONTH="${DATE_STR:4:2}"

TARGET_DIR="${WALLPAPER_DIR}/${YEAR}/${MONTH}"
TARGET_FILE="${TARGET_DIR}/${DATE_STR}.webp"

log "壁纸日期：${YEAR}/${MONTH}/${DATE_STR}"
log "标题：${IMG_TITLE:-（无）}"
log "版权：${IMG_COPYRIGHT:-（无）}"

# ---------------------------------------------------------------- 下载源图
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/bing-wallpaper.XXXXXX")"
trap 'rm -rf "$WORK_DIR"' EXIT

SRC_JPG="${WORK_DIR}/source.jpg"
TMP_PAPER="${WORK_DIR}/paper.webp"
TMP_LITE="${WORK_DIR}/lite.webp"

download() { # $1 = 完整 URL
  log "下载：$1"
  curl -fsSL --retry 3 --retry-delay 5 --max-time 180 -o "$SRC_JPG" "$1"
}

# Bing 的图片路径形如 /th?id=OHR.XXX_1920x1080.jpg&rf=...&pid=hp
# 把尺寸段换成 UHD 即可拿到 4K 原图；失败则回退到默认 1920x1080。
UHD_PATH="${IMG_PATH/1920x1080/$RESOLUTION}"
if ! download "https://www.bing.com${UHD_PATH}"; then
  warn "${RESOLUTION} 下载失败，回退 1920x1080"
  download "https://www.bing.com${IMG_PATH}"
fi

# ---------------------------------------------------------------- 源图校验
if [ ! -s "$SRC_JPG" ]; then
  die "下载结果为空"
fi
SRC_MAGIC="$(od -An -tx1 -N3 "$SRC_JPG" | tr -d ' \n')"
if [ "$SRC_MAGIC" != "ffd8ff" ]; then
  die "下载内容不是 JPG（魔数 ${SRC_MAGIC}）"
fi

SRC_KB=$(( $(wc -c < "$SRC_JPG") / 1024 ))
if [ "$SRC_KB" -lt 10 ]; then
  die "源图体积异常（${SRC_KB} KB），疑似占位图"
fi
log "源图校验通过：$(human $((SRC_KB * 1024))) JPG"

# ---------------------------------------------------------------- 转 WebP
log "转 WebP：paper（全分辨率, q=${WP_QUALITY}）"
if ! to_webp "$SRC_JPG" "$TMP_PAPER" "$WP_QUALITY" 0; then
  die "paper WebP 转换失败（工具：${CONVERTER}）"
fi

log "转 WebP：lite（宽度 ${LITE_WIDTH}px, q=${LITE_QUALITY}）"
if ! to_webp "$SRC_JPG" "$TMP_LITE" "$LITE_QUALITY" "$LITE_WIDTH"; then
  die "lite WebP 转换失败（工具：${CONVERTER}）"
fi

PAPER_BYTES=$(wc -c < "$TMP_PAPER")
LITE_BYTES=$(wc -c < "$TMP_LITE")
log "paper.webp = $(human "$PAPER_BYTES")   lite.webp = $(human "$LITE_BYTES")"
if [ "$LITE_BYTES" -ge "$PAPER_BYTES" ]; then
  warn "lite 体积未小于 paper，请检查 LITE_WIDTH / LITE_QUALITY 设置"
fi

# ---------------------------------------------------------------- 落盘
# md5 在 GNU/BSD 上命令名不同，统一封装
md5_of() {
  if command -v md5sum >/dev/null 2>&1; then
    md5sum "$1" | awk '{print $1}'
  else
    md5 -q "$1"
  fi
}

# 内容一致就不重复写入；结果写入 PLACE_RESULT（update / skip）
# 注意：不要用 stdout 回传，否则 log 输出会被命令替换一并吞掉。
PLACE_RESULT=""
place() {
  local src="$1" dst="$2"
  if [ -f "$dst" ] && [ "$(md5_of "$src")" = "$(md5_of "$dst")" ]; then
    log "内容一致，跳过：${dst}"
    PLACE_RESULT="skip"
    return 0
  fi
  mkdir -p "$(dirname "$dst")"
  cp "$src" "$dst"
  log "已写入：${dst} ($(human "$(wc -c < "$dst")"))"
  PLACE_RESULT="update"
  return 0
}

CHANGED="false"

# 1) 归档到 wallpapers/YYYY/MM/
place "$TMP_PAPER" "$TARGET_FILE"
if [ "$PLACE_RESULT" = "update" ]; then
  CHANGED="true"
fi

# 2) 根目录 paper.webp —— 当日全分辨率
place "$TMP_PAPER" "$PAPER_FILE"
if [ "$PLACE_RESULT" = "update" ]; then
  CHANGED="true"
fi

# 3) 根目录 lite.webp —— 当日轻量版
place "$TMP_LITE" "$LITE_FILE"
if [ "$PLACE_RESULT" = "update" ]; then
  CHANGED="true"
fi

# ---------------------------------------------------------------- 回传结果
if [ -n "${GITHUB_OUTPUT:-}" ]; then
  {
    echo "changed=${CHANGED}"
    echo "date=${DATE_STR}"
    echo "year=${YEAR}"
    echo "month=${MONTH}"
    echo "path=${TARGET_FILE}"
    echo "paper_bytes=${PAPER_BYTES}"
    echo "lite_bytes=${LITE_BYTES}"
    echo "paper_size=$(human "$PAPER_BYTES")"
    echo "lite_size=$(human "$LITE_BYTES")"
    echo "title=${IMG_TITLE}"
    echo "copyright=${IMG_COPYRIGHT}"
  } >> "$GITHUB_OUTPUT"
fi

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "## Bing 每日壁纸 ${YEAR}/${MONTH}/${DATE_STR}"
    echo ""
    echo "| 文件 | 大小 |"
    echo "| --- | --- |"
    echo "| \`${TARGET_FILE}\`（归档） | $(human "$PAPER_BYTES") |"
    echo "| \`${PAPER_FILE}\`（全分辨率） | $(human "$PAPER_BYTES") |"
    echo "| \`${LITE_FILE}\`（${LITE_WIDTH}px 轻量版） | $(human "$LITE_BYTES") |"
    echo ""
    echo "- 源图：$(human $((SRC_KB * 1024))) JPG → WebP"
    echo "- 变更：\`${CHANGED}\`"
    if [ -n "$IMG_TITLE" ]; then echo "- 标题：${IMG_TITLE}"; fi
    if [ -n "$IMG_COPYRIGHT" ]; then echo "- 版权：${IMG_COPYRIGHT}"; fi
  } >> "$GITHUB_STEP_SUMMARY"
fi

log "完成（changed=${CHANGED}）"
