# 应用说明

这个包按仓库结构组织，**直接把内容覆盖到 caddy-build 仓库根目录即可**。
所有文件都是完整版本，不是补丁。

```
README.md                          改（4 处事实错误 + 镜像安装命令 + Variables 表）
mirror/README.md                   改（改用清单安装）
.github/workflows/build.yml        改（R2 job 移出；接入 mirror；重试与三态基准）
.github/workflows/mirror.yml       新（由 mirror_cn.yml 更名而来，并入 R2）
.github/workflows/README.md        新（workflow 总览）
scripts/install.sh                 改
scripts/bench-mirror.sh            改
scripts/release_notes.py           改
scripts/mirror-lib.sh              新
scripts/ci-lib.sh                  新
```

**需要手动删除的文件**（覆盖操作不会帮你删）：

```
.github/workflows/mirror_cn.yml    ← 已更名为 mirror.yml，必须删掉旧的，
                                     否则两个 workflow 会同时抢镜像
```
