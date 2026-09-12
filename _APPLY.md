# 应用说明

按结构覆盖到仓库根目录。全部是完整文件，不是补丁。

```
CONTRACT.md                        新（下游消费契约）
docs/ROADMAP.md                    新（待开发）
README.md                          改（--check / --contract-version、仓库结构）
mirror/README.md                   未变
.github/workflows/build.yml        改（清单头 + 清单发到 Release）
.github/workflows/mirror.yml       未变
.github/workflows/README.md        未变
scripts/install.sh                 改（CONTRACT_VERSION / --check / --contract-version / 清单内容校验）
scripts/mirror-lib.sh              改（清单加 contract + install_sh 行）
scripts/ci-lib.sh                  未变
scripts/bench-mirror.sh            未变
scripts/release_notes.py           未变
```

无需删除任何文件。
