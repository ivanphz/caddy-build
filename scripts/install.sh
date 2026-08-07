#!/usr/bin/env bash
#
# my-custom-caddy 安装 / 更新脚本
#
#   安装:   curl -fsSL https://raw.githubusercontent.com/ivanphz/my-custom-caddy/main/scripts/install.sh | sudo bash
#   更新:   sudo caddy-update
#   卸载:   sudo caddy-update uninstall
#
# 环境变量:
#   GH_MIRROR=https://ghfast.top/   国内加速前缀（会拼在 github.com 链接前面）
#   CADDY_REPO=owner/repo           指定其它仓库
#   CADDY_TAG=v20260807-1610        安装指定版本，默认 latest
#   CADDY_BIN=/usr/local/bin/caddy  二进制安装路径
#   NO_SERVICE=1                    只装二进制，不碰 systemd
#   WELCOME=0                       不部署默认欢迎页，改用极简 Caddyfile
#
set -euo pipefail

REPO="${CADDY_REPO:-ivanphz/my-custom-caddy}"
BIN_PATH="${CADDY_BIN:-/usr/local/bin/caddy}"
GH_MIRROR="${GH_MIRROR:-}"
TAG="${CADDY_TAG:-}"
WELCOME="${WELCOME:-1}"

CONF_DIR=/etc/caddy
CONF_FILE="$CONF_DIR/Caddyfile"
DATA_DIR=/var/lib/caddy
LOG_DIR=/var/log/caddy
SITE_DIR=/usr/share/caddy
UNIT=/etc/systemd/system/caddy.service
HELPER=/usr/local/bin/caddy-update

RAW_BASE="https://raw.githubusercontent.com/${REPO}/main"
SELF_URL="${RAW_BASE}/scripts/install.sh"
DIST_BASE="${RAW_BASE}/dist"

# ---------------------------------------------------------------- 工具函数

c_red()  { printf '\033[31m%s\033[0m\n' "$*"; }
c_grn()  { printf '\033[32m%s\033[0m\n' "$*"; }
c_ylw()  { printf '\033[33m%s\033[0m\n' "$*"; }
info()   { printf '  %s\n' "$*"; }
step()   { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
die()    { c_red "错误: $*" >&2; exit 1; }

need_root() {
  [ "$(id -u)" -eq 0 ] || die "需要 root 权限，请用 sudo 运行"
}

mirror() {
  printf '%s%s' "$GH_MIRROR" "$1"
}

detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64)  echo amd64 ;;
    aarch64|arm64) echo arm64 ;;
    *) die "不支持的架构: $(uname -m)（本仓库只发布 linux amd64 / arm64）" ;;
  esac
}

latest_tag() {
  # 不依赖 jq / GitHub API 配额：跟一次 /releases/latest 的 302，从最终 URL 取 tag
  local url
  url="$(curl -fsSLI -o /dev/null -w '%{url_effective}' \
        "$(mirror "https://github.com/${REPO}/releases/latest")")" \
    || die "无法访问 GitHub，试试 GH_MIRROR=https://ghfast.top/"
  printf '%s' "${url##*/tag/}"
}

installed_version() {
  [ -x "$BIN_PATH" ] || { printf ''; return; }
  "$BIN_PATH" version 2>/dev/null | awk 'NR==1{print $1}'
}

# ---------------------------------------------------------------- 下载 + 校验

fetch_binary() {
  # $1 = 目标目录; 回显下载好的文件名
  local dir="$1" arch asset base
  arch="$(detect_arch)"
  asset="caddy-linux-${arch}"
  base="$(mirror "https://github.com/${REPO}/releases/download/${TAG}")"

  info "架构: ${arch}"
  info "版本: ${TAG}"

  curl -fL --retry 3 --retry-delay 2 --progress-bar \
       -o "${dir}/${asset}" "${base}/${asset}" \
    || die "下载二进制失败: ${base}/${asset}"

  if curl -fsL --retry 3 -o "${dir}/${asset}.sha256" "${base}/${asset}.sha256"; then
    ( cd "$dir" && sha256sum -c "${asset}.sha256" >/dev/null ) \
      || die "SHA256 校验失败，文件可能损坏或被篡改"
    c_grn "  ✓ SHA256 校验通过"
  else
    c_ylw "  ! 未找到校验和文件，跳过校验"
  fi

  chmod +x "${dir}/${asset}"
  "${dir}/${asset}" version >/dev/null 2>&1 || die "下载的二进制无法执行"
  printf '%s' "${dir}/${asset}"
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
  [ "$WELCOME" = 1 ] || return 1
  mkdir -p "$SITE_DIR"
  if curl -fsL --retry 2 -o "${SITE_DIR}/index.html.new" "$(mirror "${DIST_BASE}/index.html")"; then
    mv -f "${SITE_DIR}/index.html.new" "${SITE_DIR}/index.html"
    chmod 0644 "${SITE_DIR}/index.html"
    info "欢迎页: ${SITE_DIR}/index.html"
    return 0
  fi
  rm -f "${SITE_DIR}/index.html.new"
  c_ylw "  ! 欢迎页下载失败，将改用极简配置"
  return 1
}

write_default_config() {
  # 已有配置一律不动
  if [ -f "$CONF_FILE" ]; then
    info "已存在配置，保留不动: $CONF_FILE"
    return 0
  fi

  # 默认 Caddyfile 靠 `root * /usr/share/caddy` + `file_server` 提供欢迎页，
  # 两者必须成对；欢迎页没装成就回落到不依赖静态文件的极简配置，避免开箱即 404。
  if install_welcome && \
     curl -fsL --retry 2 -o "${CONF_FILE}.new" "$(mirror "${DIST_BASE}/Caddyfile")"; then
    mv -f "${CONF_FILE}.new" "$CONF_FILE"
  else
    rm -f "${CONF_FILE}.new"
    cat > "$CONF_FILE" <<'EOF'
# https://caddyserver.com/docs/caddyfile
#
# 改成自己的域名后，Caddy 会自动申请并续期证书。
:80 {
	respond "custom caddy is running"
}
EOF
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
  cat > "$HELPER" <<EOF
#!/usr/bin/env bash
# 由 my-custom-caddy install.sh 生成
set -euo pipefail
TMP="\$(mktemp)"
trap 'rm -f "\$TMP"' EXIT
curl -fsSL "\${GH_MIRROR:-}${SELF_URL}" -o "\$TMP"
exec bash "\$TMP" "\$@"
EOF
  chmod 0755 "$HELPER"
}

# ---------------------------------------------------------------- 主流程

do_install() {
  need_root
  command -v curl >/dev/null || die "需要 curl"
  [ -n "$TAG" ] || TAG="$(latest_tag)"

  local cur; cur="$(installed_version)"
  if [ -n "$cur" ]; then
    if [ "$cur" = "$TAG" ]; then
      c_grn "已是最新版本 ${TAG}，无需更新。"
      info "强制重装: sudo CADDY_TAG=${TAG} caddy-update install --force"
      [ "${FORCE:-0}" = 1 ] || return 0
    else
      step "更新 ${cur} → ${TAG}"
    fi
  else
    step "安装 ${TAG}"
  fi

  local tmp; tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
  local newbin; newbin="$(fetch_binary "$tmp")"

  step "安装二进制"
  install_binary "$newbin"
  info "$("$BIN_PATH" version)"

  if [ "${NO_SERVICE:-0}" = 1 ]; then
    c_grn "完成（已跳过 systemd 配置）"
    return 0
  fi

  step "配置系统服务"
  ensure_user
  write_default_config
  write_unit
  write_helper

  # 换二进制后新插件可能让旧配置失效，先验证再重启
  if ! "$BIN_PATH" validate --config "$CONF_FILE" >/dev/null 2>&1; then
    c_ylw "  ! 配置校验未通过，先不重启服务"
    "$BIN_PATH" validate --config "$CONF_FILE" || true
    rollback_binary && c_ylw "  已回滚二进制" || true
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
    c_grn "✓ caddy 运行中（$("$BIN_PATH" version)）"
  else
    c_red "✗ caddy 启动失败"
    journalctl -u caddy -n 30 --no-pager || true
    if rollback_binary; then
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
  rm -f "$UNIT" "$BIN_PATH" "${BIN_PATH}.bak" "$HELPER"
  systemctl daemon-reload 2>/dev/null || true
  c_grn "已移除二进制与服务。"
  info "配置和数据保留在 $CONF_DIR / $DATA_DIR / $SITE_DIR，确认不需要后手动删除。"
}

do_status() {
  printf '仓库     %s\n' "$REPO"
  printf '已安装   %s\n' "$(installed_version || echo '未安装')"
  printf '最新版   %s\n' "$(latest_tag)"
  systemctl is-active caddy >/dev/null 2>&1 \
    && printf '服务     running\n' || printf '服务     stopped\n'
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
