# 下游消费契约

本仓库对**自动化消费者**（脚本、舰队编排）的承诺。面向人类的用法看
[`docs/install.md`](docs/install.md)。

契约的核心是一句话：**消费者永远只查清单，不拼 URL。**

---

## 契约版本

唯一真源是 `scripts/install.sh` 里的这一行：

```bash
CONTRACT_VERSION=1
```

`mirror.yml` 和 `build.yml` 都用 `awk` 从这里抠，不在别处再写一遍数字。

**当前值：`1`**

| 变更 | contract |
| :--- | :--- |
| 加资产、加清单行、加 `--check` 的输出键、改 URL | 不变 |
| 删/改已有清单键的含义、改环境变量语义、改退出码 | **+1** |

消费者两种方式拿到它：

```bash
install.sh --contract-version          # 打印一个整数
awk -F'\t' '$1=="contract"{print $2}' manifest.txt
```

`install.sh` 自己也会检查：清单声明的 `contract` 大于它支持的值时**拒绝安装**
并说明原因，而不是装到一半失败。没有 `contract` 行的老清单按 `1` 处理。

---

## 清单

TSV，每行 `key<TAB>value`。用纯文本而非 JSON，是为了不给 `install.sh` 引入 `jq` 依赖。

```
contract                   1
tag                        v2.11.4-20260813.1110
install_sh                 https://.../scripts/install.sh
caddy-linux-amd64          https://.../caddy-linux-amd64
caddy-linux-amd64.sha256   https://.../caddy-linux-amd64.sha256
caddy-linux-arm64          https://.../caddy-linux-arm64
caddy-linux-arm64.sha256   https://.../caddy-linux-arm64.sha256
```

`install_sh` 指向**该清单所在源自己的** `install.sh`，不指回 GitHub。清单解决的是
「拼不出 URL」，指回 GitHub 等于把问题留在最后一米——国内机器拿到清单后下一跳
还是出不了墙。所以：

| 清单来自 | `install_sh` 指向 |
| :--- | :--- |
| GitHub Release | `raw.githubusercontent.com/<repo>/<tag>/scripts/install.sh` |
| Gitee | `gitee.com/…/raw/master/scripts/install.sh` |
| CNB | `cnb.cool/…/-/git/raw/main/scripts/install.sh` |
| R2 | `<你的域>/caddy/main/scripts/install.sh` |

消费者拿到清单之后**不需要再推断任何路径**。

### 为什么 GitHub 那条钉了 tag

清单是不可变的 release 资产，里面每一项都该是不可变的。指向 `main` 等于在
「某一版的快照」里塞一个活动引用——往 `main` 推一个坏的 `install.sh`，
所有按清单消费的机器下一次全都坏，而且**没有回滚路径**。钉到 tag 之后
每份清单都是自洽可复现的单元，回滚就是用旧清单。

代价是 `install.sh` 的修复要切一个 release 才发得出去。这个代价是对的：
改的是跑在几十台机器上的东西，本来就该走发布流程。

镜像那三条看起来是分支引用，但性质不同：

> **不变量**：镜像仓库只接受发布流水线的推送。
> `main` 会收手工提交，镜像分支不会——所以镜像分支上的 `install.sh`
> 永远等于「最近一次发布的那份」。
>
> **若将来允许手工往镜像推，本决定必须重新评估**，届时镜像清单的
> `install_sh` 也要钉 tag。

这条不靠人记：`mirror.yml` 每次推完会回读镜像上的 `scripts/install.sh`，
**与本次发布的那份逐字节比对**，对不上就告警。手工热修、缓存没刷新、
推丢了，三种情况都会在镜像那一步当场暴露，而不是等某台机器装出问题。

> 唯一还没版本化的是 `caddy-update` 自身的自更新链路（它按安装时固化的
> `CADDY_RAW_BASE` 取 `install.sh`，走的是分支）。见
> [docs/ROADMAP.md](docs/ROADMAP.md)。

### 清单在哪

| 源 | 地址 |
| :--- | :--- |
| GitHub | `https://github.com/ivanphz/caddy-build/releases/latest/download/manifest.txt` |
| Gitee | `https://gitee.com/<owner>/<repo>/raw/master/manifest.txt` |
| CNB | `https://cnb.cool/<owner>/<repo>/-/git/raw/main/manifest.txt` |
| R2 | `<公开域>/caddy/main/manifest.txt` |

> **`raw.githubusercontent.com/.../main/manifest.txt` 不存在，会 404。**
> 清单不提交进仓库——它每次发布都变，提交进去只会制造噪音提交和一个必然过期的副本。
> GitHub 侧它是 **release 资产**，用上面那个 `releases/latest/download/` 地址，
> 由 GitHub 转到当前最新一版。

清单只描述**最新一版**。要装指定旧版本，用 `CADDY_REL_BASE` + `CADDY_TAG`，
不要用清单——同时设了清单和对不上的 `CADDY_TAG`，`install.sh` 会**直接报错停下**。

### 软 404

有平台（实测 CNB 的 `/-/raw/`）对不存在的路径返回 **HTTP 200 + 一张 HTML 错误页**，
`curl -f` 完全拦不住，整页 HTML 会被喂进 `bash`，报的是
`syntax error near unexpected token '<'`。

`install.sh` 已经自己挡住了清单这一环：拉回来先看首行的键是不是
`contract` / `tag` / `install_sh`，不是就当场说清楚。**消费者不必再自己判。**

但**取 `install.sh` 本身**这一跳在我们的保护范围之外（那时脚本还没开始跑）。
消费者管道进 `bash` 之前应该先看头两个字节是不是 `#!`：

```bash
tmp="$(mktemp)"
curl -fsSL "$install_url" -o "$tmp"
head -c2 "$tmp" | grep -q '^#!' || { echo "取到的不是脚本，多半是软 404"; exit 1; }
sudo CADDY_MANIFEST="$manifest" bash "$tmp"
```

---

## `install.sh --check`

只探测，不动机器。

```bash
install.sh --check
```

stdout **只有** `key=value` 行，诊断信息一律走 stderr：

```
contract=1
manifest_contract=1
current=v2.11.3-20260701.0900
latest=v2.11.4-20260813.1110
would_change=yes
service_active=yes
```

| 键 | 取值 |
| :--- | :--- |
| `contract` | **本机这份 `install.sh`** 的契约版本 |
| `manifest_contract` | **清单声明**的契约版本。**无条件输出**：没用清单时是 `none`，清单读不到时是 `unknown`。条件出现的键是坑——消费者写 `[ "$mc" -le 1 ]` 会在没有清单的机器上拿到空串然后报 `integer expression expected` |
| `current` | 已装的 tag；没装是 `none`；装了但没状态文件是 `unknown` |
| `latest` | 目标版本；探测不到是 `unknown` |
| `would_change` | `yes` / `no` / `unknown` |
| `service_active` | `yes` / `no`；机器上没有 systemd 时是 `unknown` |

退出码也是契约的一部分：

| 码 | 含义 | 该采取的动作 |
| :--- | :--- | :--- |
| `0` | 探测成功（**不管有没有新版本**） | 看 `would_change` |
| `1` | 探测失败 | 见下 |
| `3` | 本机没装 caddy | 装 |

`1` 涵盖两类原因，**动作完全不同**，靠 `manifest_contract` 区分：

| 原因 | `manifest_contract` | 动作 |
| :--- | :--- | :--- |
| 网络不通 / 源地址错 / 清单取到的是 HTML | `none` 或 `unknown` | 重试、查网络 |
| **清单契约版本高于本机 `install.sh`** | 一个大于 `contract=` 的整数 | **更新全网 install.sh**，重试永远不会好 |

**为什么不给契约不兼容单独一个退出码**：新增退出码是 contract +1，代价太大；
而区分能力并没有丢——契约不兼容是**全网同时发生**的（大家读的是同一份清单），
表现为几十台一起 `rc=1`，和「五台零散失败」一眼能分；真要精确判，
输出里的 `manifest_contract` 就是那个判据。

**`1` 和 `3` 同时成立时返回 `1`** —— 真故障压过正常结论。反过来的话，
一批网络不通的机器会被报成「未安装」，然后你去装，然后装不上。

契约超版本时 `--check` 返回 `1` 而不是 `would_change=yes`：contract 变大意味着
已有键的含义可能变了，那就连里面的 `tag` 都不该照读。少了这一步，`--check` 会对
一份**注定装不上去**的清单开绿灯，而 `install` 在同一份清单上直接 die ——
「先问再决定」就白问了。

rc 非 0 时，原因**一定会打在 stderr 上**（stdout 仍然只有 `key=value`）。
扫一批机器时那几台 `rc=1` 不会只剩「不知道为什么」。

「有新版本」绝不用非零表达——`--check` 回答的是问句不是命令。混在一起会让调用方
分不清「有更新」和「探测失败」，而这两件事在几十台机器的扫描结果里是完全不同的
处理方式。

`3` 单独分出来，是因为「没装」对舰队审计是个正常结论，不该和真故障混为一谈。
只关心「有没有真问题」的话判 `!= 1` 即可；四个键在任何退出码下都会打印。

不需要 root，不需要网络以外的任何权限。

---

## 已经承诺、不会悄悄改的

| 东西 | 承诺 |
| :--- | :--- |
| `CADDY_TAG` | 装/回退到指定版本 |
| `CADDY_MANIFEST` | 清单地址，绕开一切 URL 拼接 |
| `CADDY_RAW_BASE` / `CADDY_REL_BASE` | 换源 |
| `CADDY_TAG_FILE` | 纯文本版本指针（R2 的 `latest.txt`） |
| `NO_SERVICE=1` | 只换二进制不碰 systemd |
| `NO_HELPER=1` | 不写 `/usr/local/bin/caddy-update`。**被编排统一管理的机群应该用它** —— 留着一个没人用的更新入口，谁手工跑一次就绕开了编排的单点写入，而且没有任何东西会报 |
| `CADDY_CONF_DIR` / `_DATA_DIR` / `_LOG_DIR` / `_SITE_DIR` / `CADDY_UNIT` | 覆盖安装路径 |
| 清单与 `CADDY_TAG` 对不上时 **die** | **正确行为**，防静默错版，不会改成「警告后继续」 |
| 安装顺序 | 下载 → 校验 SHA256 → 备份 → 原子替换 → validate → 重启 → 确认存活，任一步失败自动回滚 |
| 旧仓库名 `my-custom-caddy` 的重定向 | 不会新建同名仓库 |

改动其中任何一条 = `contract` +1。

---

## 契约的可执行版本

写在 Markdown 里的承诺会漂，写成断言的不会。
[`scripts/contract-selftest.sh`](scripts/contract-selftest.sh) 是本文档的可执行版本，
19 条断言，不需要网络、不需要 root、不碰真实系统目录：

```bash
scripts/contract-selftest.sh                       # 默认测 scripts/install.sh
scripts/contract-selftest.sh /path/to/install.sh   # 测任意一份
```

CI 在 `install.sh` 或这个脚本本身变更时自动跑（`.github/workflows/selftest.yml`）。

> **怎么知道这套测试本身有效**：它必须能在打断了对应行为的代码上失败。
> 实测四种变异各自只打红对应用例：条件输出 `manifest_contract` → `J` 红；
> 吞掉 `latest_tag` 的诊断 → `L2` 红；契约超版本不拒绝解读 → `G` 红；
> 去掉子 shell 预探（同一原因报三遍）→ `K`/`L` 红。
>
> `L2` 就是变异测试逼出来的：原来只有 `K`/`L`，两条走的都是**清单**那条路，
> 而清单的诊断来自子 shell 预探——给 `latest_tag` 加回 `2>/dev/null` 仍然全绿。
> 不走清单的那条路径必须单独测。

## 消费端最小实现

```bash
manifest="https://github.com/ivanphz/caddy-build/releases/latest/download/manifest.txt"

m="$(mktemp)"
curl -fsSL "$manifest" -o "$m"
get() { awk -F'\t' -v k="$1" '$1==k{print $2; exit}' "$m"; }

# 1. 契约版本在支持范围内才继续
cv="$(get contract)"; cv="${cv:-1}"
[ "$cv" -le 1 ] || { echo "上游 contract=$cv，本编排只支持到 1"; exit 1; }

# 2. install.sh 的地址直接从清单取，不推断
install_url="$(get install_sh)"

# 3. 下回来验一下是脚本再跑
s="$(mktemp)"
curl -fsSL "$install_url" -o "$s"
head -c2 "$s" | grep -q '^#!' || { echo "取到的不是脚本"; exit 1; }

# 4. 先问，再决定动不动
out="$(bash "$s" --check)"; rc=$?     # --check 不需要 root
[ "$rc" -ne 1 ] || { echo "探测失败，原因见上面的 stderr"; exit 1; }
case "$out" in *would_change=yes*) sudo CADDY_MANIFEST="$manifest" bash "$s" ;; esac
```
