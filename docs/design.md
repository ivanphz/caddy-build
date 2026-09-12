# 设计取舍

这里记的是**「为什么是这样，而不是那样」**。都是踩过或推演过的，不是风格偏好。
改动前先看一眼，很多看起来多余的写法是有原因的。

还有一些「为什么」写在离它更近的地方：

| 问题 | 在哪 |
| :--- | :--- |
| 为什么不注入 `CustomVersion`、版本号为什么是这个形状 | [build.md · 版本号](build.md#版本号) |
| 为什么保留策略以 GitHub 为准而不是各平台自己算 | [build.md · Release 保留策略](build.md#release-保留策略) |
| 为什么用 `aws` CLI 连 Cloudflare R2 | [mirrors.md · 为什么是 aws 命令](mirrors.md#为什么是-aws-命令和-aws_-变量) |
| 为什么镜像不同步插件清单，以及这么做的局限 | [mirrors.md · 镜像里放了什么](mirrors.md#镜像里放了什么没放什么) |
| 为什么用清单而不是拼 URL；`--check` 的退出码为什么这么分 | [CONTRACT.md](../CONTRACT.md) |
| `pipefail` + `head`/`grep -q` 的坑、软 404 | [.github/workflows/README.md](../.github/workflows/README.md) |

## 为什么不把日期拼进 caddy version

拼上去的写法是 `v2.11.4-20260807.1930`，但那个连字符在 semver 里是**预发布标识符**的
引导符，而规范规定预发布版本的优先级**低于**对应正式版 —— 任何做 semver 比较的工具
会认为你跑的是比 2.11.4 **更旧**的东西。判断 `caddy >= 2.11.4` 会得到否定结论。

正确的分隔符是加号：`v2.11.4+20260807.1930`。semver 里加号引导构建元数据，明确规定
「比较优先级时忽略」。但 Docker 的 tag 字符集不允许 `+`，以后要打镜像会卡住。

更重要的是**没必要**——构建身份已经在二进制里了。Go 在编译时会把源码 commit stamp
进构建信息，`-ldflags "-w -s"` 剥不掉（它在独立的段里）：

```bash
$ caddy build-info | grep vcs
build   vcs=git
build   vcs.revision=1ef6f3399a3e451f59d2f168fb274738664274f6
build   vcs.time=2026-08-07T15:40:02Z
build   vcs.modified=false
```

commit 比日期更精确：日期只说明哪天编的，commit 直接指向那一刻的 `go.mod` 和
`main.go`。所以 `version` 那一栏留给 Caddy 自己，构建身份走 `build-info`，
release 标识走 `.build-version` —— 三个问题三个答案，不互相污染。

## 关于默认页与「指纹」

一个常见的误判是「默认欢迎页暴露了这是 Caddy，换个低调的占位页更安全」。**反了。**

Caddy 的身份从 TLS 指纹、HTTP/3 支持、ALPN 顺序、证书签发模式上早就可见，改首页
藏不住。真正决定风险的是**匿名集大小**：

| 主动探测得到的响应 | 匿名集 | 作为扫描特征 |
| :--- | :--- | :--- |
| 官方欢迎页 | 极大 —— 全网每台装完没配过的 Caddy | 几乎无判别力 |
| 任何自造文案（如 `respond "xxx"`） | ≈ 1 | 完美判别式，一次字符串匹配即可枚举 |
| 空目录 → 404 | 大 | 判别力低 |

所以 `install.sh` 里**没有**「换一个更低调的占位页」这个选项：要么用官方那张，要么留空。
连网络故障时的兜底 Caddyfile 也是官方那份的逐字节内置副本，不会自造任何独特文本。

真正的答案不在这个开关上 —— 如果这台机器要长期承载 naive / trojan 流量，正解是放上
**真实内容**或 `reverse_proxy` 一个真实站点。只有占位页却持续有流量，这个组合本身就异常，
换哪张占位页都一样。

手工输入只有 `plugins.txt` 一个；`main.go` / `go.mod` / `go.sum` 全部由 `update_deps.yml`
生成并提交。**不要手改生成文件** —— `build.yml` 里的 `go mod tidy -diff` 会直接把不一致的
构建拦下来。

## 更新检测

因为 tag 不在二进制里，`caddy-update` 用两层判断：

1. `/etc/caddy/.build-version` 记录已安装的 release tag（安装时写入，root 所有 0644）
2. 状态文件缺失时（手动安装 / 从旧版迁移），回退到**比对已装二进制与最新 release 的
   sha256**

第二层其实更严格 —— 它能发现二进制被手动替换或损坏，而不只是标签对不上。
回滚发生时状态文件会被删除，避免谎报版本。

镜像端也有对应的一层：重跑 `mirror.yml` 时会先核对目标版本的资产
（文件名 / 字节数 / `.sha256` 内容），齐全就跳过上传，不齐才删掉重传 ——
不会每次都白传 140 MB。

```bash
$ sudo caddy-update status
仓库           ivanphz/caddy-build
caddy version  v2.11.4
已装 release   v2.11.4-20260807.1930
源码 commit    1ef6f33
最新 release   v2.11.5-20260814.1900
服务           running

有新版本可用，运行 sudo caddy-update
```


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
