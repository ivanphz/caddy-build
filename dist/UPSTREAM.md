# dist/ 来源

本目录下的文件由 `.github/workflows/sync_dist.yml` 从上游自动同步，**请勿手改**。
它们不参与编译，只在 `scripts/install.sh` 部署时使用。

| 本地文件 | 上游路径 | 部署到 |
| :--- | :--- | :--- |
| `dist/Caddyfile` | `config/Caddyfile` | `/etc/caddy/Caddyfile`（仅当不存在时） |
| `dist/index.html` | `welcome/index.html` | `/usr/share/caddy/index.html` |

- 上游仓库：<https://github.com/caddyserver/dist>
- 上游分支：`master`
- 上游提交：[`c3bd5625cf080742f58985f98d878e70ccba6bfd`](https://github.com/caddyserver/dist/commit/c3bd5625cf080742f58985f98d878e70ccba6bfd)
- 同步时间：2026-08-07 17:15:00 (Beijing)
