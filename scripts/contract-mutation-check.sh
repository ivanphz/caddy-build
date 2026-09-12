#!/usr/bin/env bash
# =============================================================================
# contract-mutation-check.sh —— 检验 contract-selftest.sh 本身有没有用
#
# 用法：
#   scripts/contract-mutation-check.sh [install.sh] [contract-selftest.sh]
#
# 【为什么要有这个】
# 一套在任何代码上都通过的测试什么都没测。这里把 install.sh 的关键行为逐条
# 打断，确认自测真的会红。实测逼出过一个空档：K/L 走的都是「清单」那条路，
# 给 latest_tag 加回 2>/dev/null 仍然全绿 —— 于是补了 L2。
#
# 【为什么是独立脚本而不是写在 workflow 里】
# 锚点是多行的原文片段，塞进 YAML 的 `run: |` 块标量会撑破缩进
#（片段里有 4 空格、8 空格的行，块标量要求每行不低于块缩进）。
# 放这里还有个好处：锚点和它要保护的断言在同一个目录，改 install.sh 时
# 一眼能看到两边都要跟。
#
# 【锚点故意只有四条】
# 每条都是精确字符串匹配，install.sh 一重构就要跟着改。再往上加，
# 维护成本会压过收益。挑的是「改坏了后果最重」的四条，各自映射一条契约条款。
# =============================================================================
set -uo pipefail

I="${1:-scripts/install.sh}"
T="${2:-scripts/contract-selftest.sh}"
[ -f "$I" ] && [ -f "$T" ] || { echo "找不到 $I 或 $T" >&2; exit 2; }

ORIG="$(mktemp)"; cp "$I" "$ORIG"
restore() { cp "$ORIG" "$I"; }
trap 'restore; rm -f "$ORIG"' EXIT

FAIL=0

mutate() {   # <条款> <原文> <替换>
    local desc="$1" a="$2" b="$3"
    restore
    if ! A="$a" B="$b" I="$I" python3 - <<'PY'
import os, sys
p = os.environ['I']
a, b = os.environ['A'], os.environ['B']
s = open(p, encoding='utf-8').read()
if s.count(a) != 1:
    sys.exit(
        f"变异锚点在 {p} 里找不到（或不唯一）:\n{a[:120]!r}\n"
        "install.sh 重构过了 —— 请更新本脚本里的锚点。\n"
        "这不是测试失败，是变异检测本身失效了，必须修，不能绕过。")
open(p, 'w', encoding='utf-8').write(s.replace(a, b))
PY
    then
        FAIL=$((FAIL + 1)); return 1
    fi

    if bash "$T" "$I" >/dev/null 2>&1; then
        printf '  \033[31m✗\033[0m 打断「%s」之后自测仍然全绿 —— 这条契约条款没有任何用例覆盖\n' "$desc"
        FAIL=$((FAIL + 1))
    else
        printf '  \033[32m✓\033[0m 打断「%s」→ 自测变红\n' "$desc"
    fi
}

echo "变异检测: $I  ←  $T"

# 条款：manifest_contract 无条件输出（条件出现的键会让消费者的 -le 比较炸）
mutate 'manifest_contract 无条件输出' \
'  printf '"'"'manifest_contract=%s\n'"'"' "${mc:-none}"' \
'  if [ -n "$MANIFEST" ]; then printf '"'"'manifest_contract=%s\n'"'"' "$mc"; fi'

# 条款：rc 非 0 时，原因一定打在 stderr 上
mutate 'latest_tag 的诊断不被吞' \
'    lt="$(latest_tag)" || lt=""' \
'    lt="$(latest_tag 2>/dev/null)" || lt=""'

# 条款：清单契约版本超出支持范围时，拒绝解读其中的 tag
mutate '契约超版本时拒绝解读' \
'          unreadable=1
        fi ;;' \
'          :
        fi ;;'

# 条款：rc=1 与 rc=3 同时成立时返回 1（真故障压过正常结论）
mutate 'rc=1 优先于 rc=3' \
'  if [ -z "$lt" ]; then
    printf '"'"'would_change=unknown\n'"'"'; ec=1
  elif [ -z "$cur" ]; then
    printf '"'"'would_change=yes\n'"'"'; ec=3' \
'  if [ -z "$cur" ]; then
    printf '"'"'would_change=yes\n'"'"'; ec=3
  elif [ -z "$lt" ]; then
    printf '"'"'would_change=unknown\n'"'"'; ec=1'

restore
if [ "$FAIL" -eq 0 ]; then
    printf '\n\033[1m四条变异都被抓住\033[0m\n'
else
    printf '\n\033[1;31m%d 条没被抓住\033[0m\n' "$FAIL"
fi
[ "$FAIL" -eq 0 ]
