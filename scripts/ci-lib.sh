#!/usr/bin/env bash
#
# 各 workflow 共用的小工具。用 `source scripts/ci-lib.sh` 引入。
#
# 只放一件事：重试。GitHub runner 到 api.github.com 会偶发抖动，实测见过
#   Post "https://api.github.com/graphql": tls: failed to verify certificate:
#   x509: certificate is not valid for any names, but wanted to match api.github.com
# 整步几秒就红了，重跑一次就好。这种错误不该让一次编译或一整条镜像链路作废。
#
# 刻意不做的事：不在这里包装业务逻辑。重试是横切关注点，
# 混进平台适配器或构建步骤会让「这一步到底做了什么」变得难读。

# 通用重试。命令的 stdout/stderr 原样透传。
#   retry <次数> <首次间隔秒> -- <命令...>
# 间隔按次数线性递增（delay, 2*delay, 3*delay …）。
retry() {
  local times="$1" delay="$2"; shift 2
  [ "${1:-}" = "--" ] && shift
  local i=1
  while :; do
    if "$@"; then return 0; fi
    if [ "$i" -ge "$times" ]; then
      echo "::error::重试 ${times} 次仍失败: $*" >&2
      return 1
    fi
    echo "  第 ${i}/${times} 次失败，$(( i * delay ))s 后重试: $*" >&2
    sleep $(( i * delay ))
    i=$(( i + 1 ))
  done
}

# gh 专用：stdout 落盘到指定文件，方便调用方读取；stderr 留档以便失败时回显。
#   gh_retry <输出文件> <gh 参数...>
# 返回非零时调用方自己决定是中止还是降级 —— 这里不替它做决定。
gh_retry() {
  local out="$1"; shift
  local err="${out}.err" i
  for i in 1 2 3 4; do
    if gh "$@" > "$out" 2> "$err"; then
      return 0
    fi
    echo "  gh 第 ${i}/4 次失败: $(tail -n1 "$err" 2>/dev/null)" >&2
    [ "$i" -lt 4 ] && sleep $(( i * 5 ))
  done
  echo "::error::gh 重试 4 次仍失败: gh $*" >&2
  sed 's/^/    /' "$err" >&2 2>/dev/null || true
  return 1
}

# 配置不全 = 你压根没打算用这个平台，跳过就好，【不要】把整个 job 标红。
# 界线划在这里：
#   缺配置        → 跳过（本函数），是正常状态
#   配了但用不了  → 报错（token 无效、上传失败、仓库不存在），必须响
# 混在一起的后果是：要么没配的人天天收失败邮件，要么真出事了没人发现。
#
# 用法: skip_unless_configured Gitee GITEE_TOKEN "$TOKEN" GITEE_REPO "$OWNER_REPO"
# 缺任何一项就打印 notice 并让当前 step 以【成功】退出。
skip_unless_configured() {
  local platform="$1"; shift
  local missing="" name val
  while [ $# -ge 2 ]; do
    name="$1"; val="$2"; shift 2
    [ -n "$val" ] || missing="${missing}${missing:+, }${name}"
  done
  [ -z "$missing" ] && return 0
  echo "::notice::${platform} 未配置（缺 ${missing}），跳过。这不是错误。"
  exit 0
}
