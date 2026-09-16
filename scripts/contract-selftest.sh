#!/usr/bin/env bash
# =============================================================================
# contract-selftest.sh —— CONTRACT.md 的可执行版本
#
# 用法：
#   scripts/contract-selftest.sh [路径/install.sh]     默认 scripts/install.sh
#
# 【为什么要有这个】
# 契约是写给机器看的承诺。写在 Markdown 里的承诺会漂，写成断言的不会。
# 每改一次 install.sh 跑一遍，比"我实测过"可靠。
#
# 【怎么判断这套测试本身是好的】
# 它必须能在【旧版本】的 install.sh 上失败。一套在任何代码上都通过的测试
# 什么都没测。改完之后拿上一版跑一次，确认 ①②③ 组是红的。
#
# 不需要网络（清单走 file://），不需要 root，不碰真的 /usr/local/bin。
# =============================================================================
set -uo pipefail        # 【刻意不设 -e】：测试要跑完全部用例再汇总，不能中途退场

# 【断言一律用 grep -q <<< "$var"，不要用 printf … | grep -q】
# pipefail 下 `printf '%s\n' "$out" | grep -qxF "$kv"` 会【随机】假失败：
# grep -q 首次命中就退出 → printf 还没写完就吃 SIGPIPE(141) → pipefail
# 判整条管道失败 → 明明命中却记成「缺少」。命中在第一行时最容易触发。
# 实测 4000 次里假失败 3 次，换成 here-string 后 0 次。
#
# 这条本仓库在生产代码里已经栽过两次（aws ls | grep -q .、curl | head -n1），
# 却还是漏在了测试代码上 —— 测试代码天然比生产代码少受审视。
# 一个 flaky 的检查最终下场是被加 `|| true`，然后它保护的东西就再也没人管了。

I="${1:-scripts/install.sh}"
[ -f "$I" ] || { echo "找不到 install.sh: $I" >&2; exit 2; }
I="$(cd "$(dirname "$I")" && pwd)/$(basename "$I")"

W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
mkdir -p "$W/bin"
BIN="$W/bin/caddy"
TAG_NEW="v9.9.9-20260101.0000"
TAG_OLD="v9.9.8-20251201.0000"

# CONF_DIR 现在可以用 CADDY_CONF_DIR 覆盖（原来写死 /etc/caddy，导致这套测试
# 必须能写真实系统目录才跑得起来 —— 测不了的东西就没人测，那本身就是个缺陷）。
# 这里全部指到临时目录：不需要 root，不碰真实系统。
STATE_DIR="$W/etc"
mkdir -p "$STATE_DIR"
STATE="$STATE_DIR/.build-version"
export CADDY_CONF_DIR="$STATE_DIR"

# ---------- 夹具 ----------
mkman() { # mkman <文件> <contract 行或空> <tag>
    { [ -n "$2" ] && printf 'contract\t%s\n' "$2"
      printf 'tag\t%s\n' "$3"
      printf 'install_sh\tfile://%s\n' "$I"
      for a in caddy-linux-amd64 caddy-linux-arm64; do
          printf '%s\tfile://%s/%s\n'        "$a" "$W" "$a"
          printf '%s.sha256\tfile://%s/%s.sha256\n' "$a" "$W" "$a"
      done
    } > "$1"
}
mkman "$W/ok.txt"      1  "$TAG_NEW"
mkman "$W/c99.txt"     99 "$TAG_NEW"
mkman "$W/cbad.txt"    v2 "$TAG_NEW"
mkman "$W/nocontract.txt" "" "$TAG_NEW"
printf '<!DOCTYPE html>\n<html><body>404 Not Found</body></html>\n' > "$W/soft404.txt"

M()  { printf 'file://%s/%s' "$W" "$1"; }
installed() { printf '#!/bin/sh\necho x\n' > "$BIN"; chmod +x "$BIN"; printf '%s\n' "$1" > "$STATE"; }
notinstalled() { rm -f "$BIN" "$STATE"; }
nostate()  { printf '#!/bin/sh\necho x\n' > "$BIN"; chmod +x "$BIN"; rm -f "$STATE"; }

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  \033[31m✗\033[0m %s\n     %s\n' "$1" "$2"; }
grp()  { printf '\n\033[1m%s\033[0m\n' "$1"; }

# check <说明> <期望rc> <CADDY_MANIFEST 或 -> <期望 key=value ...>
check() {
    local desc="$1" want_rc="$2" man="$3"; shift 3
    local out rc kv miss=""
    if [ "$man" = "-" ]; then
        out="$(env CADDY_BIN="$BIN" CADDY_CONF_DIR="$STATE_DIR" bash "$I" --check 2>"$W/err")"; rc=$?
    else
        out="$(env CADDY_BIN="$BIN" CADDY_CONF_DIR="$STATE_DIR" CADDY_MANIFEST="$man" bash "$I" --check 2>"$W/err")"; rc=$?
    fi
    for kv in "$@"; do
        grep -qxF "$kv" <<< "$out" || miss="$miss [$kv]"
    done
    if [ "$rc" != "$want_rc" ]; then
        bad "$desc" "rc=$rc（期望 $want_rc）; 输出: $(printf '%s' "$out" | tr '\n' ' ')"
    elif [ -n "$miss" ]; then
        bad "$desc" "缺少键:$miss; 实得: $(printf '%s' "$out" | tr '\n' ' ')"
    else
        ok "$desc"
    fi
}

# ============================================================================
grp "① --check 六个场景（退出码是契约的一部分）"
notinstalled
check "A 没装 + 清单可达 → rc=3" 3 "$(M ok.txt)" \
      "current=none" "latest=$TAG_NEW" "would_change=yes"
installed "$TAG_NEW"
check "B 已装且最新 → rc=0, no" 0 "$(M ok.txt)" \
      "current=$TAG_NEW" "would_change=no"
installed "$TAG_OLD"
check "C 已装但旧 → rc=0, yes" 0 "$(M ok.txt)" \
      "current=$TAG_OLD" "latest=$TAG_NEW" "would_change=yes"
nostate
check "D 装了但没状态文件 → current=unknown" 0 "$(M ok.txt)" \
      "current=unknown" "would_change=yes"
installed "$TAG_OLD"
check "E 探测不到 → rc=1, unknown" 1 "$(M nope.txt)" \
      "latest=unknown" "would_change=unknown"
notinstalled
check "F 没装【且】探测不到 → rc=1（真故障压过正常结论）" 1 "$(M nope.txt)" \
      "current=none" "latest=unknown" "would_change=unknown"

# ============================================================================
grp "② 契约版本（本轮新增行为 —— 旧版 install.sh 这一组必须是红的）"
installed "$TAG_NEW"
check "G contract=99 → 拒绝解读，rc=1" 1 "$(M c99.txt)" \
      "contract=1" "manifest_contract=99" "latest=unknown" "would_change=unknown"

check "H 正常清单 → manifest_contract=1" 0 "$(M ok.txt)" \
      "manifest_contract=1"

check "I 无 contract 行的老清单 → 按 1 处理，不拦" 0 "$(M nocontract.txt)" \
      "manifest_contract=1" "would_change=no"

# unknown 和 none 是两个不同的结论，对应两种不同的处置：
#   none  出现在本该有清单的机器上 → 编排把 CADDY_MANIFEST 弄丢了，查编排
#   unknown                        → 清单源挂了 / 软 404，查镜像
# 不测的话，哪天有人把 mc=unknown 改成 mc=none，19/19 照样全绿。
check "H2 清单设了但读不出来 → unknown（不是 none）" 1 "$(M soft404.txt)" \
      "manifest_contract=unknown" "latest=unknown" "would_change=unknown"

# J 不能断言 rc：没设 MANIFEST 时 --check 会真的去问 GitHub，
# 结果取决于当前网络和线上版本。契约在这里要求的只是【键必须存在】。
# 断言里混进环境依赖，等于给自己埋一个随机失败的用例。
# 用 CADDY_TAG 短路版本探测：没设 MANIFEST 时 --check 本来会真的去问 GitHub，
# 结果取决于当时的网络和线上版本。断言里混进环境依赖等于埋一个随机失败的用例。
out="$(env CADDY_BIN="$BIN" CADDY_CONF_DIR="$STATE_DIR" CADDY_TAG=v0.0.0 bash "$I" --check 2>/dev/null)"
grep -qxF "manifest_contract=none" <<< "$out" \
  && ok "J 没设 MANIFEST 时键仍出现（条件出现的键是坑）" \
  || bad "J 没设 MANIFEST 时键仍出现" "实得: $(printf '%s' "$out" | tr '\n' ' ')"

grp "③ 诊断可见性 + 不重复（本轮新增 —— 旧版必须红）"
notinstalled
env CADDY_BIN="$BIN" CADDY_CONF_DIR="$STATE_DIR" CADDY_MANIFEST="$(M soft404.txt)" bash "$I" --check >/dev/null 2>"$W/e1"
n="$(grep -c '不像清单' "$W/e1" 2>/dev/null)"; n="${n:-0}"
case "$n" in
  0) bad "K 软 404 的原因要出现在 stderr" "一次都没出现（是不是还被 2>/dev/null 吞了）" ;;
  1) ok  "K 软 404 原因出现在 stderr，且只报一遍" ;;
  *) bad "K 软 404 原因只能报一遍" "报了 $n 遍（fetch_manifest 的 die 在子 shell 里被反复触发）" ;;
esac

env CADDY_BIN="$BIN" CADDY_CONF_DIR="$STATE_DIR" CADDY_MANIFEST="$(M nope.txt)" bash "$I" --check >/dev/null 2>"$W/e2"
[ -s "$W/e2" ] && ok "L 清单取不到时 stderr 有原因" \
               || bad "L 清单取不到时 stderr 有原因" "stderr 是空的"

# K/L 走的都是【清单】那条路，而清单的诊断来自 do_check 里的子 shell 预探。
# 只有这两条的话，给 latest_tag 加回 2>/dev/null 仍然全绿 —— 变异测试实测如此。
# 不走清单时（CADDY_TAG_FILE / GitHub 302）的诊断是另一条路径，必须单独测。
env CADDY_BIN="$BIN" CADDY_CONF_DIR="$STATE_DIR" \
    CADDY_TAG_FILE="file://$W/nope-pointer.txt" bash "$I" --check >/dev/null 2>"$W/e3"
grep -q '版本指针' "$W/e3" 2>/dev/null \
  && ok "L2 不走清单时，latest_tag 的诊断同样不能被吞" \
  || bad "L2 不走清单时 latest_tag 的诊断" "stderr 里没有原因：$(tr '\n' ' ' < "$W/e3")"

grp "④ 安装路径的契约检查（不实际安装，只看拒绝行为）"
one() { # one <说明> <清单> <期望 stderr 关键字>
    local o; o="$(env CADDY_BIN="$BIN" CADDY_CONF_DIR="$STATE_DIR" CADDY_MANIFEST="$2" bash "$I" install 2>&1)"
    grep -q "$3" <<< "$o" && ok "$1" || bad "$1" "stderr 里找不到「$3」：$(printf '%s' "$o" | head -2 | tr '\n' ' ')"
}
one "M contract=99 拒装"          "$(M c99.txt)"   "只支持到"
one "N contract 非整数报错"        "$(M cbad.txt)"  "不是整数"
one "O 软 404 被识别"             "$(M soft404.txt)" "不像清单"

grp "⑤ 其他契约面"
v="$(bash "$I" --contract-version 2>/dev/null)"
[ "$v" = "1" ] && ok "P --contract-version 输出 1" || bad "P --contract-version" "实得 '$v'"

cat > "$W/fake.sh" <<'EOF'
# 见第 2 节，涉及 33 台机器；旧值 CONTRACT_VERSION=99 已废弃
CONTRACT_VERSION=1   # 唯一真源
# CONTRACT_VERSION=7
EOF
cv="$(awk '/^CONTRACT_VERSION=/{sub(/^CONTRACT_VERSION=/,""); sub(/[^0-9].*$/,""); print; exit}' "$W/fake.sh")"
[ "$cv" = "1" ] && ok "Q awk 抠取抗注释干扰" || bad "Q awk 抠取" "实得 '$cv'（被注释里的数字串了）"

out="$(env CADDY_BIN="$BIN" CADDY_CONF_DIR="$STATE_DIR" CADDY_MANIFEST="$(M ok.txt)" bash "$I" --check 2>/dev/null)"
grep -qvE '^[a-z_]+=[^=]*$' <<< "$out" \
  && bad "R stdout 只有 key=value 行" "混进了别的内容" \
  || ok "R stdout 只有 key=value 行"

printf '\n\033[1m通过 %d，失败 %d\033[0m\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
