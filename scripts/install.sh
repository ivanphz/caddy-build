#!/usr/bin/env bash
#
# caddy-build 安装 / 更新脚本
#
#   安装:   curl -fsSL https://raw.githubusercontent.com/ivanphz/caddy-build/main/scripts/install.sh | sudo bash
#   更新:   sudo caddy-update
#   卸载:   sudo caddy-update uninstall
#
# 环境变量:
# 下载来源（两类资源分开配，因为 URL 形状不同）:
#   GH_MIRROR=https://ghfast.top/   前缀型代理，同时作用于两类资源
#   CADDY_SOURCE=jsdelivr|fastly    仓库小文件走 jsDelivr（二进制仍走 GitHub，见下）
#   CADDY_RAW_BASE=<url>            仓库文件基址，完全自定义（私有仓库 Worker 用这个）
#   CADDY_REL_BASE=<url>            release 资产基址，完全自定义
#   CADDY_TAG_URL=<url>             latest 版本解析地址（跟 302 取 tag，GitHub 用）
#   CADDY_TAG_FILE=<url>            从纯文本文件读 tag（R2 / 自建源用，无 302 可跟）
#   CADDY_MANIFEST=<url>            清单文件，直接给出每个资产的完整下载地址。
#                                   给 URL 无法从 tag 推导的平台用（如 Gitee 的
#                                   attach_files/{数字ID}/download/{名}）。设了它
#                                   就同时覆盖 REL_BASE 和 TAG_FILE。
#
#   注意: jsDelivr 的 /gh/ 单文件上限 20 MB，且只服务 git 树、不碰 Releases。
#   caddy 二进制约 69 MB，所以 CADDY_SOURCE 只改仓库文件来源，不改二进制来源。
#
#   CADDY_REPO=owner/repo           指定其它仓库
#   CADDY_TAG=v20260807-1610        安装指定版本，默认 latest
#   CADDY_BIN=/usr/local/bin/caddy  二进制安装路径
#   NO_SERVICE=1                    只装二进制，不碰 systemd
#   WELCOME=0                       不部署默认欢迎页（Caddyfile 仍用官方那份，根路径返回 404）
#
set -euo pipefail

REPO="${CADDY_REPO:-ivanphz/caddy-build}"
BIN_PATH="${CADDY_BIN:-/usr/local/bin/caddy}"
GH_MIRROR="${GH_MIRROR:-}"
TAG="${CADDY_TAG:-}"
WELCOME="${WELCOME:-1}"

CONF_DIR=/etc/caddy
CONF_FILE="$CONF_DIR/Caddyfile"
DATA_DIR=/var/lib/caddy
LOG_DIR=/var/log/caddy
SITE_DIR=/usr/share/caddy
STATE_FILE="$CONF_DIR/.build-version"   # 记录已安装的 release tag
UNIT=/etc/systemd/system/caddy.service
HELPER=/usr/local/bin/caddy-update

# ---- 下载来源解析 ----
# 两类资源必须分开，因为 URL 形状根本不同：
#   RAW_BASE  仓库文件（install.sh 自身、dist/*），几十 KB，可走 CDN / Worker
#   REL_BASE  release 资产（二进制 + sha256），约 69 MB，只能走 GitHub 或前缀型代理
#   TAG_URL   解析 latest tag 的 302 跳转，GitHub 特有
case "${CADDY_SOURCE:-github}" in
  github)   RAW_DEFAULT="${GH_MIRROR}https://raw.githubusercontent.com/${REPO}/main" ;;
  jsdelivr) RAW_DEFAULT="https://cdn.jsdelivr.net/gh/${REPO}@main" ;;
  fastly)   RAW_DEFAULT="https://fastly.jsdelivr.net/gh/${REPO}@main" ;;
  *) echo "错误: 未知 CADDY_SOURCE '${CADDY_SOURCE}'（可用 github / jsdelivr / fastly）" >&2
     exit 1 ;;
esac

RAW_BASE="${CADDY_RAW_BASE:-$RAW_DEFAULT}"
REL_BASE="${CADDY_REL_BASE:-${GH_MIRROR}https://github.com/${REPO}/releases/download}"
TAG_URL="${CADDY_TAG_URL:-${GH_MIRROR}https://github.com/${REPO}/releases/latest}"
TAG_FILE="${CADDY_TAG_FILE:-}"   # 设了就优先用它，绕开 GitHub 的 302
MANIFEST="${CADDY_MANIFEST:-}"   # 设了就优先用它，绕开一切 URL 拼接
MANIFEST_CACHE=""                # 一次会话只拉一次
TMPD=""                          # 全局临时目录，供 EXIT trap 清理

# trap 在脚本退出时执行，那时函数的 local 变量早已出作用域。
# 之前写成 trap 'rm -rf "$tmp"' EXIT，配合 set -u 会报 "tmp: unbound variable"。
cleanup() {
  [ -n "${TMPD:-}" ] && rm -rf "$TMPD" || true
  [ -n "${MANIFEST_CACHE:-}" ] && rm -f "$MANIFEST_CACHE" || true
}
trap cleanup EXIT

SELF_URL="${RAW_BASE}/scripts/install.sh"

# ---------------------------------------------------------------- 工具函数

# 全部走 stderr。函数若用 stdout 返回值（如 fetch_binary 回显路径），
# 混在一起会被 $(...) 一并捕获 —— 表现为 install 报
# "cannot stat '  架构: amd64'..." 这种莫名其妙的错误。
c_red()  { printf '\033[31m%s\033[0m\n' "$*" >&2; }
c_grn()  { printf '\033[32m%s\033[0m\n' "$*" >&2; }
c_ylw()  { printf '\033[33m%s\033[0m\n' "$*" >&2; }
info()   { printf '  %s\n' "$*" >&2; }
step()   { printf '\n\033[1m==> %s\033[0m\n' "$*" >&2; }
die()    { c_red "错误: $*" >&2; exit 1; }

need_root() {
  [ "$(id -u)" -eq 0 ] || die "需要 root 权限，请用 sudo 运行"
}

raw_url() { printf '%s/%s' "$RAW_BASE" "$1"; }             # $1 = 仓库内相对路径

# 清单格式（tab 分隔，每行 key<TAB>value）:
#   tag                       v2.11.4-20260807.1930
#   caddy-linux-amd64         https://.../download/caddy-linux-amd64
#   caddy-linux-amd64.sha256  https://.../download/caddy-linux-amd64.sha256
# 用纯文本而非 JSON，是为了不给脚本引入 jq 依赖 —— 全程只用 curl/awk/sed。
fetch_manifest() {
  [ -n "$MANIFEST" ] || return 1
  if [ -z "$MANIFEST_CACHE" ]; then
    MANIFEST_CACHE="$(mktemp)"
    curl -fsSL --retry 2 --max-time 30 "$MANIFEST" -o "$MANIFEST_CACHE" \
      || die "无法拉取清单: $MANIFEST"
    tr -d '\r' < "$MANIFEST_CACHE" > "${MANIFEST_CACHE}.clean" \
      && mv -f "${MANIFEST_CACHE}.clean" "$MANIFEST_CACHE"
  fi
  printf '%s' "$MANIFEST_CACHE"
}

manifest_get() {
  # $1 = key；未命中返回非零
  local f v
  f="$(fetch_manifest)" || return 1
  v="$(awk -F'\t' -v k="$1" '$1==k{print $2; found=1; exit} END{exit !found}' "$f")" || return 1
  [ -n "$v" ] || return 1
  printf '%s' "$v"
}

rel_url() {
  # $1 = 资产文件名。有清单就查表，否则按 基址/tag/文件名 拼。
  if [ -n "$MANIFEST" ]; then
    manifest_get "$1" || die "清单里没有资产 '$1'（$MANIFEST）"
    return
  fi
  printf '%s/%s/%s' "$REL_BASE" "$TAG" "$1"
}

detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64)  echo amd64 ;;
    aarch64|arm64) echo arm64 ;;
    *) die "不支持的架构: $(uname -m)（本仓库只发布 linux amd64 / arm64）" ;;
  esac
}

latest_tag() {
  local url tag

  # 清单自带 tag，优先级最高
  if [ -n "$MANIFEST" ]; then
    tag="$(manifest_get tag)" || die "清单里缺少 tag 行: $MANIFEST"
    printf '%s' "$tag"
    return
  fi

  # 自建源（R2 / 对象存储）没有 releases/latest 那种 302 可跟，用纯文本指针
  if [ -n "$TAG_FILE" ]; then
    tag="$(curl -fsSL --retry 2 --max-time 30 "$TAG_FILE" 2>/dev/null | head -n1 | tr -d '\r ')" \
      || die "无法读取版本指针: $TAG_FILE"
    [ -n "$tag" ] || die "版本指针为空: $TAG_FILE"
    printf '%s' "$tag"
    return
  fi

  # GitHub: 不依赖 jq / API 配额，跟一次 /releases/latest 的 302，从最终 URL 取 tag
  url="$(curl -fsSLI -o /dev/null -w '%{url_effective}' "$TAG_URL")" \
    || die "无法解析最新版本（$TAG_URL）。可设 GH_MIRROR= / CADDY_TAG_URL= / CADDY_TAG_FILE=，或直接指定 CADDY_TAG="
  printf '%s' "${url##*/tag/}"
}

caddy_version() {
  # 二进制没有被注入 CustomVersion，所以这里返回的是真正的 Caddy 核心版本
  #（如 v2.11.4），与官方二进制、与 xcaddy 构建的输出完全一致。
  [ -x "$BIN_PATH" ] || { printf ''; return; }
  "$BIN_PATH" version 2>/dev/null | awk 'NR==1{print $1}'
}

installed_tag() {
  # release tag 不在二进制里，装的时候单独记在状态文件
  [ -r "$STATE_FILE" ] && head -n1 "$STATE_FILE" || printf ''
}

source_commit() {
  # Go 在编译时把源码 commit stamp 进了二进制（-ldflags "-w -s" 剥不掉它，
  # 构建信息在独立的段里）。这是比日期更精确的构建身份：直接指向那一刻的
  # go.mod 和 main.go。
  [ -x "$BIN_PATH" ] || { printf ''; return; }
  "$BIN_PATH" build-info 2>/dev/null \
    | awk -F= '/vcs.revision=/{print substr($2,1,7); exit}'
}

binary_matches_release() {
  # 状态文件缺失时的兜底（手动装的 / 从旧版迁移过来的）：
  # 直接比对已装二进制与目标 release 的 sha256。
  # 这一层比标签比对更严格 —— 二进制被手动换过或损坏也能发现。
  local arch asset want have
  [ -x "$BIN_PATH" ] || return 1
  arch="$(detect_arch)"; asset="caddy-linux-${arch}"
  want="$(curl -fsL --retry 2 --max-time 30 "$(rel_url "${asset}.sha256")" \
          2>/dev/null | awk '{print $1}')" || return 1
  [ -n "$want" ] || return 1
  have="$(sha256sum "$BIN_PATH" | awk '{print $1}')"
  [ "$have" = "$want" ]
}

# ---------------------------------------------------------------- 下载 + 校验

FETCHED=""   # fetch_binary 的返回值走全局变量，不走 stdout

fetch_binary() {
  # $1 = 目标目录; 结果写入全局 FETCHED
  local dir="$1" arch asset
  arch="$(detect_arch)"
  asset="caddy-linux-${arch}"

  info "架构: ${arch}"
  info "版本: ${TAG}"
  info "来源: $(rel_url "$asset")"

  curl -fL --retry 3 --retry-delay 2 --progress-bar \
       -o "${dir}/${asset}" "$(rel_url "$asset")" \
    || die "下载二进制失败: $(rel_url "$asset")"

  if curl -fsL --retry 3 -o "${dir}/${asset}.sha256" "$(rel_url "${asset}.sha256")"; then
    ( cd "$dir" && sha256sum -c "${asset}.sha256" >/dev/null ) \
      || die "SHA256 校验失败，文件可能损坏或被篡改"
    c_grn "  ✓ SHA256 校验通过"
  else
    c_ylw "  ! 未找到校验和文件，跳过校验"
  fi

  chmod +x "${dir}/${asset}"
  "${dir}/${asset}" version >/dev/null 2>&1 || die "下载的二进制无法执行"
  FETCHED="${dir}/${asset}"
}

install_binary() {
  # $1 = 新二进制路径。用 rename 而不是 cp —— 覆盖正在运行的可执行文件会 ETXTBSY
  local src="$1"
  mkdir -p "$(dirname "$BIN_PATH")"
  [ -x "$BIN_PATH" ] && cp -f "$BIN_PATH" "${BIN_PATH}.bak"
  install -m 0755 "$src" "${BIN_PATH}.new"
  mv -f "${BIN_PATH}.new" "$BIN_PATH"
}

rollback_binary() {
  [ -f "${BIN_PATH}.bak" ] || return 1
  c_ylw "  正在回滚到上一版本…"
  mv -f "${BIN_PATH}.bak" "$BIN_PATH"
}

# ---------------------------------------------------------------- 系统集成

ensure_user() {
  getent group caddy >/dev/null || groupadd --system caddy
  if ! getent passwd caddy >/dev/null; then
    local shell=/usr/sbin/nologin
    [ -x "$shell" ] || shell=/sbin/nologin
    [ -x "$shell" ] || shell=/bin/false
    useradd --system --gid caddy --create-home --home-dir "$DATA_DIR" \
            --shell "$shell" --comment "Caddy web server" caddy
  fi
  mkdir -p "$CONF_DIR" "$DATA_DIR" "$LOG_DIR"
  chown -R caddy:caddy "$DATA_DIR" "$LOG_DIR"
}

install_welcome() {
  # dist/index.html 与 caddyserver/dist/welcome/index.html 逐字节相同，
  # 即 apt 装 caddy 时落到 /usr/share/caddy/index.html 的那张欢迎页。
  #
  # 这张页面的价值在于「匿名集」：全网每台装完没配过的 Caddy 都长这样，
  # 主动探测拿到它得不到任何判别力。反过来，任何自造的独特响应文本
  # （比如一句自定义 respond）都是完美的扫描特征 —— 所以这里没有
  # 「换一个更低调的占位页」这种选项，要么用官方那张，要么留空。
  mkdir -p "$SITE_DIR"

  if [ "$WELCOME" != 1 ]; then
    info "已跳过欢迎页（WELCOME=0）"
    info "  ${SITE_DIR} 为空时根路径返回 404；放自己的内容进去即可"
    return 0
  fi

  if curl -fsL --retry 2 -o "${SITE_DIR}/index.html.new" "$(raw_url dist/index.html)"; then
    mv -f "${SITE_DIR}/index.html.new" "${SITE_DIR}/index.html"
    chmod 0644 "${SITE_DIR}/index.html"
    info "欢迎页: ${SITE_DIR}/index.html"
  else
    rm -f "${SITE_DIR}/index.html.new"
    c_ylw "  ! 欢迎页下载失败，${SITE_DIR} 为空，根路径将返回 404"
  fi
  return 0
}

write_default_config() {
  # 已有配置一律不动
  if [ -f "$CONF_FILE" ]; then
    info "已存在配置，保留不动: $CONF_FILE"
    return 0
  fi

  if curl -fsL --retry 2 -o "${CONF_FILE}.new" "$(raw_url dist/Caddyfile)"; then
    mv -f "${CONF_FILE}.new" "$CONF_FILE"
  else
    # 兜底副本与 caddyserver/dist/config/Caddyfile 逐字节相同。
    # 刻意不在这里自造任何独特文案 —— 见 install_welcome 的注释。
    rm -f "${CONF_FILE}.new"
    c_ylw "  ! Caddyfile 下载失败，写入内置副本"
    sed 's/^    //' > "$CONF_FILE" <<'CADDYFILE_EOF'
    # The Caddyfile is an easy way to configure your Caddy web server.
    #
    # Unless the file starts with a global options block, the first
    # uncommented line is always the address of your site.
    #
    # To use your own domain name (with automatic HTTPS), first make
    # sure your domain's A/AAAA DNS records are properly pointed to
    # this machine's public IP, then replace ":80" below with your
    # domain name.

    :80 {
    	# Set this path to your site's directory.
    	root * /usr/share/caddy

    	# Enable the static file server.
    	file_server

    	# Another common task is to set up a reverse proxy:
    	# reverse_proxy localhost:8080

    	# Or serve a PHP site through php-fpm:
    	# php_fastcgi localhost:9000
    }

    # Refer to the Caddy docs for more information:
    # https://caddyserver.com/docs/caddyfile
CADDYFILE_EOF
  fi
  chown caddy:caddy "$CONF_FILE"
  info "配置文件: $CONF_FILE"
}

write_unit() {
  if [ -f "$UNIT" ]; then
    info "已存在 systemd unit，保留不动: $UNIT"
    return 0
  fi
  # 与 caddyserver/dist/init/caddy.service 对齐，只改了路径。
  # CAP_NET_ADMIN 不能省：quic-go 用 SO_RCVBUFFORCE 绕过 net.core.rmem_max
  # 扩 UDP 接收缓冲，缺了它 HTTP/3 高吞吐下会丢包并刷 buffer 警告。
  # CAP_NET_BIND_SERVICE 让非 root 的 caddy 用户能绑 80/443，因此不需要 setcap
  #（setcap 会在每次替换二进制后失效，很容易忘）。
  cat > "$UNIT" <<EOF
[Unit]
Description=Caddy (custom build)
Documentation=https://caddyserver.com/docs/
After=network.target network-online.target
Requires=network-online.target

[Service]
Type=notify
User=caddy
Group=caddy
ExecStart=${BIN_PATH} run --environ --config ${CONF_FILE}
ExecReload=${BIN_PATH} reload --config ${CONF_FILE} --force
TimeoutStopSec=5s
LimitNOFILE=1048576
PrivateTmp=true
ProtectSystem=full
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  info "systemd unit: $UNIT"
}

write_helper() {
  # 把本次解析出的来源固化进 helper —— 否则用 jsDelivr / Worker 装的机器，
  # 下次 caddy-update 会退回默认 GitHub 源，在受限网络下直接失败。
  cat > "$HELPER" <<EOF
#!/usr/bin/env bash
# 由 caddy-build install.sh 生成，勿手改（重装会覆盖）
set -euo pipefail
export CADDY_REPO="\${CADDY_REPO:-${REPO}}"
export CADDY_RAW_BASE="\${CADDY_RAW_BASE:-${RAW_BASE}}"
export CADDY_REL_BASE="\${CADDY_REL_BASE:-${REL_BASE}}"
export CADDY_TAG_URL="\${CADDY_TAG_URL:-${TAG_URL}}"
export CADDY_TAG_FILE="\${CADDY_TAG_FILE:-${TAG_FILE}}"
export CADDY_MANIFEST="\${CADDY_MANIFEST:-${MANIFEST}}"
TMP="\$(mktemp)"
trap 'rm -f "\$TMP"' EXIT
curl -fsSL "${SELF_URL}" -o "\$TMP"
exec bash "\$TMP" "\$@"
EOF
  chmod 0755 "$HELPER"
}

# ---------------------------------------------------------------- 主流程

check_conflicts() {
  # 官方 caddy .deb 装在 /usr/bin/caddy 且自带 /lib/systemd/system/caddy.service。
  # 本脚本装到 /usr/local/bin/caddy 并写 /etc/systemd/system/caddy.service：
  # PATH 上 /usr/local/bin 在前、/etc 下的 unit 覆盖 /lib 下的，所以平时是本构建生效。
  # 但 apt upgrade 会悄悄换掉 /usr/bin/caddy，一旦本地 unit 被删就会回落到无插件版本。
  command -v dpkg-query >/dev/null 2>&1 || return 0
  dpkg-query -W -f='${Status}' caddy 2>/dev/null | grep -q "^install ok installed" || return 0
  c_ylw "  ! 检测到已安装官方 caddy apt 包（/usr/bin/caddy）"
  info "    本构建装在 ${BIN_PATH}，正常情况下优先生效，但两者会长期打架。"
  info "    建议二选一:  sudo apt remove caddy    或    sudo apt-mark hold caddy"
}

do_install() {
  need_root
  command -v curl >/dev/null || die "需要 curl"
  check_conflicts
  [ -n "$TAG" ] || TAG="$(latest_tag)"

  local cur up_to_date=0
  cur="$(installed_tag)"

  if [ -x "$BIN_PATH" ]; then
    if [ -n "$cur" ]; then
      [ "$cur" = "$TAG" ] && up_to_date=1
    elif binary_matches_release; then
      # 二进制内容已经是目标版本，只是没有状态文件 —— 补写一份即可
      up_to_date=1
      cur="$TAG"
    fi
  fi

  if [ "$up_to_date" = 1 ]; then
    printf '%s\n' "$(c_grn "已是最新版本 ${TAG}，无需更新。")"
    info "caddy version: $(caddy_version)"
    printf '%s\n' "$TAG" > "$STATE_FILE" 2>/dev/null || true
    info "强制重装: sudo CADDY_TAG=${TAG} caddy-update install --force"
    [ "${FORCE:-0}" = 1 ] || return 0
  elif [ -x "$BIN_PATH" ]; then
    step "更新 ${cur:-未知版本} → ${TAG}"
  else
    step "安装 ${TAG}"
  fi

  TMPD="$(mktemp -d)"
  fetch_binary "$TMPD"

  step "安装二进制"
  install_binary "$FETCHED"
  mkdir -p "$CONF_DIR"
  printf '%s\n' "$TAG" > "$STATE_FILE"
  chmod 0644 "$STATE_FILE"
  info "caddy version: $(caddy_version)"
  info "release tag:   $TAG  (记录于 $STATE_FILE)"

  if [ "${NO_SERVICE:-0}" = 1 ]; then
    c_grn "完成（已跳过 systemd 配置）"
    return 0
  fi

  step "配置系统服务"
  ensure_user
  install_welcome
  write_default_config
  write_unit
  write_helper

  # 换二进制后新插件可能让旧配置失效，先验证再重启
  if ! "$BIN_PATH" validate --config "$CONF_FILE" >/dev/null 2>&1; then
    c_ylw "  ! 配置校验未通过，先不重启服务"
    "$BIN_PATH" validate --config "$CONF_FILE" || true
    if rollback_binary; then rm -f "$STATE_FILE"; c_ylw "  已回滚二进制"; fi
    exit 1
  fi

  step "启动服务"
  if systemctl is-enabled --quiet caddy 2>/dev/null; then
    systemctl restart caddy
  else
    systemctl enable --now caddy
  fi

  sleep 2
  if systemctl is-active --quiet caddy; then
    rm -f "${BIN_PATH}.bak"
    c_grn "✓ caddy 运行中（$(caddy_version) / ${TAG}）"
  else
    c_red "✗ caddy 启动失败"
    journalctl -u caddy -n 30 --no-pager || true
    if rollback_binary; then
      rm -f "$STATE_FILE"      # 回滚后标签已不可信，删掉让下次走 sha256 兜底
      systemctl restart caddy || true
      c_ylw "已回滚，请检查上面的日志"
    fi
    exit 1
  fi

  cat <<EOF

  配置文件   $CONF_FILE
  站点根目录 $SITE_DIR
  数据目录   $DATA_DIR
  更新       sudo caddy-update
  查看日志   journalctl -u caddy -f
  重载配置   sudo systemctl reload caddy

EOF
}

do_uninstall() {
  need_root
  step "卸载"
  systemctl disable --now caddy 2>/dev/null || true
  rm -f "$UNIT" "$BIN_PATH" "${BIN_PATH}.bak" "$HELPER" "$STATE_FILE"
  systemctl daemon-reload 2>/dev/null || true
  c_grn "已移除二进制与服务。"
  info "配置和数据保留在 $CONF_DIR / $DATA_DIR / $SITE_DIR，确认不需要后手动删除。"
}

do_status() {
  local cv it lt
  cv="$(caddy_version)"; it="$(installed_tag)"; lt="$(latest_tag)"
  printf '仓库           %s\n' "$REPO"
  printf '仓库文件源     %s\n' "$RAW_BASE"
  if [ -n "$MANIFEST" ]; then
    printf 'release 源     清单 %s\n' "$MANIFEST"
  else
    printf 'release 源     %s\n' "$REL_BASE"
  fi
  printf 'caddy version  %s\n' "${cv:-未安装}"
  printf '已装 release   %s\n' "${it:-未知（无状态文件）}"
  printf '源码 commit    %s\n' "$(source_commit || echo '未知')"
  printf '最新 release   %s\n' "$lt"
  systemctl is-active caddy >/dev/null 2>&1 \
    && printf '服务           running\n' || printf '服务           stopped\n'
  [ -n "$it" ] && [ "$it" != "$lt" ] && printf '\n有新版本可用，运行 sudo caddy-update\n'
  return 0
}

case "${1:-install}" in
  install|update|upgrade|"")
    [ "${2:-}" = "--force" ] && FORCE=1
    do_install
    ;;
  uninstall|remove) do_uninstall ;;
  status)           do_status ;;
  -h|--help|help)
    sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'
    ;;
  *) die "未知子命令: $1（可用: install / update / uninstall / status）" ;;
esac
