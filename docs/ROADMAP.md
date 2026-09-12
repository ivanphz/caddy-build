# 待开发

按「不做的代价」排，不按工作量排。做完划掉并注明日期。

---

## 1. 架构与资产名的单一真源

**现状**：`caddy-linux-amd64` / `caddy-linux-arm64` 这两个名字散在至少 6 处 ——
`build.yml` 的 matrix、`mirror.yml` 的 `ASSETS`、`install.sh` 的
`asset="caddy-linux-${arch}"`、`README.md`、`mirror/README.md`、`bench-mirror.sh`。

**代价**：加一个架构（armv7 / riscv64 / darwin）要改 6 个地方，漏一个就是
「构建出来了但镜像不同步」或「镜像有了但装不上」，而且**不会有任何报错**。

**方向**：真源是 build matrix。让 build job 产出一份机器可读的资产名单
（清单里已经有了——`manifest.txt` 的资产行就是），下游一律读它而不是各自硬写。
`mirror.yml` 的 `ASSETS` 可以从上一版清单推导；`install.sh` 已经能查清单，
只剩 `asset=` 那行还在拼。

> 已经做掉一半：`mirror-lib.sh` 的 `MIRROR_REPO_FILES` 统一了「要同步哪些仓库文件」，
> git 型和对象存储型共用一份。以前这份名单写了两遍，结果 `dist/` 只有 R2 那边有。

---

## 2. 把「走哪条路」从代码里挪到配置里

**现状**：哪个平台走什么通道是写死在代码里的 ——

| | 通道 | 写在哪 |
| :--- | :--- | :--- |
| Gitee | SSH 中转（可选）或直连 | `mirror.yml` 里 Gitee 那个 step 独有的 ~90 行 |
| CNB | 只能直连 | 没得选 |
| R2 | 只能直连 | 没得选 |
| `bench-mirror.sh` | `PROXY=` 一个环境变量，全局生效 | 和上面完全另一套 |
| `install.sh` | `GH_MIRROR` / `CADDY_RAW_BASE` / `CADDY_SOURCE` | 客户端侧，又是另一套 |

**实测数字**（2026-09-12，同一次发布，同样两个文件共 138 MB）：

| 平台 | 通道 | 上行 | 耗时 |
| :--- | :--- | ---: | ---: |
| Gitee | 香港 SSH 中转 | ~5.1 MB/s | 27 秒 |
| CNB | runner 直连 | ~316 KB/s | **441 秒** |
| R2 | runner 直连 | ~6.4 MB/s | 22 秒 |

**CNB 一家占掉整个 mirror job 的七分半。** 中转机就在那儿、Gitee 走它快 16 倍，
但 CNB 用不上 —— 因为那 90 行中转代码长在 Gitee 的 step 里。
抽出 transport 层之后，这件事是改一行 YAML。

**代价**：
- 想让 CNB 也走香港中转 → 只能把那 90 行复制一遍，然后两份各自腐烂
- 想临时换一台中转机 → 改的是代码不是配置
- 想让某个平台走 HTTP/SOCKS 代理而不是 SSH 中转 → 没有这个概念
- 三套「怎么出去」的写法互不相通，学会一套不代表看得懂另一套

**方向**：抽一层**传输通道（transport）**，和平台适配器正交。

```yaml
# .github/mirror-transports.yml —— 只描述形状，凭据仍在 Secrets
transports:
  direct:      { type: direct }
  hk-relay:    { type: ssh,   host_secret: RELAY_HK_HOST, key_secret: RELAY_HK_KEY }
  tokyo-proxy: { type: proxy, url_secret: PROXY_TOKYO_URL }   # curl --proxy 语法

platforms:
  gitee: hk-relay
  cnb:   direct
  r2:    direct
```

实现上 `mirror-lib.sh` 多一个 `transport_*` 层，`platform_upload_assets` 通过它发文件；
现在 Gitee 那 90 行中转代码变成 `transport_ssh`，**任何平台都能用**。
换中转机 = 改一行 YAML；某个平台临时走代理 = 改一行 YAML。

客户端侧同理：`/etc/caddy/sources.conf` 里定义 2~3 个命名源（GitHub / Gitee / 自建 R2），
`CADDY_SOURCE_PROFILE=r2` 选一个，或者不选就按顺序探测哪个通。
现在这些只能靠一长串环境变量表达，且装完就固化进 `caddy-update`，换源要重装。

**注意**：凭据（SSH 私钥、代理密码）永远不进配置文件，配置里只放 Secret 的**名字**。

---

## 3. 清掉剩下的硬编码

**范围**：架构名除外（那是 #1 的事）。清点如下。

### 真该改的

| 位置 | 现状 | 该怎样 |
| :--- | :--- | :--- |
| ~~`install.sh` 的目录常量~~ | ~~全部写死~~ | ✅ **2026-09 已做**：`CADDY_CONF_DIR` / `CADDY_DATA_DIR` / `CADDY_LOG_DIR` / `CADDY_SITE_DIR` / `CADDY_UNIT` 五个一起开。触发点是可测性——`CONF_DIR` 写死导致契约自测必须能写真实 `/etc/caddy`，**测不了的东西就没人测** |
| `bench-mirror.sh` 的用法示例 | 注释里写死 `ivanphz/caddy-build` / `ivanabc/caddy-build` | 换成 `<owner>/<repo>` |
| `install.sh` 头部注释的安装地址 | 写死完整 URL | 同上 |
| 服务名 `caddy` | unit 名、用户名、组名都硬编码 `caddy` | 同机装两份（比如一个测试实例）时会打架 |

### 不算硬编码，别动

| 东西 | 为什么 |
| :--- | :--- |
| `gitee.com` / `cnb.cool` / `*.r2.cloudflarestorage.com` | 适配器**就是**那个平台，抽出来只会多一层没人配的间接 |
| `install.sh` 的 `REPO` 默认值 | 脚本是被 `curl \| bash` 的，没法从自身位置反推仓库，必须有默认值；已可用 `CADDY_REPO` 覆盖 |
| `raw.githubusercontent.com` / `cdn.jsdelivr.net` / `ghfast.top` | 都只是默认值，`CADDY_RAW_BASE` / `CADDY_SOURCE` / `GH_MIRROR` / `CADDY_RAW_FALLBACK` 全能覆盖 |
| `PLATFORM_DEFAULT_BRANCH` | 是「这个平台建仓默认叫什么」的事实（Gitee=master / CNB=main），且有 `*_BRANCH` 可覆盖 |

### 魔数：已经有变量的和还没有的

已可配：`KEEP_RELEASES`、`GITEE_KEEP` / `CNB_KEEP` / `R2_KEEP`、`MIN_MODULES`、
`PROGRESS_INTERVAL`、`R2_CACHE_SECONDS`。

还写死的：`--max-time 1800`（单文件传输上限）、`per_page=100` / `--limit 500`
（分页大小）、中转机 `-ge 300`（磁盘余量 MB）、`max-age=31536000`（不可变对象缓存）。
这些是内部实现细节，**优先级低于上面那张表** —— 改成变量的收益还不如加注释说明取值理由。

---

## 4. Docker 编译与推送

**为什么现在能做**：版本号 `v2.11.4-20260813.1110` 本来就是 Docker tag 安全的
（当初刻意没用 `+`）；`CGO_ENABLED=0` + `-tags nobadger,nomysql,nopgx` 产出的是
静态二进制，distroless / scratch 镜像很直接。

**形状**：新增 `.github/workflows/docker.yml`，由 `build.yml` 在 release 之后
`workflow_call` 调用，复用 `init` 的 `version_tag`。多架构用 buildx，
amd64 + arm64 直接塞已经编好的二进制进去，不要在镜像里重新 `go build`。

**推去哪**：GHCR 一定要有；国内可以推 CNB 的 `docker.cnb.cool` 或阿里云 ACR。
推送层同样走 `mirror.yml` 的适配器模式，别再开一套。

---

## 5. 浅克隆上 rebase

**现状**：`update_deps.yml` / `sync_dist.yml` 用 `actions/checkout` 的默认
`fetch-depth: 1`，却在之后执行 `git pull --rebase --autostash`。

**代价**：至今没炸不代表安全。浅历史上 rebase 在特定情形下会失败，
表现为「依赖更新提交不上去」，而下游构建完全没有感知。

**方向**：这两个 workflow 的 checkout 加 `fetch-depth: 0`。代价是克隆慢几秒。

---

## 6. bench-mirror.sh 支持 R2

**现状**：只能测 Gitee / CNB。

**代价**：不大。但 R2 的上传速度（实测 runner → R2 约 6.4 MB/s，
比 CNB 的 304 KB/s 快一个数量级）目前没有任何工具能复现测量，
换区域或换账户时只能靠 workflow 跑一次看日志。

**方向**：加一个 `r2` 子命令，走 `aws s3 cp` 到一个临时 key 再删掉，
沿用现有的 `trap` 清理机制。

---

## 7. Go 版本会漂

**现状**：`build.yml` 用 `go-version: 'stable'` + `check-latest: true`。

**代价**：同一份 `go.mod` 在不同日期编出的二进制不一定逐字节相同。
对这个项目影响有限（没有声称可复现构建），但排查「上周还好好的」类问题时
会多一个变量。

**方向**：要么钉死小版本，要么在 release notes 里记录实际使用的 Go 版本
（`go_modules.json` 已经有了，但正文里没体现）。属于「知道就好」。

---

## 8. `caddy-update` 在编排管理的机器上是条死路径

**现状**：整条链路上，只有 `install.sh` 本身是活动引用。

| 东西 | 有没有版本 | 能不能回滚 |
| :--- | :--- | :--- |
| 二进制 | tag | ✅ 用旧 tag |
| 清单 | release 资产，随 tag 不可变 | ✅ 用旧清单 |
| 契约 | `contract` 整数 | ✅ 消费者按范围拒绝 |
| 清单里的 `install_sh` | 已钉到 tag（2026-09 修） | ✅ |
| **`caddy-update` 自己取的 `install.sh`** | **分支** | ❌ |

`write_helper` 把 `CADDY_RAW_BASE` 固化进 `/usr/local/bin/caddy-update`，
每次运行都从那个**分支**地址重新取 `install.sh`，而且**不读清单里的 `install_sh` 键**。

这里有两个不同的机群，走两条不同的升级路，`install_sh` 钉 tag 只解决了其中一条：

| 机群 | 升级路径 | 钉清单管不管用 |
| :--- | :--- | :--- |
| 舰队机（编排统一管） | 编排自己取 `install.sh` | ✅ 管用——编排改成读清单的 `install_sh` 键即可 |
| 手工装的机器 | `caddy-update` → `RAW_BASE`（分支） | ❌ 不管用 |

**优先级重估**：舰队机上 `caddy-update` 是**装了但从不使用**的死路径。
真正的风险不是「升级会坏」，而是——

> 有人 SSH 上去手工跑一次 `caddy-update`，就绕开了编排的单点写入者模型，
> 那台机器的版本从此和编排记录的对不上，而且没有任何东西会报。

**已做的便宜解**（2026-09）：`NO_HELPER=1` —— 编排装机时干脆不写这个入口，
和 `NO_SERVICE=1` 同形。休眠的违反项从此不存在。

**剩下的**：手工装的机器仍然走分支。彻底解法是让 helper 改成
「先取清单 → 用清单里的 `install_sh`」，这样 `install.sh` 也变成发布门控的。
**代价**：`install.sh` 的修复必须切一个 release 才发得出去；而且改的是跑在
几十台机器上的升级路径，**风险不对称**——升级路径本身出问题时没有别的路可走。
真要做，先让新旧两种 helper 并存一个发布周期。

---

## 9. 别让整文件覆盖悄悄回退 Dependabot

**现状**：改动以「整文件覆盖」的方式落到仓库。而 `.github/workflows/*.yml`
同时也是 **Dependabot 的地盘** —— 它每月会去改那里的 `uses:` 行。

**代价**（实测发生过）：合并了 5 个 Dependabot 升级 PR，下一轮覆盖工作流文件时
全部被打回旧版本，而且**没有任何冲突提示** —— 覆盖不是合并，不会有冲突。
表现是「明明合过了，构建日志里还是老版本告警」。

**方向**（按成本排）：

1. 每次只动真正改过的文件，没改的不要重新覆盖一遍 —— 零成本，最有效
2. 覆盖工作流文件前先对一眼当前 `main`：
   ```bash
   grep -rn "uses:" .github/workflows/*.yml
   ```
3. 彻底一点：把 `uses:` 的版本集中到一处（composite action 或
   `.github/actions/` 下的本地封装），工作流只引本地封装。
   这样 Dependabot 和手工改动就不在同一个文件里打架了。

---

## 记录

| 日期 | 做掉了什么 |
| :--- | :--- |
| 2026-08 | 镜像流程抽到 `mirror-lib.sh`，Gitee / CNB / R2 共用一套适配器 |
| 2026-08 | 资产完整性检查：齐全就跳过上传，不再每次重传 140 MB |
| 2026-08 | `manifest.txt`：不再靠拼 URL 定位资产 |
| 2026-09 | 下游消费契约（`CONTRACT.md`）：`contract` 版本号、`--check`、清单发到 GitHub |
| 2026-09 | Actions 全部升到 Node 24 运行时（Node 20 于 2026-09-16 从 runner 移除） |
| 2026-09 | 三个平台 + GitHub 全链路跑通并实测：清单、契约、完整性检查、缓存头 |
| 2026-09 | 文档按读者角色拆成 6 份，README 从 974 行减到 85 行 |
| 2026-09 | `--check` 补上清单契约校验与 stderr 诊断；GitHub 清单的 `install_sh` 钉到 tag |
| 2026-09 | 安装路径五个目录全部可覆盖；新增 `NO_HELPER=1` |
| 2026-09 | `scripts/contract-selftest.sh`（19 条断言）+ CI 变异检测；镜像内容一致性绊线 |
