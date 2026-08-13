# 工作流总览

一句话版本：**`plugins.txt` 是唯一手工输入，其余全是自动生成或分发。**

```
  caddyserver/dist ──[sync_dist]──► dist/          （部署资产，不参与编译）

  plugins.txt ──[update_deps]──► go.mod/go.sum/main.go
                                       │
                                       └──[build]──► GitHub Release
                                                       │
                                                       └──[mirror]──┬──► Gitee
                                                                    ├──► CNB
                                                                    └──► Cloudflare R2
```

分发只有一个入口。以前 R2 在 `build.yml` 里、国内平台在另一个文件，
同样的「查重 → 校验 → 上传 → 清理」写了两遍且不一致（R2 每次无条件重传）。

| 文件 | 名称 | 触发 | 干什么 | 产物落在哪 |
| :--- | :--- | :--- | :--- | :--- |
| `update_deps.yml` | Update Dependencies | 每周五 18:00、改 `plugins.txt`、手动 | 解析 `plugins.txt` → 写 `go.mod` / `go.sum` / `main.go`，试编译一次 | 提交回本仓库 `main` |
| `build.yml` | Build Custom Caddy | `go.mod` / `go.sum` 变更、手动 | 编译 amd64 + arm64、冒烟测试、生成 release notes、发 Release、清理旧 Release、（可选）推 R2 | GitHub Release + R2 |
| `sync_dist.yml` | Sync dist assets | 每周一 18:00、手动 | 从 `caddyserver/dist` 拉默认 Caddyfile 和欢迎页 | 提交回本仓库 `dist/` |
| `mirror.yml` | Mirror | 由 `build.yml` 自动调用，也可手动 | 把 Release 的 4 个资产 + `install.sh` + `manifest.txt` 分发到 Gitee / CNB / R2 | 各平台仓库、Release、存储桶 |
| `dependabot.yml` | — | 每月 | 只跟 Actions 版本，**不管 Go 依赖**（那是 `update_deps` 的活） | PR |

---

## update_deps.yml — 依赖解析

**唯一会改 `go.mod` 的地方。** 手改 `main.go` / `go.mod` 会被 `build.yml` 的
`go mod tidy -diff` 拦下来。

1. 清掉所有旧 `replace`
2. 逐行处理 `plugins.txt`
   - `a=b@ref` → 先用 `go list -m` 把分支/tag 解析成 pseudo-version，再写 `replace`
   - 普通行 → `go get @latest`
3. 生成 `main.go`（唯一真源，没有 `tools.go`）
4. `go mod tidy` + 试编译，**编译不过就不提交**
5. 有解析失败的条目 → workflow 直接失败并列出来

必须用 `secrets.PAT` 提交：`GITHUB_TOKEN` 的推送不会触发下游 `build.yml`。

## build.yml — 编译与发布

四个 job：

| job | 干什么 | 备注 |
| :--- | :--- | :--- |
| `init` | 生成全局版本号 `v2.11.4-20260807.1930` | 只生成一次，两个架构共用，避免跨分钟产生不同 tag |
| `build` | matrix × {amd64, arm64}：`go mod verify` → `go build` → 冒烟测试 → release notes | 不跑 `go mod tidy`，`-mod=readonly` 保证可复现 |
| `release` | 合并产物、拼 release 正文、发 Release、清理超出 `KEEP_RELEASES`（默认 12）的旧版本 | 清理按创建时间倒序跳过前 N 个，刚发的必然排第一；清理失败不标红 |
| `mirror` | 调用 `mirror.yml` 分发到所有下游平台 | 每个平台的 token/变量没配就各自跳过 |

冒烟测试只在 amd64 跑（runner 执行不了 arm64 二进制）：核对 `caddy version` 与
`go.mod` 里的核心版本一致、`list-modules` 数量不异常偏少。

## sync_dist.yml — 同步打包资产

按上游 **commit SHA** 而不是分支名取文件，保证一轮拿到的两个文件来自同一个提交；
下载后校验内容特征串，防止把 404 页面当资产提交进来。只有 `dist/Caddyfile` /
`dist/index.html` 真变了才提交（`dist/UPSTREAM.md` 里的时间戳不算变更）。

这些文件不参与编译，只在 `install.sh` 部署时使用，所以这里的提交**不会**触发重新构建。

## mirror.yml — 分发

平台无关的流程全在 [`scripts/mirror-lib.sh`](../../scripts/mirror-lib.sh)，
本文件只写每个平台「怎么调 API」。流程：

```
确定目标分支/命名空间（git 型探测远端默认分支，探不到就报错，不猜 main）
  └─ 远端为空 → 用平台默认值（Gitee=master / CNB=main / R2=main）
查同名 release / tag 前缀
  ├─ 存在 → 逐个核对资产：文件名 / 字节数 / .sha256 内容
  │           ├─ 齐全 → 跳过上传
  │           └─ 不齐 → 整个删掉，重建重传
  └─ 不存在 → 新建
上传（Gitee 可走 SSH 中转，CNB 三步预签名，R2 走 S3 API）
写 manifest.txt（文件名 → 真实下载地址），连同 README + install.sh 一起推过去
按 GitHub 现存 tag 清理旧版本（本次的 tag 永远保留）
```

三个平台的差异只在「怎么调 API」，上面这套流程一份代码。

**加一个新平台**：复制一个 step，实现 6 个 `platform_*` 函数（见
`mirror-lib.sh` 顶部的适配器契约），`mirror-lib.sh` 一行都不用改。
对象存储这类没有 git 仓库的平台，额外实现 `platform_sync_files`
和（可选的）`platform_fetch_asset`，并设 `PLATFORM_KIND=object`。

---

## 需要的 Secret / Variable

| 类型 | 名称 | 必需 | 用途 |
| :--- | :--- | :--- | :--- |
| Secret | `PAT` | 是 | `repo` 权限，`update_deps` 提交用 |
| Variable | `KEEP_RELEASES` | 否 | GitHub 保留数，默认 12，下限 3 |
| Variable | `MIN_MODULES` | 否 | 冒烟测试的模块数下限，默认 100 |
| Secret | `GITEE_TOKEN` | 否 | 不设则整个 Gitee 步骤跳过 |
| Variable | `GITEE_REPO` | Gitee 必需 | 例 `owner/caddy-build`；缺了 → 跳过 |
| Variable | `GITEE_BRANCH` / `GITEE_USER` / `GITEE_ASSETS` / `GITEE_KEEP` | 否 | 分支默认自动探测；保留数默认 5（Gitee 附件总量上限 1 GB） |
| Secret | `GITEE_RELAY_KEY` | 否 | SSH 中转私钥；不设则 runner 直连 |
| Secret 或 Variable | `GITEE_RELAY_HOST` / `_KNOWN_HOSTS` | 否 | 建议放 Secrets，见下 |
| Variable | `GITEE_RELAY_USER` / `_PORT` | 否 | 默认 `root` / `22` |
| Secret | `CNB_TOKEN` | 否 | 需 `repo-release:rw`；不设则跳过 CNB |
| Variable | `CNB_REPO` | CNB 必需 | 缺了 → 跳过 |
| Variable | `CNB_BRANCH` / `CNB_ASSETS` / `CNB_KEEP` | 否 | 保留数默认 12 |
| Secret | `R2_ACCESS_KEY_ID` / `R2_SECRET_ACCESS_KEY` | 否 | 不设 `R2_ACCESS_KEY_ID` 则整个 R2 步骤跳过 |
| Variable | `R2_BUCKET` / `R2_ACCOUNT_ID` | R2 必需 | 缺任一项 → 跳过 |
| Secret 或 Variable | `R2_PUBLIC_BASE` | 否 | R2 公开访问域名。**不配也能用**：照常上传产物，只是不生成清单、日志和摘要里也不回显任何地址 |
| Variable | `R2_PREFIX` / `R2_NAMESPACE` / `R2_ASSETS` / `R2_KEEP` | 否 | 默认 `caddy` / `main` / 全部 / 12 |

---

## 容错约定

界线只有一条：

| 情况 | 行为 |
| :--- | :--- |
| **缺配置**（没填 token、没填仓库名、没填 bucket…） | 打 `::notice::` 后**跳过**，step 算成功 |
| **配了但用不了**（token 无效、仓库不存在、上传失败、分支探测不到） | 报错，step 标红 |

混在一起的后果是：要么没配的人天天收失败邮件，要么真出事了没人发现。

三个平台互相独立（`!cancelled()`），一个挂了另外两个照跑。但上游的
`Resolve tag` 失败时三个都跳过 —— 没有 tag 就没什么可镜像的。

中转机同理：没配 `GITEE_RELAY_HOST` / `_KEY` 就自动回落 runner 直连，
没配 `_KNOWN_HOSTS` 就 `ssh-keyscan` 并给出警告，都不会中断。

---

## 什么会出现在公开日志里

本仓库是公开的，**Actions 日志和 Run summary 任何人都能看**。GitHub 会把每个
step 的 `env:` 块原样打进日志：`vars.*` 明文可见，`secrets.*` 显示成 `***`。

建议放 Secrets 而不是 Variables 的三个值：

| 值 | 泄露了会怎样 |
| :--- | :--- |
| `R2_PUBLIC_BASE` | 任何人可直接下载你的 R2 对象。R2 出网不计费，主要是不想被当图床、也不想被计入 Class B 操作 |
| `GITEE_RELAY_HOST` | 暴露中转机主机名 |
| `GITEE_RELAY_KNOWN_HOSTS` | 同上（内容里含主机名和主机公钥） |

三者都写成 `${{ secrets.X || vars.X }}`，放哪边都能工作，放 Secrets 才会打码。

`R2_BUCKET`、`R2_ACCOUNT_ID`、`GITEE_REPO`、`CNB_REPO` 泄露无所谓 ——
没有凭据用不了，仓库名本来就是公开的。
