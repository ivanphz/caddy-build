# 应用说明

按结构覆盖到仓库根目录。全部是完整文件，不是补丁。无需删除任何文件。

```
scripts/mirror-lib.sh          改（修 manifest soft404 误判）
.github/workflows/build.yml    改（actions 升 Node 24、产物结构断言）
.github/workflows/mirror.yml   改（actions 升 Node 24、注释去仓库名）
scripts/bench-mirror.sh        改（用法示例去仓库名）
docs/ROADMAP.md                改（新增第 2、3 条）
CONTRACT.md / README.md        未变
scripts/install.sh             未变
scripts/ci-lib.sh              未变
scripts/release_notes.py       未变
mirror/README.md               未变
.github/workflows/README.md    未变
```
