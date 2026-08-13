#!/usr/bin/env bash
#
# 分发的【平台无关】逻辑。由 .github/workflows/mirror.yml 的各平台步骤
# `source` 之后调用 mirror_run。
#
# 为什么单独成文件：Gitee / CNB / 以后可能加的任何平台，差异只在「怎么调 API」，
# 而「先查 release 是否齐全 → 齐全就跳过上传 / 不齐就删了重传 → 写清单 → 推仓库
# → 按 GitHub 保留策略清理」这一整套流程是完全一样的。写两遍就一定会走偏。
#
# ============================================================================
# 适配器契约
# ============================================================================
# 调用 mirror_run 前，平台步骤必须先赋值以下【变量】：
#
#   PLATFORM_NAME            显示名，如 Gitee
#   PLATFORM_REMOTE          带凭据的 git remote URL（用于推 README / install.sh / 清单）
#   PLATFORM_RAW_BASE        仓库文件基址模板，分支处写 {BRANCH} 占位
#                        例: https://gitee.com/owner/repo/raw/{BRANCH}
#   PLATFORM_BRANCH_VAR      显式指定分支用的仓库变量名（仅用于报错文案）
#   PLATFORM_DEFAULT_BRANCH  远端是空仓库时用哪个分支名建仓（Gitee=master / CNB=main）
#   PLATFORM_PUBLIC_URLS     1（默认）| 0
#                            0 表示这个平台没有可对外发布的访问地址：
#                            不生成清单、不渲染 README、日志和摘要里不回显任何地址。
#                            自建存储没配公开域名时用 —— 既能正常镜像产物，
#                            又不会把域名写进公开仓库的 Actions 日志。
#   PLATFORM_KIND            git（默认，仓库型平台）| object（对象存储，如 R2）
#                            object 型没有 git 仓库也没有 release API，
#                            必须自己实现 platform_sync_files；分支只是路径命名空间。
#   TAG                  本次要镜像的 tag
#   DL_DIR               已下载资产所在目录
#   WANT_ASSETS          本平台需要镜像的资产名，空格分隔
#   KEEP                 保留最近多少个 tag
#   GH_TAGS_FILE         GitHub 现存 tag 清单（新→旧，每行一个）
#   BODY_FILE            release 正文
#   REPO_ROOT            本仓库工作区根目录（Actions 里就是 $GITHUB_WORKSPACE）
#   BRANCH               可选，显式指定分支；留空则探测远端默认分支
#
# 以及以下【函数】。约定：
#   - 结果一律通过全局变量或文件回传，【不走 stdout】。
#     stdout 留给人看的日志 —— 混用会让 $(...) 把日志一起捕获进变量，
#     这类 bug 排查成本极高（本仓库 install.sh 的注释里已经栽过一次）。
#   - 任何失败都要返回非零，由上层统一 fail-loud，不做静默降级。
#
#   platform_release_find   <tag>                  → 置 RELEASE_ID（不存在则空串）
#   platform_release_assets <rid>                  → 写 $REMOTE_ASSETS_FILE
#                                                     每行 name<TAB>url<TAB>size
#                                                     size 未知时填 "-"
#   platform_release_delete <rid>
#   platform_release_create <tag> <bodyfile> <br>  → 置 RELEASE_ID
#   platform_upload_assets  <rid> <name...>        → 追加写 $ASSET_URL_FILE
#                                                     每行 name<TAB>url
#   platform_release_list                          → 写 $RELEASE_LIST_FILE
#                                                     每行 id<TAB>tag
#
# 两个【可选】钩子，不定义就用默认实现：
#
#   platform_sync_files  <full|bootstrap>   推 README / install.sh / manifest.txt
#                        默认 = git 提交推送。PLATFORM_KIND=object 时【必须】实现。
#   platform_fetch_asset <name> <url> <dst> 取回一个小文件用于校验
#                        默认 = curl。私有存储桶用自己的凭据取（如 aws s3 cp），
#                        免得为了做完整性校验被迫开公开读。
# ============================================================================

# ---- 输出 -------------------------------------------------------------------
# ::error:: / ::warning:: 必须顶格，Actions 才认

mlog()  { printf '  %s\n' "$*"; }
mstep() { printf '\n== %s ==\n' "$*"; }
mwarn() { printf '::warning::%s\n' "$*"; }
mdie()  { printf '::error::%s\n' "$*"; exit 1; }

# ---- 临时文件 ---------------------------------------------------------------

MIRROR_TMPD=""
REMOTE_ASSETS_FILE=""
RELEASE_LIST_FILE=""
ASSET_URL_FILE=""
MANIFEST_LOCAL=""
RELEASE_ID=""
MIRROR_BRANCH=""
RAW_BASE=""
MANIFEST_URL=""

# 清单在镜像仓库里的路径。install.sh 的 CADDY_MANIFEST 指向它。
MANIFEST_PATH="${MANIFEST_PATH:-manifest.txt}"

mirror_init() {
  MIRROR_TMPD="$(mktemp -d)"
  REMOTE_ASSETS_FILE="${MIRROR_TMPD}/remote_assets.tsv"
  RELEASE_LIST_FILE="${MIRROR_TMPD}/releases.tsv"
  ASSET_URL_FILE="${MIRROR_TMPD}/asset_urls.tsv"
  MANIFEST_LOCAL="${MIRROR_TMPD}/manifest.txt"
  : > "$REMOTE_ASSETS_FILE"
  : > "$RELEASE_LIST_FILE"
  : > "$ASSET_URL_FILE"
  trap 'rm -rf "$MIRROR_TMPD"' EXIT
}

# ---- 上传进度 ---------------------------------------------------------------
# curl 的进度表用 \r 覆盖同一行，直接进日志会刷屏，所以转成换行后节流取最后一条。
# curl 必须【不带 -s】—— -s 会把进度表整个关掉，单用 -S 保留报错输出即可。

progress_watch() {   # $1=curl的stderr文件 $2=间隔秒
  local last="" line
  while :; do
    sleep "$2"
    [ -s "$1" ] || continue
    line="$(tr '\r' '\n' < "$1" | awk 'NF>=12 && $1 ~ /^[0-9]+$/' | tail -n1)"
    { [ -z "$line" ] || [ "$line" = "$last" ]; } && continue
    last="$line"
    # 字段: 5=已传% 6=已传量 2=总量 12=当前速度 11=剩余时间
    printf '%s\n' "$line" \
      | awk '{printf "    %s%%  %s/%s   当前 %s/s   剩余 %s\n", $5, $6, $2, $12, $11}'
  done
}

# 启停必须封装。裸写 `kill $PID; wait $PID` 在 set -e 下会炸：
# wait 一个被 SIGTERM 杀掉的任务返回 143，set -e 据此终止整个脚本
#（表现为 step 退出码 143，且看不出任何原因）。
PROG_ERRF=""; PROG_PID=""
progress_start() {
  PROG_ERRF="$(mktemp -p "$MIRROR_TMPD")"
  progress_watch "$PROG_ERRF" "${PROGRESS_INTERVAL:-15}" &
  PROG_PID=$!
}
progress_stop() {
  [ -n "$PROG_PID" ] && kill "$PROG_PID" 2>/dev/null || true
  [ -n "$PROG_PID" ] && wait "$PROG_PID" 2>/dev/null || true
  PROG_PID=""
}
progress_tail() {
  [ -s "$PROG_ERRF" ] && tr '\r' '\n' < "$PROG_ERRF" \
    | grep -v '^[[:space:]]*$' | tail -2 || true
}

# ---- 分支 -------------------------------------------------------------------

# 结果写全局 MIRROR_BRANCH。
#
# 这里【不】无条件回落到 main：Gitee 建仓默认是 master，猜错的后果是把文件推到
# 一个谁也看不见的新分支上，而仓库首页仍显示 master 的旧内容，安装链接指向 404。
# 这正是上一版最主要的坑。
#
# 三种情况必须分开处理，混在一起就会把「网络不通」当成「仓库是空的」：
#   远端不可达        → 直接报错停下
#   远端为空（无引用）→ 用平台默认分支建仓（Gitee=master / CNB=main）
#   远端有引用无 HEAD → 报错，让人显式指定，不猜
resolve_branch() {
  # 对象存储没有 HEAD 可探测，"分支"只是仓库文件的路径命名空间，直接取值
  if [ "${PLATFORM_KIND:-git}" != git ]; then
    MIRROR_BRANCH="${BRANCH:-$PLATFORM_DEFAULT_BRANCH}"
    return 0
  fi

  local lsr="${MIRROR_TMPD}/lsremote.txt" err="${MIRROR_TMPD}/lsremote.err"
  local det refcount

  if ! git ls-remote --symref "$PLATFORM_REMOTE" > "$lsr" 2> "$err"; then
    mdie "${PLATFORM_NAME}: 无法访问远端仓库（仓库不存在 / 凭据无效 / 网络不通）: $(tr -d '\r' < "$err" | tail -2 | tr '\n' ' ')"
  fi

  det="$(awk '$1=="ref:" && $3=="HEAD"{sub("refs/heads/","",$2); print $2; exit}' "$lsr")"
  refcount="$(grep -c 'refs/' "$lsr" || true)"

  if [ -n "${BRANCH:-}" ]; then
    MIRROR_BRANCH="$BRANCH"
    if [ -n "$det" ] && [ "$det" != "$BRANCH" ]; then
      mwarn "${PLATFORM_NAME}: 指定分支 ${BRANCH} ≠ 远端默认分支 ${det}。仓库首页会显示 ${det} 的内容，而安装链接指向 ${BRANCH}，两者会长期不一致。"
    fi
    return 0
  fi

  if [ -n "$det" ]; then
    MIRROR_BRANCH="$det"
    return 0
  fi

  if [ "${refcount:-0}" -eq 0 ]; then
    MIRROR_BRANCH="$PLATFORM_DEFAULT_BRANCH"
    mlog "远端仓库为空，按平台默认建 ${MIRROR_BRANCH} 分支"
    return 0
  fi

  mdie "${PLATFORM_NAME}: 远端有 ${refcount} 个引用却读不到 HEAD 的符号引用，无法判断默认分支。请用仓库变量 ${PLATFORM_BRANCH_VAR} 显式指定。"
}

# ---- 资产完整性 -------------------------------------------------------------

local_size() { stat -c%s "$1"; }

# 取不到就返回空串（不报错）—— 不是所有平台都给 content-length
remote_size() {
  curl -fsIL --connect-timeout 20 --max-time 60 \
       -o /dev/null -w '%header{content-length}' "$1" 2>/dev/null \
    | tr -d ' \r' || true
}

manifest_url_of() { awk -F'\t' -v n="$1" '$1==n{print $2; exit}' "$ASSET_URL_FILE"; }

# 取回一个小文件做校验。默认走公开 HTTP；私有桶可实现 platform_fetch_asset
# 用自己的凭据取，不必为了这一步把存储开成公开读。
fetch_asset() {   # $1=名字 $2=url $3=落盘路径
  if declare -F platform_fetch_asset >/dev/null 2>&1; then
    platform_fetch_asset "$@"
    return
  fi
  curl -fsL --connect-timeout 20 --max-time 60 --retry 2 -o "$3" "$2"
}

# 判定「这个 release 的附件是否已经齐全且正确」。
# 齐全返回 0，并把每个资产的真实下载地址写进 $ASSET_URL_FILE（后面写清单要用）。
#
# 三层判定，从便宜到贵：
#   1. 文件名必须全在
#   2. 字节数必须与本地一致（优先用 API 给的 size，没有就 HEAD 取 content-length）
#   3. .sha256 只有几十字节，直接拉回来逐字节比对
#      —— 这一层能发现「同名 tag 下挂着上一次构建的二进制」，只比大小是发现不了的
assets_complete() {
  local rid="$1" name line url size want missing=0

  platform_release_assets "$rid" || { mlog "无法读取远端资产列表"; return 1; }
  : > "$ASSET_URL_FILE"

  for name in $WANT_ASSETS; do
    line="$(awk -F'\t' -v n="$name" '$1==n{print; exit}' "$REMOTE_ASSETS_FILE")"
    if [ -z "$line" ]; then
      mlog "✗ 缺少 ${name}"
      missing=1
      continue
    fi
    url="$(printf '%s' "$line" | cut -f2)"
    size="$(printf '%s' "$line" | cut -f3)"
    if [ -z "$url" ]; then
      mlog "✗ ${name} 没有下载地址"
      missing=1
      continue
    fi

    want="$(local_size "${DL_DIR}/${name}")"
    if [ -z "$size" ] || [ "$size" = "-" ]; then
      size="$(remote_size "$url")"
    fi

    if [ -z "$size" ]; then
      mwarn "${PLATFORM_NAME}: ${name} 取不到远端大小，仅按文件名判定为已存在"
    elif [ "$size" != "$want" ]; then
      mlog "✗ ${name} 大小不符（远端 ${size} / 本地 ${want}）"
      missing=1
      continue
    fi

    printf '%s\t%s\n' "$name" "$url" >> "$ASSET_URL_FILE"
    mlog "✓ ${name}"
  done

  [ "$missing" = 0 ] || return 1

  for name in $WANT_ASSETS; do
    case "$name" in *.sha256) ;; *) continue ;; esac
    url="$(manifest_url_of "$name")"
    if ! fetch_asset "$name" "$url" "${MIRROR_TMPD}/probe"; then
      mlog "✗ ${name} 拉取失败，判定为不完整"
      return 1
    fi
    if ! cmp -s "${MIRROR_TMPD}/probe" "${DL_DIR}/${name}"; then
      mlog "✗ ${name} 内容与本次构建不一致（同名 tag 挂着旧产物）"
      return 1
    fi
    mlog "✓ ${name} 内容比对通过"
  done

  return 0
}

# 按体积从小到大排。.sha256 只有几十字节，先传它能在 2 秒内验证端点，
# 而不是等一个 69MB 的上传挂十分钟才发现路径写错。
upload_order() {
  local n
  local -a paths=()
  for n in $WANT_ASSETS; do paths+=("${DL_DIR}/${n}"); done
  # 资产名是固定的 ASCII，不存在换行/空格文件名，用 ls 排序是安全的
  # shellcheck disable=SC2011
  ls -S -r "${paths[@]}" | xargs -n1 basename
}

# ---- 清单 -------------------------------------------------------------------
#
# 为什么要有清单：GitHub 的 release 资产可以按 基址/tag/文件名 拼出来，但这不是
# 通用形状 —— Gitee 的附件地址是 attach_files/{数字ID}/download/{名}，数字 ID
# 只有上传完才知道，从 tag 根本推不出来。清单把「文件名 → 真实地址」这层映射
# 固化成一个几百字节的文本文件推进镜像仓库，install.sh 的 CADDY_MANIFEST 直接查表。
#
# 好处是它对【任何】平台都成立：以后接新平台，只要适配器能报出真实下载地址，
# 安装侧一行都不用改。
write_manifest() {
  {
    printf 'tag\t%s\n' "$TAG"
    sort "$ASSET_URL_FILE"
  } > "$MANIFEST_LOCAL"
  mlog "清单: $(wc -l < "$MANIFEST_LOCAL") 行"
}

# ---- 推仓库 -----------------------------------------------------------------

render_readme() {
  sed -e "s|{{PLATFORM}}|${PLATFORM_NAME}|g" \
      -e "s|{{RAW_BASE}}|${RAW_BASE}|g" \
      -e "s|{{MANIFEST_URL}}|${MANIFEST_URL}|g" \
      -e "s|{{TAG}}|${TAG}|g" \
      -e "s|{{URL_AMD64}}|$(manifest_url_of caddy-linux-amd64)|g" \
      -e "s|{{URL_AMD64_SHA}}|$(manifest_url_of caddy-linux-amd64.sha256)|g" \
      -e "s|{{URL_ARM64}}|$(manifest_url_of caddy-linux-arm64)|g" \
      -e "s|{{URL_ARM64_SHA}}|$(manifest_url_of caddy-linux-arm64.sha256)|g" \
      "${REPO_ROOT}/mirror/README.md"
}

# $1=分支  $2=模式 full|bootstrap
sync_repo() {
  if declare -F platform_sync_files >/dev/null 2>&1; then
    platform_sync_files "${2:-full}"
    return
  fi
  [ "${PLATFORM_KIND:-git}" = git ] \
    || mdie "${PLATFORM_NAME}: PLATFORM_KIND=${PLATFORM_KIND} 必须自己实现 platform_sync_files"
  git_sync_repo "$@"
}

# 默认实现：git 提交推送。
# bootstrap 只在远端分支还不存在时跑一次：建 release 需要 target_commitish，
# 空仓库没有任何分支会直接失败。正常情况下每次镜像只产生一个提交。
git_sync_repo() {
  local br="$1" mode="${2:-full}" work
  work="$(mktemp -d)"
  (
    set -euo pipefail
    cd "$work"
    git init -q -b "$br"
    git config user.email 'actions@users.noreply.github.com'
    git config user.name  'mirror-bot'
    git remote add origin "$PLATFORM_REMOTE"
    # 已有内容就接着提交，保留历史；空仓库则从零开始
    if git fetch -q --depth 1 origin "$br" 2>/dev/null; then
      git reset -q --hard "origin/${br}"
    fi

    mkdir -p scripts
    cp "${REPO_ROOT}/scripts/install.sh" scripts/install.sh
    chmod 0755 scripts/install.sh

    if [ "$mode" = full ]; then
      cp "$MANIFEST_LOCAL" "$MANIFEST_PATH"
      render_readme > README.md
    else
      [ -f README.md ] || printf '# caddy-build\n\n镜像仓库初始化中，稍后由流水线覆盖。\n' > README.md
    fi

    git add -A
    if git diff --cached --quiet; then
      echo "  文件无变更，跳过推送"
    else
      git commit -qm "sync ${TAG}"
      git push -q origin "HEAD:${br}"
      echo "  ✓ 已推送 README.md / scripts/install.sh${MANIFEST_NOTE:-}"
    fi
  )
  rm -rf "$work"
}

ensure_branch() {
  # 对象存储没有"分支要先存在"这回事，前缀写进去就有了
  [ "${PLATFORM_KIND:-git}" = git ] || return 0
  if git ls-remote --exit-code --heads "$PLATFORM_REMOTE" "$1" >/dev/null 2>&1; then
    return 0
  fi
  mlog "远端分支 $1 不存在，先建立一个初始提交"
  sync_repo "$1" bootstrap
}

# ---- 保留策略 ---------------------------------------------------------------
#
# 不自己算保留策略 —— 直接以 GitHub 上还存在的 release 为准，两边永远一致，
# 也不用担心 tag 的字典序排不对（v2.9 vs v2.11），或者 CNB 那种超 2^53 的
# 雪花号 id 被 jq 按 double 排错。
prune_releases() {
  local keep_file id tag
  keep_file="${MIRROR_TMPD}/keep.txt"

  head -n "$KEEP" "$GH_TAGS_FILE" > "$keep_file"
  # 本次刚镜像的 tag 必须留住。手动镜像一个不在 GitHub 最新 KEEP 名单里的旧 tag 时，
  # 少了这一行会出现「刚传完 72MB 就被自己删掉」。
  printf '%s\n' "$TAG" >> "$keep_file"
  sort -u -o "$keep_file" "$keep_file"

  if [ ! -s "$keep_file" ]; then
    mwarn "${PLATFORM_NAME}: 保留清单为空，跳过清理（避免误删全部）"
    return 0
  fi

  platform_release_list || { mwarn "${PLATFORM_NAME}: 无法列出远端 release，跳过清理"; return 0; }

  while IFS=$'\t' read -r id tag; do
    [ -n "$id" ] || continue
    if grep -qxF "$tag" "$keep_file"; then
      continue
    fi
    mlog "删除 $tag (id=$id)"
    platform_release_delete "$id" || mwarn "${PLATFORM_NAME}: 删除 $tag 失败"
  done < "$RELEASE_LIST_FILE"
}

# ---- 主流程 -----------------------------------------------------------------

mirror_run() {
  local complete=0 name

  # 前置断言。正常情况下 workflow 的 step 条件已经挡住了「上游步骤失败」这条路，
  # 但真漏进来时，"TAG: unbound variable" 这种报错完全指不到真正的原因。
  [ -n "${TAG:-}" ] || mdie "${PLATFORM_NAME:-镜像}: TAG 为空 —— 上游 Resolve 步骤没有成功"
  [ -s "${GH_TAGS_FILE:-/nonexistent}" ] || mdie "${PLATFORM_NAME}: GitHub tag 清单缺失，保留策略没有基准"
  [ -d "${DL_DIR:-/nonexistent}" ] || mdie "${PLATFORM_NAME}: 资产目录 ${DL_DIR:-} 不存在"

  mirror_init

  mstep "${PLATFORM_NAME}"
  resolve_branch
  RAW_BASE="${PLATFORM_RAW_BASE//\{BRANCH\}/$MIRROR_BRANCH}"
  MANIFEST_URL="${RAW_BASE}/${MANIFEST_PATH}"
  mlog "目标分支:   ${MIRROR_BRANCH}"
  if [ "${PLATFORM_PUBLIC_URLS:-1}" = 1 ]; then
    mlog "仓库文件源: ${RAW_BASE}"
  else
    mlog "仓库文件源: （未配置公开访问地址，只上传产物，不发布清单）"
  fi
  mlog "镜像资产:   ${WANT_ASSETS}"

  ensure_branch "$MIRROR_BRANCH"

  RELEASE_ID=""
  platform_release_find "$TAG"
  if [ -n "$RELEASE_ID" ]; then
    mstep "${PLATFORM_NAME}: 已存在 ${TAG} (id=${RELEASE_ID})，检查资产完整性"
    if assets_complete "$RELEASE_ID"; then
      complete=1
      mlog "资产齐全，跳过上传"
    else
      mlog "资产不完整，删除后重传"
      platform_release_delete "$RELEASE_ID"
      RELEASE_ID=""
    fi
  fi

  if [ -z "$RELEASE_ID" ]; then
    mstep "${PLATFORM_NAME}: 创建 release"
    platform_release_create "$TAG" "$BODY_FILE" "$MIRROR_BRANCH"
    [ -n "$RELEASE_ID" ] || mdie "${PLATFORM_NAME}: 创建 release 失败"
    mlog "release_id=${RELEASE_ID}"
  fi

  if [ "$complete" != 1 ]; then
    mstep "${PLATFORM_NAME}: 上传附件"
    : > "$ASSET_URL_FILE"
    # shellcheck disable=SC2046
    platform_upload_assets "$RELEASE_ID" $(upload_order)

    for name in $WANT_ASSETS; do
      grep -q "^${name}"$'\t' "$ASSET_URL_FILE" \
        || mdie "${PLATFORM_NAME}: ${name} 上传后没有拿到下载地址，清单会不完整"
    done
  fi

  mstep "${PLATFORM_NAME}: 写清单并同步仓库"
  write_manifest
  MANIFEST_NOTE=" / ${MANIFEST_PATH}"
  sync_repo "$MIRROR_BRANCH" full

  mstep "${PLATFORM_NAME}: 清理旧版本（保留 GitHub 最新 ${KEEP} 个 tag）"
  prune_releases

  mirror_summary
}

mirror_summary() {
  local amd

  # 没有公开地址就什么都不回显。公开仓库的 Actions 日志和 Summary 是所有人可见的，
  # 在这里 echo 一次等于把地址永久公开出去。
  if [ "${PLATFORM_PUBLIC_URLS:-1}" != 1 ]; then
    mlog "已上传 ${TAG}（未配置公开访问地址，未发布清单）"
    [ -n "${GITHUB_STEP_SUMMARY:-}" ] || return 0
    {
      echo "### ${PLATFORM_NAME} \`${TAG}\`"
      echo ""
      echo "已上传产物。未配置公开访问地址，因此不生成清单，也不在此回显任何地址。"
      echo ""
    } >> "$GITHUB_STEP_SUMMARY"
    return 0
  fi

  amd="$(manifest_url_of caddy-linux-amd64)"
  mlog "下载地址: ${amd:-（未镜像二进制）}"

  [ -n "${GITHUB_STEP_SUMMARY:-}" ] || return 0
  {
    echo "### ${PLATFORM_NAME} \`${TAG}\`"
    echo ""
    if [ "${PLATFORM_KIND:-git}" = git ]; then
      echo "分支 \`${MIRROR_BRANCH}\`"
    else
      echo "命名空间 \`${MIRROR_BRANCH}\`"
    fi
    echo ""
    echo '```bash'
    echo "curl -fsSL ${RAW_BASE}/scripts/install.sh | sudo \\"
    echo "  CADDY_RAW_BASE=${RAW_BASE} \\"
    echo "  CADDY_MANIFEST=${MANIFEST_URL} bash"
    echo '```'
    echo ""
  } >> "$GITHUB_STEP_SUMMARY"
}
