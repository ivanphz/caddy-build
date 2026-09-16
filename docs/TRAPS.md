# 踩过的坑

**这一份不是「最佳实践」，是账单。** 每一条都在这个仓库里真实发生过，
后面括号里是它当时的表现形式。改代码前扫一眼——这些形状会反复长回来。

---

## 1. `pipefail` + 会提前关闭读端的命令

```bash
set -o pipefail
printf '%s' "$body" | head -n1 | grep -q '^#!'   # grep 匹配成功
echo $?                                          # → 141
```

`grep -q` 一匹配就退出 → `head` 收 EPIPE 退出 → `printf` 再写就吃 SIGPIPE(141)
→ `pipefail` 取管道里最后一个非零状态，判整条失败。

**这个仓库栽过三次：**

| 位置 | 当时的表现 |
| :--- | :--- |
| `aws s3 ls … \| grep -q .` | 前缀明明存在却判为「不存在」，R2 完整性检查形同虚设，每次照样重传 140 MB |
| `curl … \| head -n1`（`latest_tag`） | 内容取到了却走进 `die` |
| `printf '%s\n' "$out" \| grep -qxF "$kv"`（自测） | **随机**假失败。实测 4000 次里 3 次；报错自相矛盾——「缺少 `current=none`」而实得里明明有 |

**判据不是「有没有用管道」，是「管道的退出码参不参与判断」。**
`die "…$(echo "$resp" | head -c 400)"` 是安全的——那是字符串参数，退出码没人看。

**写法**：

```bash
body="$(curl -sSL "$url")"          # 先整个取回变量
first="${body%%$'\n'*}"             # 用参数展开切
case "$first" in '#!'*) ;; esac

grep -q "$pat" <<< "$var"           # 断言用 here-string，不产生独立写入进程
```

> **测试代码要和生产代码守同一套规矩。** 前两次都是在生产代码里发现并修掉的，
> 第三次还是漏在了测试脚本上——测试代码天然比生产代码少受审视。
> 而一个 flaky 的检查，最终下场是被加上 `|| true`，
> 然后它保护的东西就再也没人管了。

---

## 2. 软 404：HTTP 200 + 一张 HTML 错误页

CNB 的 `/-/raw/` 对不存在的路径返回 **200**，而不是 404。`curl -f` 拦不住，
整页 HTML 被喂进 `bash`，报的是 `syntax error near unexpected token '<'`
——从错误信息完全看不出真正原因是地址形状写错了。

**凡是校验地址可用性的地方，必须连内容一起验：**

| 文件 | 判据 |
| :--- | :--- |
| `scripts/install.sh` | 首行是 `#!` |
| `manifest.txt` | 首行的键是 `contract` / `tag` / `install_sh` 之一 |
| release 资产 | `.sha256` 拉回来与本次构建逐字节比对 |

---

## 3. `$(f || true)` 挡不住 `f` 里的 `exit`

```bash
lt="$(latest_tag 2>/dev/null || true)"    # 直觉上「失败就算了」
```

`latest_tag` 失败走的是 `die → exit`，**`exit` 直接结束子 shell，
里面的 `|| true` 根本没机会执行**。命令替换返回非零，`errexit` 把整个脚本带走
——表现是 `--check` 一行不输出就退出码 1。

```bash
lt="$(latest_tag)" || lt=""               # || 必须放在父层
```

---

## 4. 把「失败」和「没有」混成一件事

三次，形状完全一样：

| 位置 | 后果 |
| :--- | :--- |
| `aws s3 ls … 2>/dev/null` 吞掉错误 | 凭据坏了却报告「release 不存在」，一路走到上传才抛 AccessDenied |
| `gh release download … \|\| echo '[]'` | 一次网络抖动就让变更日志把全部 18 个插件列成「新增」，还吞掉 Caddy Core 升级那一行，正文看着完全正常 |
| `--check` 对 contract 超版本的清单报 `would_change=yes` | 假绿灯：`--check` 说能装，`install` 在同一份清单上直接 die |

**规则**：缺配置 → 跳过（`::notice::`）；配了但用不了 → 报错。
两者用不同的退出码/输出键区分，**不要合并**。
合并的后果是调用方重新失去区分能力，而那正是加这层检查的初衷。

---

## 5. 分支猜测与平台路径形状

- Gitee 建仓默认 **`master`**，不是 `main`。写死 `main` 的后果是文件推到一个
  谁也看不见的分支，而仓库首页仍显示旧内容，安装链接 404
- raw 路径三家都不一样，**没有跨平台标准**：

| 平台 | 原始内容 | 文件页（HTML，不能当 raw 用） |
| :--- | :--- | :--- |
| GitHub | `raw.githubusercontent.com/{repo}/{ref}/` | `github.com/{repo}/blob/{ref}/` |
| Gitee | `gitee.com/{repo}/raw/{分支}/`（302 到 `raw.giteeusercontent.com`） | `gitee.com/{repo}/blob/{分支}/` |
| CNB | `cnb.cool/{repo}/-/git/raw/{分支}/` | `cnb.cool/{repo}/-/blob/{分支}/` |

**探测不到就报错，不要猜默认值。** `mirror.yml` 现在推完会拿
`scripts/install.sh` 逐个试候选基址，全试不通就报错并列出每个候选的结果。

---

## 6. 服务端 raw 缓存：`git push` 成功 ≠ raw 读得到

Gitee 公开仓库的 raw 数据在服务端缓存 60~300 秒，而且**不同文件不同时失效**。
实测现象：同一次装机里 `dist/Caddyfile` 拿到了、`dist/index.html` 还是 404，
过一会儿两个都好了。

对策：`mirror.yml` 推完回读一遍，读不到等 30 秒再试一轮；
`install.sh` 取不到 `dist/*` 时自动回落 `CADDY_RAW_FALLBACK`。

---

## 7. 整文件覆盖会悄悄回退 Dependabot

`.github/workflows/*.yml` 同时是 Dependabot 的地盘。用整文件覆盖的方式交付改动，
会把合并过的版本升级打回去，**而且没有任何冲突提示**——覆盖不是合并。

证据：同一个 `bump actions/checkout from 4 to 7` 被开了两次，
两次都是「from 4」——说明仓库在中间回到过 v4。

对策：每次只动真正改过的文件；覆盖工作流前先 `grep -rn "uses:" .github/workflows/`。

---

## 8. 重要约束不要只写在交付说明里

「`build.yml` 必须一起合」这条只写在临时的 `_APPLY.md` 里，
结果是：漏掉它时清单照样生成、CI 照样全绿、什么都不报，
只是 `install_sh` 悄悄退回指向分支。

**约束要写进代码才拦得住，写进文档只是希望。**
现在 `build.yml` 里有一条断言：`install_sh` 的 URL 必须包含当前 tag，
否则 release job 直接红。

---

## 相关文档

- [design.md](design.md) —— 设计取舍（为什么这么做）
- [.github/workflows/README.md](../.github/workflows/README.md) —— 容错约定、所需 Secret
- [../CONTRACT.md](../CONTRACT.md) —— 下游消费契约，及它的可执行版本
