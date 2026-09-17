# 构建与发布

面向**要改这条流水线的人**。每个 workflow 的触发条件、job 拆分和所需
Secret / Variable 在 [.github/workflows/README.md](../.github/workflows/README.md)，
本文讲的是它们背后的链路和策略。

## 工作原理

```
caddyserver/dist ──> Sync dist assets (每周一 18:00 / 手动)
                       校验后提交 dist/，不触发重新编译

plugins.txt
    │
    ├─ Update Dependencies (每周五 18:00 / 改 plugins.txt / 手动)
    │     解析 replace 的分支 → pseudo-version
    │     go get 各插件 @latest
    │     生成 main.go   ← 唯一真源，不再有 tools.go
    │     go mod tidy
    │     试编译一次（不过就不提交）
    │     提交 go.mod / go.sum / main.go  ← 用 PAT，否则不触发下游 workflow
    │
    └─ Build Custom Caddy (go.mod / go.sum 变更时触发)
          go mod verify           ← 不跑 tidy，-mod=readonly 保证可复现
          go build × {amd64, arm64}
          冒烟测试：caddy version 是否与上游一致、模块数是否合理
          对比上一个 Release 的 go_modules.json 生成变更日志
          发 Release → 清理旧 Release
             └─ Mirror → Gitee / CNB / R2（各自没配就跳过，不报错）
```

只看 `go.mod` / `go.sum` 而不看 `main.go`：`main.go` 的任何实质变更都必然伴随这两者变化，
单独改 `main.go`（比如 `plugins.txt` 只调了顺序）产出的二进制是一样的，不值得重建。

每个 workflow 的详细职责、触发条件和所需 Secret 见
[`.github/workflows/README.md`](../.github/workflows/README.md)。

版本号形如 `v2.11.4-20260807.1930`（Asia/Shanghai），由 `init` job 统一生成，两个架构共用同一个 tag。

编译参数与 Caddy 官方一致：`-trimpath -ldflags "-w -s" -tags nobadger,nomysql,nopgx`（排除 BadgerDB / MySQL / PostgreSQL 存储后端以缩小体积）。**刻意不注入 `CustomVersion`** —— 理由见下面「版本号」一节。`main.go` 里 import 了 `time/tzdata`，所以在没有系统时区库的精简环境下 `@` 时间匹配器一样能用。

## 仓库结构

```
plugins.txt                        ★ 插件清单，唯一需要手动编辑的文件
main.go                            自动生成，勿手改
go.mod / go.sum                    自动生成，勿手改

dist/Caddyfile                     → /etc/caddy/Caddyfile（仅当不存在时）
dist/index.html                    → /usr/share/caddy/index.html
dist/UPSTREAM.md                   同步来源与上游 commit 记录

mirror/README.md                   镜像仓库用的精简 README 模板
                                   （占位符由 mirror.yml 按平台替换）

README.md                          入口与导航
CONTRACT.md                        下游消费契约（给脚本看的）
docs/install.md                    安装 / 更新 / 卸载 / 换源 / 运维
docs/mirrors.md                    Gitee / CNB / R2 的配置与排障
docs/plugins.md                    插件清单与增删
docs/build.md                      ← 本文
docs/design.md                     设计取舍
docs/TRAPS.md                      踩过的坑（改代码前扫一眼）
docs/HANDOFF-NEW-CHAT.md           新开 AI 对话时整份贴进去的交接（每轮结束更新第 3 节）
docs/ROADMAP.md                    待开发
scripts/install.sh                 安装 / 更新 / 卸载 / 探测
scripts/contract-selftest.sh       CONTRACT.md 的可执行版本，20 条断言
scripts/contract-mutation-check.sh 验证自测本身有效（四条变异）
scripts/lint-workflow-env.py       查 workflow 里跨 step 失效的 env 引用（带 --selftest）
scripts/release_notes.py           Release 正文生成
scripts/mirror-lib.sh              分发流程（平台无关），被 mirror.yml source
scripts/ci-lib.sh                  CI 共用小工具（目前只有网络重试）
scripts/bench-mirror.sh            镜像链路测速，选中转机用（不参与流水线）

.github/workflows/README.md        ★ 各 workflow 的职责与配置总览
.github/workflows/update_deps.yml  依赖解析
.github/workflows/build.yml        编译与发布
.github/workflows/sync_dist.yml    从 caddyserver/dist 同步打包资产
.github/workflows/mirror.yml       分发到 Gitee / CNB / R2（由 build.yml 调用）
.github/workflows/selftest.yml     契约自测 + 变异检测 + workflow env 作用域检查
.github/dependabot.yml             Actions 版本自动跟进（不管 Go 依赖）
.gitattributes                     强制 LF，防 CRLF 混入 plugins.txt
```

加一个分发平台 = 在 `mirror.yml` 里复制一个 step、实现 6 个 `platform_*` 函数，
`mirror-lib.sh` 一行都不用改。适配器契约写在 `mirror-lib.sh` 顶部。

`scripts/bench-mirror.sh` 是运维工具不是流水线的一环 —— 放在仓库里是为了版本化管理、
随手 `scp` 到候选机器上就能跑，本身不被任何 workflow 引用。

三层职责：**根目录 = 构建输入与产物**，`dist/` = 部署资产（不参与编译），
`scripts/` = 工具。

`dist/` 下的文件由 `sync_dist.yml` 每周一从 `caddyserver/dist` 自动同步，与上游
逐字节一致 —— 就是 `apt install caddy` 会给你的那套默认配置和欢迎页。之所以同步
进仓库而不是让 `install.sh` 直接从上游拉：`dist/Caddyfile` 会落到 `/etc/caddy/`，
走 CI 的话上游任何变动都先变成一个可审查的 commit，而不是无声地进到新装的机器上;
同时安装路径只依赖本仓库一个来源，一个 `GH_MIRROR` 覆盖全部，且任一 commit 都是
自洽快照。当前同步状态见 [`dist/UPSTREAM.md`](../dist/UPSTREAM.md)。

不想要欢迎页：

```bash
curl -fsSL .../install.sh | sudo WELCOME=0 bash
```

此时 Caddyfile 仍然用官方那份，只是不放 `index.html`，根路径返回 404。

`/usr/share/caddy/` 同时是默认站点根目录，所以 `install.sh` 会记一份欢迎页的
sha256 到 `/etc/caddy/.welcome-sha256`：指纹对得上说明这页是脚本自己写的、
可以覆盖；对不上（你换成了自己的内容）就保留不动并提示 —— 与 Caddyfile
「已有一律不动」的处理保持一致。想换回官方欢迎页，删掉 `index.html` 再
`caddy-update` 即可。

## 版本号

**`caddy version` 输出的就是真正的 Caddy 版本**，和官方二进制、和 xcaddy 构建完全同形：

```
$ caddy version
v2.11.4 h1:...
```

这是刻意的：这个产物**就是 Caddy，只是多带插件**，不应该伪装成另一个东西。
构建时没有设 `-X ...CustomVersion=` —— 那个变量会整个替换掉 Caddy 自报的版本，
任何按 Caddy 版本做判断的脚本、文档查询、issue 上报都会拿到一串它不认识的东西。
不设它时，Caddy 从 `debug.ReadBuildInfo()` 读依赖 `caddy/v2` 的版本，行为与上游一致。

Release tag 是**仓库侧的标识**，不进二进制：

```
v2.11.4-20260807.1930
└─────┘ └──────┘ └──┘
 上游核心  构建日期  时分
```

带上核心版本，是为了在 Releases 页面上一眼看出每次构建对应哪个 Caddy；
用日期而非递增构建号，是因为旧 release 会被自动清理，靠数已有 release 递增会重号。

**插件版本不进 tag。** 18 个插件会让 tag 长到没法读，且插件版本已经记录在三个地方：
release notes 的表格、随 release 发布的 `go_modules.json`、以及二进制自带的
`caddy build-info`。tag 是标识符，不是清单。

```bash
caddy build-info                  # 完整依赖树及版本
caddy list-modules --versions     # 已注册模块
```

## Release 保留策略

每次成功发布后，`build.yml` 会自动删除超出保留数量的旧 release（连同 tag），
默认保留最近 **12 个**。想改就在 Settings → Secrets and variables → Actions →
Variables 里加一个 `KEEP_RELEASES`，脚本内置下限为 3。

为什么要清理 —— 不是为了省空间。GitHub 对 release 的总大小和带宽都没有限制，
放着不管也不会有人来找你。真正的理由是**旧构建是负债**：一年前的二进制里带着
一年份未修补的 Caddy 与依赖 CVE，而 `CADDY_TAG=` 能一键把它装回任何一台机器。
留一排能一键安装的过期二进制，本身就是个降级攻击面。

按每 8~9 天一个版本的实际节奏，保留 12 个约等于 3 个月。插件更新真出问题，
你几天内就会发现；超过两三个月的构建，回滚过去比不回滚更危险。

清理逻辑按创建时间倒序跳过前 N 个，**刚发布的那个必然排第一，不会被误删** ——
这点很重要，`build.yml` 的插件变更对比要从 `releases/latest` 下载
`go_modules.json`，最新版必须保住。


## 需要的 Secret 与 Variable

完整清单见 [.github/workflows/README.md](../.github/workflows/README.md#需要的-secret--variable)。
只有 `PAT` 是必需的（`Update Dependencies` 用它提交——`GITHUB_TOKEN` 的推送
不会触发 `build.yml`），其余全部不配就跳过对应功能。

## 校验与信任

每个 Release 都附带 `.sha256`，正文里也有一份。另外还发布了：

- `main.go` — 本次编译实际使用的入口文件，可以核对到底编进去了哪些插件
- `go_modules.json` — 完整依赖快照，可以核对每个模块的精确版本

安装脚本默认校验 SHA256，失败会中止。

插件都是从各自上游 `@latest` 拉的，这意味着上游一旦被投毒，下一次周五构建就会带进来。介意的话可以在 `plugins.txt` 里把版本钉死（用 `original=original@v1.2.3` 的形式）。


---

| 文档 | 内容 |
| :--- | :--- |
| [README](../README.md) | 项目是什么、一条命令装上 |
| [docs/install.md](install.md) | 安装、更新、卸载、换源、日常运维 |
| [docs/mirrors.md](mirrors.md) | Gitee / CNB / R2 三个镜像的配置与排障 |
| [docs/plugins.md](plugins.md) | 编进去了哪些插件、怎么增删 |
| [docs/build.md](build.md) | 从 `plugins.txt` 到一个二进制的完整链路 |
| [docs/design.md](design.md) | 设计取舍，以及为什么不用另一种做法 |
| [docs/ROADMAP.md](ROADMAP.md) | 待开发 |
| [CONTRACT.md](../CONTRACT.md) | 下游消费契约（给脚本看的） |
| [.github/workflows/README.md](../.github/workflows/README.md) | 各 workflow 的职责与所需 Secret |
