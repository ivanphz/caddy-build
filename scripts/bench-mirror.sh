#!/usr/bin/env bash
#
# 镜像链路测速：在任意机器上跑，测出这台机器做中转值不值。
#
# 用法：
#   ./bench-mirror.sh dl    ivanphz/caddy-build                 # GitHub 下载速度
#   ./bench-mirror.sh gitee ivanabc/caddy-build "$GITEE_TOKEN"  # Gitee 上传速度
#   ./bench-mirror.sh cnb   ivanabc/caddy-build "$CNB_TOKEN"    # CNB 上传速度
#   ./bench-mirror.sh all   ...                                 # 见下方 all 用法
#   ./bench-mirror.sh purge gitee ivanabc/caddy-build "$TOKEN"  # 清理遗留的 bench-* release
#
# 环境变量：
#   SIZE_MB=20            测试文件大小，默认 20（正式产物约 72M，按比例外推即可）
#   PROXY=socks5h://...   走代理测（curl --proxy 语法，http/https/socks5h 均可）
#   KEEP=1                测完不删除测试 release（默认删）
#   INTERVAL=3            进度打印间隔秒数，默认 3
#   BRANCH=main           建测试 release 用的分支，留空自动探测
#
# 依赖：curl、jq。
#
# 测试 release 会在退出时删除，Ctrl-C / 被 kill / 中途报错也会删 —— 否则每中断
# 一次就在 Gitee 上留下一个带 20MB 附件的 bench-* release，一直占着 1GB 附件配额。
# 万一还是漏了（比如机器直接断电），用 purge 子命令一次性扫掉。
#
set -euo pipefail

SIZE_MB="${SIZE_MB:-20}"
PROXY="${PROXY:-}"
KEEP="${KEEP:-0}"
STAMP="$(date +%Y%m%d-%H%M%S)"
TESTTAG="bench-${STAMP}"
TMPD="$(mktemp -d)"

c()  { printf '\033[%sm%s\033[0m\n' "$1" "$2"; }
ok() { c 32 "$*"; }
wr() { c 33 "$*"; }
er() { c 31 "$*" >&2; }
die(){ er "错误: $*"; exit 1; }

INTERVAL="${INTERVAL:-3}"

# 控制类请求：静默
CURL=(curl -sS --connect-timeout 20 --max-time 120)
# 传输类请求：【不带 -s】—— -s 会把 curl 的进度表整个关掉。
# 单用 -S 保留报错，进度表走 stderr，由 progress_watch 节流后打印。
# --speed-limit/--speed-time: 平均速率低于 1KB/s 持续 60 秒就放弃。
# 没有这个的话，链路卡死时会一直挂到 --max-time（30 分钟）才退出。
XFER=(curl -S --connect-timeout 20 --speed-limit 1024 --speed-time 60)
[ -n "$PROXY" ] && { CURL+=(--proxy "$PROXY"); XFER+=(--proxy "$PROXY"); }

# ---------------------------------------------------------------- 清理
# 建完测试 release 就登记，退出时（含 Ctrl-C）无条件删除。
# 旧版把 DELETE 写在每个 bench_* 函数末尾，只要中途退出就删不掉 ——
# 慢链路上手动 Ctrl-C 恰恰是最常见的路径。

CLEAN_PLATFORM=""; CLEAN_API=""; CLEAN_ID=""; CLEAN_TOKEN=""

release_delete() {   # $1=平台 $2=api $3=id $4=token
  case "$1" in
    gitee) "${CURL[@]}" -o /dev/null -X DELETE "${2}/releases/${3}" \
             -H "Authorization: token ${4}" ;;
    cnb)   "${CURL[@]}" -o /dev/null -X DELETE "${2}/${3}" \
             -H "Authorization: Bearer ${4}" -H 'Accept: application/json' ;;
    *)     return 1 ;;
  esac
}

cleanup() {
  if [ -n "$CLEAN_ID" ]; then
    if [ "$KEEP" = 1 ]; then
      wr "  已保留测试 release ${TESTTAG} (id=${CLEAN_ID})，用完请手动删除"
    else
      echo "  清理测试 release ${TESTTAG} (id=${CLEAN_ID}) …" >&2
      release_delete "$CLEAN_PLATFORM" "$CLEAN_API" "$CLEAN_ID" "$CLEAN_TOKEN" \
        || er "  ! 删除失败，请手动删除 ${TESTTAG}（它会一直占着附件配额）"
    fi
    CLEAN_ID=""
  fi
  rm -rf "$TMPD"
}
trap cleanup EXIT
# INT/TERM/HUP 里 exit 会接着触发上面的 EXIT trap，清理逻辑只写一份
trap 'er "已中断"; exit 130' INT TERM HUP

# 注意：输出必须走 stderr。xfer 用 stdout 回传 "http|秒|速率"，而 xfer 本身
# 是在 $(...) 里被调用的 —— 进度若打到 stdout，会连同统计一起被捕获进变量：
# 终端一行都看不到，且 IFS='|' read 读到的第一行变成进度文本，统计全废。
# （这不是 curl 的问题；curl 在 stderr 重定向到文件时照常输出进度表。）
progress_watch() {   # $1=stderr文件 $2=间隔秒；输出到 stderr
  local last="" line iv=2   # 首次 2 秒就出一行，之后按间隔
  while :; do
    sleep "$iv"; iv="$2"
    [ -s "$1" ] || continue
    line="$(tr '\r' '\n' < "$1" | awk 'NF>=12 && $1 ~ /^[0-9]+$/' | tail -n1)"
    { [ -z "$line" ] || [ "$line" = "$last" ]; } && continue
    last="$line"
    # 字段: 5=已传% 6=已传量 2=总量 12=当前速度 11=剩余时间
    printf '%s\n' "$line" \
      | awk '{printf "    %s%%  %s/%s   当前 %s/s   剩余 %s\n", $5, $6, $2, $12, $11}' >&2
  done
}

# 带进度地跑一次传输，回显 "http|秒|速率"
xfer() {
  local errf pid stat
  errf="$(mktemp -p "$TMPD")"
  progress_watch "$errf" "$INTERVAL" & pid=$!
  stat="$("${XFER[@]}" "$@" 2>"$errf")" || stat=""
  # kill 后 wait 一个被 SIGTERM 杀掉的任务返回 143。这里恰好在 $(...) 里，
  # bash 默认不把 errexit 带进命令替换（需要 shopt -s inherit_errexit），
  # 所以裸写没炸 —— 但这是巧合不是设计。补上 || true，换个调用位置也不会塌。
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  if [ -z "$stat" ]; then
    er "  传输中断（超时 / 失速 / 网络错误）:"
    tr '\r' '\n' < "$errf" | grep -v '^[[:space:]]*$' | tail -3 | sed 's/^/    /' >&2
  fi
  rm -f "$errf"
  printf '%s' "${stat:-0|0|0}"
}

need() { command -v "$1" >/dev/null || die "需要 $1"; }
need curl; need jq

# 人类可读速率 + 按 72MB 外推
report() {  # $1=标签 $2=字节数 $3=秒 $4=速率(B/s)
  local kbs mbs est
  kbs="$(awk -v s="$4" 'BEGIN{printf "%.0f", s/1024}')"
  mbs="$(awk -v s="$4" 'BEGIN{printf "%.2f", s/1048576}')"
  est="$(awk -v s="$4" 'BEGIN{ if(s<1){print "N/A"} else {printf "%.1f 分钟", 72*1048576/s/60} }')"
  printf '  %-22s %8s KB/s (%s MB/s)   用时 %ss   →  72MB 约需 %s\n' \
         "$1" "$kbs" "$mbs" "$3" "$est"
}

mkfile() {
  # 用随机数据，避免中间环节压缩造成虚高
  head -c "$((SIZE_MB * 1024 * 1024))" /dev/urandom > "$TMPD/blob.bin"
  echo "  测试文件: ${SIZE_MB} MB (随机数据，防压缩虚高)"
}

# ---------------------------------------------------------------- GitHub 下载

bench_dl() {
  local repo="$1" tag url
  echo; c 36 "== GitHub 下载 ($repo) =="
  tag="$("${CURL[@]}" -I -o /dev/null -w '%{url_effective}' -L \
        "https://github.com/${repo}/releases/latest")" || die "解析 latest 失败"
  case "$tag" in
    */tag/*) ;;
    *) die "从 ${tag} 解析不出 tag（代理可能改写了跳转）" ;;
  esac
  tag="${tag##*/tag/}"
  url="https://github.com/${repo}/releases/download/${tag}/caddy-linux-amd64"
  echo "  版本: $tag"
  local stat; stat="$(xfer -L -o /dev/null \
      -w '%{size_download}|%{time_total}|%{speed_download}' "$url")"
  IFS='|' read -r SZ T SP <<< "$stat"
  report "GitHub → 本机" "$SZ" "$T" "$SP"
}

# ---------------------------------------------------------------- Gitee 上传

bench_gitee() {
  local repo="$1" token="$2"
  local api="https://gitee.com/api/v5/repos/${repo}"
  local hdr="Authorization: token ${token}"
  echo; c 36 "== Gitee 上传 ($repo) =="
  mkfile

  local br rid resp
  br="${BRANCH:-$("${CURL[@]}" "${api}" -H "$hdr" | jq -r '.default_branch // "master"')}"
  resp="$("${CURL[@]}" -X POST "${api}/releases" -H "$hdr" \
         -H 'Content-Type: application/json' \
         -d "$(jq -n --arg t "$TESTTAG" --arg c "$br" \
               '{tag_name:$t,name:$t,body:"bench",target_commitish:$c}')")"
  rid="$(echo "$resp" | jq -r '.id // empty')"
  # 打印服务端原话，而不是替它猜原因
  [ -n "$rid" ] || die "创建测试 release 失败，服务端返回: $(echo "$resp" | head -c 400)"
  # 登记给 cleanup —— 必须紧跟创建，中间任何一步中断都能删掉
  CLEAN_PLATFORM=gitee; CLEAN_API="$api"; CLEAN_ID="$rid"; CLEAN_TOKEN="$token"
  echo "  测试 release id=$rid (分支 $br)"

  local stat
  stat="$(xfer --max-time 1800 -o "$TMPD/resp.json" \
         -w '%{size_upload}|%{time_total}|%{speed_upload}' \
         -X POST "${api}/releases/${rid}/attach_files" -H "$hdr" \
         -F "file=@$TMPD/blob.bin")"
  IFS='|' read -r SZ T SP <<< "$stat"
  jq -e '.id' "$TMPD/resp.json" >/dev/null 2>&1 \
    || wr "  响应异常: $(head -c 200 "$TMPD/resp.json")"
  report "本机 → Gitee" "$SZ" "$T" "$SP"
}

# ---------------------------------------------------------------- CNB 上传

bench_cnb() {
  local repo="$1" token="$2"
  local api="https://api.cnb.cool/${repo}/-/releases"
  local auth="Authorization: Bearer ${token}"
  local acc='Accept: application/json'   # 不带这个 CNB 回 406
  echo; c 36 "== CNB 上传 ($repo) =="
  mkfile

  local rid resp br
  # target_commitish 不能省：tag 尚不存在时，服务端需要知道打在哪个提交上。
  #
  # 末尾的 || true 不能省：set -e 下，命令替换失败会让整条赋值失败进而终止脚本，
  # 而 2>/dev/null 又把原因吞了 —— 表现为「打印完测试文件大小就无声退出」。
  # 触发条件：机器没装 git，或 cnb.cool 的 git 端口不通。
  br="${BRANCH:-}"
  if [ -z "$br" ] && command -v git >/dev/null 2>&1; then
    br="$(git ls-remote --symref "https://cnb.cool/${repo}.git" HEAD 2>/dev/null \
          | awk '/^ref:/{sub("refs/heads/","",$2); print $2; exit}' || true)"
  fi
  br="${br:-main}"
  echo "  目标分支: $br（可用 BRANCH= 覆盖）"
  resp="$("${CURL[@]}" -X POST "$api" -H "$auth" -H "$acc" \
         -H 'Content-Type: application/json' \
         -d "$(jq -n --arg t "$TESTTAG" --arg c "$br" \
               '{tag_name:$t,name:$t,body:"bench",target_commitish:$c,make_latest:"false"}')")"
  rid="$(echo "$resp" | jq -r '.id // empty')"
  [ -n "$rid" ] || die "创建测试 release 失败，服务端返回: $(echo "$resp" | head -c 400)"
  CLEAN_PLATFORM=cnb; CLEAN_API="$api"; CLEAN_ID="$rid"; CLEAN_TOKEN="$token"
  echo "  测试 release id=$rid"

  local u up vf size
  size="$(stat -c%s "$TMPD/blob.bin" 2>/dev/null || stat -f%z "$TMPD/blob.bin")"
  u="$("${CURL[@]}" -X POST "${api}/${rid}/asset-upload-url" -H "$auth" -H "$acc" \
      -H 'Content-Type: application/json' \
      -d "$(jq -n --arg n "blob.bin" --argjson s "$size" \
            '{asset_name:$n,size:$s,overwrite:true,ttl:0}')")"
  up="$(echo "$u" | jq -r '.upload_url // empty')"
  vf="$(echo "$u" | jq -r '.verify_url // empty')"
  [ -n "$up" ] || die "取上传地址失败: $(echo "$u" | head -c 300)"

  # 注意：预签名 URL 不能带 Authorization，会破坏签名
  local stat
  stat="$(xfer --max-time 1800 -o /dev/null \
         -w '%{size_upload}|%{time_total}|%{speed_upload}' \
         -X PUT "$up" --upload-file "$TMPD/blob.bin")"
  IFS='|' read -r SZ T SP <<< "$stat"
  report "本机 → CNB" "$SZ" "$T" "$SP"

  local tail_ tok path
  tail_="${vf#*/asset-upload-confirmation/}"; tok="${tail_%%/*}"; path="${tail_#*/}"
  "${CURL[@]}" -o /dev/null -X POST \
    "${api}/${rid}/asset-upload-confirmation/${tok}/${path}?ttl=0" -H "$auth" -H "$acc" || true
}

# ---------------------------------------------------------------- 清理遗留

purge() {   # $1=平台 $2=owner/repo $3=token
  local plat="$1" repo="$2" token="$3" api list
  echo; c 36 "== 清理 ${plat} 上遗留的 bench-* 测试 release ($repo) =="
  case "$plat" in
    gitee)
      api="https://gitee.com/api/v5/repos/${repo}"
      list="$("${CURL[@]}" "${api}/releases?page=1&per_page=100" \
              -H "Authorization: token ${token}")" ;;
    cnb)
      api="https://api.cnb.cool/${repo}/-/releases"
      list="$("${CURL[@]}" "${api}?page=1&page_size=100" \
              -H "Authorization: Bearer ${token}" -H 'Accept: application/json')" ;;
    *) die "purge 只支持 gitee / cnb" ;;
  esac

  local n=0 id tag
  while IFS=$'\t' read -r id tag; do
    [ -n "$id" ] || continue
    echo "  删除 $tag (id=$id)"
    release_delete "$plat" "$api" "$id" "$token" || wr "    删除失败"
    n=$((n + 1))
  done < <(printf '%s' "$list" \
           | jq -r '.[] | select(.tag_name | startswith("bench-")) | "\(.id)\t\(.tag_name)"')
  echo "  共清理 ${n} 个"
}

# ---------------------------------------------------------------- 入口

echo "机器: $(uname -s) $(uname -m)   出口 IP: $("${CURL[@]}" -s --max-time 10 https://api.ipify.org 2>/dev/null || echo '未知')"
[ -n "$PROXY" ] && echo "代理: $PROXY"

case "${1:-}" in
  dl)    bench_dl "${2:?用法: $0 dl <github owner/repo>}" ;;
  gitee) bench_gitee "${2:?缺少 owner/repo}" "${3:?缺少 token}" ;;
  cnb)   bench_cnb "${2:?缺少 owner/repo}" "${3:?缺少 token}" ;;
  purge) purge "${2:?用法: $0 purge <gitee|cnb> <owner/repo> <token>}" \
               "${3:?缺少 owner/repo}" "${4:?缺少 token}"; exit 0 ;;
  all)
    # 用法: ./bench-mirror.sh all <gh_repo> <cn_repo> <gitee_token> <cnb_token>
    bench_dl "${2:?}"; bench_gitee "${3:?}" "${4:?}"
    cleanup                       # 先删掉 Gitee 那个，再登记 CNB 的
    bench_cnb "${3}" "${5:?}"
    ;;
  *)
    sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'
    exit 1 ;;
esac

echo
ok "完成。判断标准："
echo "  上行 > 1 MB/s   →  这台机器适合做中转（72MB 约 1 分钟）"
echo "  上行 300~800 KB/s →  能用，单文件 2~4 分钟"
echo "  上行 < 150 KB/s →  不可用，换机器"
