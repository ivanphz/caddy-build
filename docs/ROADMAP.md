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

## 2. Docker 编译与推送

**为什么现在能做**：版本号 `v2.11.4-20260813.1110` 本来就是 Docker tag 安全的
（当初刻意没用 `+`）；`CGO_ENABLED=0` + `-tags nobadger,nomysql,nopgx` 产出的是
静态二进制，distroless / scratch 镜像很直接。

**形状**：新增 `.github/workflows/docker.yml`，由 `build.yml` 在 release 之后
`workflow_call` 调用，复用 `init` 的 `version_tag`。多架构用 buildx，
amd64 + arm64 直接塞已经编好的二进制进去，不要在镜像里重新 `go build`。

**推去哪**：GHCR 一定要有；国内可以推 CNB 的 `docker.cnb.cool` 或阿里云 ACR。
推送层同样走 `mirror.yml` 的适配器模式，别再开一套。

---

## 3. 浅克隆上 rebase

**现状**：`update_deps.yml` / `sync_dist.yml` 用 `actions/checkout` 的默认
`fetch-depth: 1`，却在之后执行 `git pull --rebase --autostash`。

**代价**：至今没炸不代表安全。浅历史上 rebase 在特定情形下会失败，
表现为「依赖更新提交不上去」，而下游构建完全没有感知。

**方向**：这两个 workflow 的 checkout 加 `fetch-depth: 0`。代价是克隆慢几秒。

---

## 4. bench-mirror.sh 支持 R2

**现状**：只能测 Gitee / CNB。

**代价**：不大。但 R2 的上传速度（实测 runner → R2 约 6.4 MB/s，
比 CNB 的 304 KB/s 快一个数量级）目前没有任何工具能复现测量，
换区域或换账户时只能靠 workflow 跑一次看日志。

**方向**：加一个 `r2` 子命令，走 `aws s3 cp` 到一个临时 key 再删掉，
沿用现有的 `trap` 清理机制。

---

## 5. Go 版本会漂

**现状**：`build.yml` 用 `go-version: 'stable'` + `check-latest: true`。

**代价**：同一份 `go.mod` 在不同日期编出的二进制不一定逐字节相同。
对这个项目影响有限（没有声称可复现构建），但排查「上周还好好的」类问题时
会多一个变量。

**方向**：要么钉死小版本，要么在 release notes 里记录实际使用的 Go 版本
（`go_modules.json` 已经有了，但正文里没体现）。属于「知道就好」。

---

## 记录

| 日期 | 做掉了什么 |
| :--- | :--- |
| 2026-08 | 镜像流程抽到 `mirror-lib.sh`，Gitee / CNB / R2 共用一套适配器 |
| 2026-08 | 资产完整性检查：齐全就跳过上传，不再每次重传 140 MB |
| 2026-08 | `manifest.txt`：不再靠拼 URL 定位资产 |
| 2026-09 | 下游消费契约（`CONTRACT.md`）：`contract` 版本号、`--check`、清单发到 GitHub |
