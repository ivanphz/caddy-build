#!/usr/bin/env python3
# =============================================================================
# lint-workflow-env.py —— workflow 里「引用了、但这个 step 看不见」的环境变量
#
# 用法：
#   python3 scripts/lint-workflow-env.py [workflow 目录]    默认 .github/workflows
#   python3 scripts/lint-workflow-env.py --selftest           确认本检查自己会红
#
# 【为什么要有这个】
# Actions 的 env 有作用域：写在某个 step 的 `env:` 下，只对【那一个 step】生效。
# 后面的 step 再引用同名变量，拿到的是「未设置」：
#   - 脚本开了 set -u → `TAG: unbound variable`，step 红
#   - 没开 set -u     → 展开成空串，断言悄悄变恒真：
#                       *"/${TAG}/"* 变成 *"//"*，任何 https 地址都匹配
#
# 实际发生过（2026-09，见 docs/TRAPS.md 第 9 条）：build.yml 的
# 「Verify manifest install_sh is reachable」引用了 TAG，而 TAG 只写在
# 前一个 step「Generate Manifest」的 env 里。本地「三向实测」全对，
# 因为模拟时先 export 了 TAG —— 真实 runner 上第一次发版就会红，
# 而且红在 Create Release 之后：Release 已经发出去，mirror 却不再跑。
#
# 别的工具都抓不到：
#   shellcheck —— SC2154 故意跳过全大写变量名（它假定那是外部传入的）
#   bash -n    —— 语法没错
#   本地模拟    —— 习惯先把变量 export 好，恰好把作用域问题盖住
# 只有读 YAML 的作用域才看得出来。
#
# 【什么算「看得见」】
#   workflow env ∪ job env ∪ step env
#   ∪ 同一 job 里更早的 step 写进 $GITHUB_ENV 的
#   ∪ 脚本自己赋值的（VAR=、read、for、mapfile、printf -v、${VAR:=…}）
#   ∪ 脚本 source 的仓库内文件里赋值的
#   ∪ runner 自带的（GITHUB_* / RUNNER_* / HOME / PATH …）
#
# 带默认值的引用不算：${VAR:-x} ${VAR-x} ${VAR:=x} ${VAR:?msg} ${VAR:+x}
# —— 那是作者明确处理过「可能没设」。
# 只查全大写名字：那是环境变量的约定；小写变量是脚本内部的，不归这里管。
#
# 【取舍】这是词法级的近似，不是 bash 解析器。宁可漏报不误报：
# 误报会逼人加豁免，豁免多了这个检查就没人看了。
# $GITHUB_ENV 的写入按「整段脚本里 echo/printf 出的 NAME=」宽松收集。
#
# 退出码：0 干净 / 1 有问题 / 2 用法或解析错误
# =============================================================================
import os
import re
import sys

try:
    import yaml
except ImportError:  # selftest.yml 会先确保它在；本地没有时给句人话
    sys.exit("需要 PyYAML：apt install python3-yaml，或 pip install pyyaml")

NAME_RE = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")
ENV_NAME_RE = re.compile(r"^[A-Z][A-Z0-9_]*$")

# runner 与 bash 自带、不需要声明的
RUNNER_PREFIXES = ("GITHUB_", "RUNNER_", "ACTIONS_", "BASH")
RUNNER_NAMES = {
    "CI", "HOME", "PATH", "PWD", "OLDPWD", "USER", "SHELL", "TMPDIR", "LANG",
    "LC_ALL", "TERM", "HOSTNAME", "UID", "EUID", "PPID", "RANDOM", "SECONDS",
    "LINENO", "IFS", "OPTARG", "OPTIND", "REPLY", "PIPESTATUS", "FUNCNAME",
    "EPOCHSECONDS", "EPOCHREALTIME", "SHELLOPTS", "HOSTTYPE", "OSTYPE",
    "MACHTYPE", "GROUPS", "DIRSTACK", "COLUMNS", "LINES",
}

ASSIGN_RE = re.compile(
    r"(?:^|[\s;&|({])"
    r"(?:(?:export|local|readonly|declare|typeset)\s+(?:-\w+\s+)*)?"
    r"([A-Za-z_]\w*)(?:\[[^\]\n]*\])?\+?="
)
READ_RE = re.compile(r"(?:^|[\s;&|({])read((?:[ \t]+\S+)+)")
READ_ARG_OPTS = set("adinNptu")     # 这些选项要吃掉下一个词
FOR_RE = re.compile(r"(?:^|[\s;&|({])for\s+([A-Za-z_]\w*)\s+in\b")
MAPFILE_RE = re.compile(r"(?:^|[\s;&|({])(?:mapfile|readarray)\s+(?:-\w+\s+(?:\S+\s+)?)*([A-Za-z_]\w*)")
PRINTF_V_RE = re.compile(r"printf\s+-v\s+([A-Za-z_]\w*)")
SOURCE_RE = re.compile(r"(?:^|[\s;&|({])(?:source|\.)\s+\"?(?:\$\{?\w+\}?/)?([\w./-]+\.sh)\"?")
GHENV_KV_RE = re.compile(r"\b([A-Z_][A-Z0-9_]*)=")
HEREDOC_RE = re.compile(r"<<(-?)[ \t]*(\\?)(['\"]?)([A-Za-z_][A-Za-z0-9_]*)\3")


class Scan:
    """一段 bash 的词法扫描结果：引用了哪些名字、代码区（去掉引号内容）长什么样。"""

    def __init__(self, src):
        self.src = src
        self.n = len(src)
        self.refs = {}          # name -> 脚本内行号（1 起）
        self.assigned = set()   # ${VAR:=…} 这类在展开里完成的赋值
        self.code = []          # 引号与 heredoc 内容替换成空格后的文本
        self.pending = []       # 本行登记、下一行开始的 heredoc
        self.i = 0
        self._top()
        self.code = "".join(self.code)

    # ---- 基础 ----
    def _line(self, pos):
        return self.src.count("\n", 0, pos) + 1

    def _emit(self, ch, keep):
        # keep=False 时只保留换行，保证 code 与 src 行号对齐
        self.code.append(ch if keep or ch == "\n" else " ")

    def _ref(self, name, pos):
        if name not in self.refs:
            self.refs[name] = self._line(pos)

    # ---- 上下文 ----
    def _top(self):
        self._run(end=None, keep=True, quotes=True)

    def _run(self, end, keep, quotes, depth=0):
        """扫描到 end（')'、'`'、'}'）为止；quotes=False 表示处于双引号内。"""
        s = self.src
        word_start = True
        while self.i < self.n:
            c = s[self.i]
            if c == "\n":
                self._emit(c, keep)
                self.i += 1
                if self.pending:
                    self._heredocs()
                word_start = True
                continue
            if c == "\\":
                self._emit(c, keep)
                if self.i + 1 < self.n:
                    self._emit(s[self.i + 1], keep)
                self.i += 2
                word_start = False
                continue
            if end == "}" and c == "}" and depth == 0:
                self.i += 1
                self._emit(c, keep)
                return
            if not quotes:
                if c == '"':
                    self._emit(c, keep)
                    self.i += 1
                    return
                if c == "$":
                    self._dollar(keep)
                    continue
                if c == "`":
                    self._emit(c, keep)
                    self.i += 1
                    self._run(end="`", keep=False, quotes=True)
                    continue
                self._emit(c, keep)
                self.i += 1
                continue
            # ---- 代码区 ----
            if end == "`" and c == "`":
                self._emit(c, keep)
                self.i += 1
                return
            if end == ")" and c == ")" and depth == 0:
                self._emit(c, keep)
                self.i += 1
                return
            if c == "#" and word_start:
                j = s.find("\n", self.i)
                j = self.n if j < 0 else j
                for ch in s[self.i:j]:
                    self._emit(ch, False)
                self.i = j
                continue
            if c == "'":
                j = s.find("'", self.i + 1)
                j = self.n - 1 if j < 0 else j
                self._emit("'", keep)
                for ch in s[self.i + 1:j]:
                    self._emit(ch, False)
                self._emit("'", keep)
                self.i = j + 1
                word_start = False
                continue
            if c == '"':
                self._emit(c, keep)
                self.i += 1
                self._run(end=None, keep=False, quotes=False)
                word_start = False
                continue
            if c == "$":
                self._dollar(keep)
                word_start = False
                continue
            if c == "`":
                self._emit(c, keep)
                self.i += 1
                self._run(end="`", keep=keep, quotes=True)
                continue
            if c == "<" and s.startswith("<<", self.i) and not s.startswith("<<<", self.i):
                m = HEREDOC_RE.match(s, self.i)
                if m:
                    quoted = bool(m.group(2) or m.group(3))
                    self.pending.append((m.group(4), bool(m.group(1)), quoted))
                    for ch in m.group(0):
                        self._emit(ch, keep)
                    self.i = m.end()
                    continue
            if c == "(":
                depth += 1
            elif c == ")" and depth > 0:
                depth -= 1
            self._emit(c, keep)
            self.i += 1
            word_start = c in " \t;&|()"

    def _heredocs(self):
        s = self.src
        todo, self.pending = self.pending, []
        for delim, strip_tabs, quoted in todo:
            while self.i < self.n:
                j = s.find("\n", self.i)
                j = self.n if j < 0 else j
                line = s[self.i:j]
                probe = line.lstrip("\t") if strip_tabs else line
                if probe == delim:
                    for ch in s[self.i:j]:
                        self._emit(ch, False)
                    self.i = j
                    if self.i < self.n:
                        self._emit("\n", False)
                        self.i += 1
                    break
                if quoted:
                    for ch in s[self.i:j + 1]:
                        self._emit(ch, False)
                else:
                    self._expanding_line(self.i, j)
                    if j < self.n:
                        self._emit("\n", False)
                self.i = min(j + 1, self.n)

    def _expanding_line(self, a, b):
        # 非引号 heredoc 的正文：会展开，但引号不是引号
        save = self.i
        self.i = a
        while self.i < b:
            c = self.src[self.i]
            if c == "\\":
                self._emit(c, False)
                if self.i + 1 < b:
                    self._emit(self.src[self.i + 1], False)
                self.i += 2
            elif c == "$":
                self._dollar(False)
            else:
                self._emit(c, False)
                self.i += 1
        self.i = max(self.i, save)

    def _dollar(self, keep):
        s, i = self.src, self.i
        nxt = s[i + 1] if i + 1 < self.n else ""
        if s.startswith("${{", i):                      # GitHub 表达式，runner 先替换掉
            j = s.find("}}", i)
            j = self.n if j < 0 else j + 2
            for ch in s[i:j]:
                self._emit(ch, keep)
            self.i = j
            return
        if s.startswith("$((", i):
            self._emit("$", keep); self._emit("(", keep); self._emit("(", keep)
            self.i = i + 3
            self._run(end=")", keep=keep, quotes=True)
            if self.i < self.n and s[self.i] == ")":
                self._emit(")", keep)
                self.i += 1
            return
        if nxt == "(":
            self._emit("$", keep); self._emit("(", keep)
            self.i = i + 2
            self._run(end=")", keep=keep, quotes=True)
            return
        if nxt == "'":                                  # $'…' ANSI-C 字符串
            j = i + 2
            while j < self.n and s[j] != "'":
                j += 2 if s[j] == "\\" else 1
            for ch in s[i:j + 1]:
                self._emit(ch, False)
            self.i = j + 1
            return
        if nxt == "{":
            self._brace(keep)
            return
        m = NAME_RE.match(s, i + 1)
        if m:
            self._ref(m.group(0), i)
            for ch in s[i:m.end()]:
                self._emit(ch, keep)
            self.i = m.end()
            return
        self._emit("$", keep)
        self.i = i + 1

    def _brace(self, keep):
        s, i = self.src, self.i
        j = i + 2
        indirect = j < self.n and s[j] == "!"
        length = j < self.n and s[j] == "#" and NAME_RE.match(s, j + 1) is not None
        if indirect or length:
            j += 1
        m = NAME_RE.match(s, j)
        name = m.group(0) if m else None
        k = m.end() if m else j
        if m and k < self.n and s[k] == "[":
            e = s.find("]", k)
            k = self.n if e < 0 else e + 1
        op = s[k:k + 2]
        if name and not indirect:
            if op[:1] == "}" or length:
                self._ref(name, i)
            elif op in (":-", ":+", ":?") or op[:1] in ("-", "+", "?"):
                pass                                    # 有默认值：作者处理过「没设」
            elif op == ":=" or op[:1] == "=":
                self.assigned.add(name)
            else:                                       # ${V%x} ${V/a/b} ${V:0:3} …
                self._ref(name, i)
        for ch in s[i:k]:
            self._emit(ch, keep)
        self.i = k
        # 其余部分（默认值、替换串）里还可能嵌套引用，按双引号语义继续扫
        self._run(end="}", keep=keep, quotes=False)


def assignments(code):
    out = set(m.group(1) for m in ASSIGN_RE.finditer(code))
    for m in READ_RE.finditer(code):
        words = m.group(1).split()
        k = 0
        while k < len(words) and words[k].startswith("-"):
            flags = words[k][1:]
            if flags and flags[-1] in READ_ARG_OPTS:
                if flags[-1] == "a" and k + 1 < len(words):
                    out.add(words[k + 1])            # read -a ARR：ARR 被赋值
                k += 1
            k += 1
        for w in words[k:]:
            m = NAME_RE.match(w)
            if not m:
                break                                # 碰到 <<< / < 等就停
            out.add(m.group(0))
            if m.end() != len(w):
                break                                # read -r LINE; do …
    out.update(m.group(1) for m in FOR_RE.finditer(code))
    out.update(m.group(1) for m in MAPFILE_RE.finditer(code))
    out.update(m.group(1) for m in PRINTF_V_RE.finditer(code))
    return out


def github_env_writes(src):
    if "GITHUB_ENV" not in src:
        return set()
    names = set()
    for line in src.splitlines():
        if re.search(r"\b(echo|printf)\b", line) or "GITHUB_ENV" in line:
            names.update(GHENV_KV_RE.findall(line))
    # cat >> "$GITHUB_ENV" <<EOF … EOF 形式
    for m in re.finditer(r"GITHUB_ENV[^\n]*<<-?\s*['\"]?(\w+)['\"]?\n(.*?)\n\s*\1\s*$", src, re.S | re.M):
        names.update(re.findall(r"^\s*([A-Z_][A-Z0-9_]*)=", m.group(2), re.M))
    return names


def sourced_assignments(src, root, seen=None):
    """src 用原文：路径通常写在双引号里（"${REPO_ROOT}/scripts/x.sh"），代码区里已被抹掉。"""
    seen = set() if seen is None else seen
    out = set()
    for m in SOURCE_RE.finditer(src):
        rel = m.group(1)
        idx = rel.find("scripts/")
        rel = rel[idx:] if idx >= 0 else rel
        path = os.path.normpath(os.path.join(root, rel))
        if path in seen or not os.path.isfile(path):
            continue
        seen.add(path)
        with open(path, encoding="utf-8") as f:
            sc = Scan(f.read())
        out |= assignments(sc.code) | sc.assigned | github_env_writes(sc.src)
        out |= sourced_assignments(sc.src, root, seen)
    return out


class LineLoader(yaml.SafeLoader):
    pass


def _construct_mapping(loader, node, deep=False):
    mapping = yaml.SafeLoader.construct_mapping(loader, node, deep=deep)
    lines = {}
    for k, v in node.value:
        key = loader.construct_object(k, deep=deep)
        off = 1 if getattr(v, "style", None) in ("|", ">") else 0
        lines[key] = v.start_mark.line + 1 + off
    mapping["__lines__"] = lines
    mapping["__line__"] = node.start_mark.line + 1
    return mapping


LineLoader.add_constructor(yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, _construct_mapping)


def env_keys(d):
    e = d.get("env") if isinstance(d, dict) else None
    return {k for k in e if k not in ("__lines__", "__line__")} if isinstance(e, dict) else set()


def visible_to_runner(name):
    return name in RUNNER_NAMES or name.startswith(RUNNER_PREFIXES)


def is_bash(step, job, wf):
    shell = step.get("shell")
    if shell is None:
        shell = ((job.get("defaults") or {}).get("run") or {}).get("shell")
    if shell is None:
        shell = ((wf.get("defaults") or {}).get("run") or {}).get("shell")
    return shell is None or str(shell).split()[0] in ("bash", "sh")


def lint_file(path, root):
    with open(path, encoding="utf-8") as f:
        wf = yaml.load(f, Loader=LineLoader)
    problems = []
    if not isinstance(wf, dict) or not isinstance(wf.get("jobs"), dict):
        return problems
    wf_env = env_keys(wf)
    for jid, job in wf["jobs"].items():
        if jid in ("__lines__", "__line__") or not isinstance(job, dict):
            continue
        job_env = env_keys(job)
        steps = [s for s in (job.get("steps") or []) if isinstance(s, dict)]
        # 同 job 里每个名字写在哪些 step 的 env 下 —— 报错时用来指路
        where = {}
        for idx, st in enumerate(steps):
            for k in env_keys(st):
                where.setdefault(k, []).append(st.get("name") or f"step #{idx + 1}")
        exported = set()
        for idx, st in enumerate(steps):
            run = st.get("run")
            if not isinstance(run, str) or not is_bash(st, job, wf):
                continue
            sc = Scan(run)
            visible = (wf_env | job_env | env_keys(st) | exported
                       | assignments(sc.code) | sc.assigned
                       | sourced_assignments(run, root))
            base = st["__lines__"].get("run", st["__line__"])
            label = st.get("name") or f"step #{idx + 1}"
            for name, ln in sorted(sc.refs.items(), key=lambda kv: kv[1]):
                if not ENV_NAME_RE.match(name) or name in visible or visible_to_runner(name):
                    continue
                elsewhere = [w for w in where.get(name, []) if w != label]
                hint = (f"—— 它只写在同 job 的「{'」「'.join(elsewhere)}」的 env 下，"
                        f"step 级 env 不跨 step" if elsewhere else "—— 哪一级 env 都没有声明")
                problems.append(f"{path}:{base + ln - 1}: [{jid} / {label}] ${name} 在这个 step 里看不见 {hint}")
            exported |= github_env_writes(run)
    return problems


def selftest():
    """本检查自己必须能红：正例报、反例不报。"""
    bad = """
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - name: A
        env: { TAG: v1 }
        run: echo "$TAG"
      - name: B
        run: |
          set -euo pipefail
          case "$url" in *"/${TAG}/"*) ;; esac
"""
    good = """
env: { WF: 1 }
jobs:
  j:
    runs-on: ubuntu-latest
    env: { JOB: 1 }
    steps:
      - run: echo "ASSET=x" >> "$GITHUB_ENV"
      - name: B
        env: { STEP: 1 }
        run: |
          set -euo pipefail
          LOCAL=1; read -r R1 R2 <<< "a b"; for F in x; do :; done
          echo "$WF $JOB $STEP $ASSET $LOCAL $R1 $R2 $F $GITHUB_SHA $HOME"
          echo "${OPT:-} ${OPT2-} ${SET:=x} $SET ${REQ:?必须设置}"
          echo '$SINGLE' "\\$ESCAPED" ${{ env.EXPR }}
          # $COMMENT
          awk '{print $NF}' <<'EOF'
          $QUOTED_HEREDOC
          EOF
          printf -v PV '%s' x; echo "$PV"
          while read -r LINE; do echo "$LINE"; done < /dev/null
          echo "$(awk -F'\\t' '{print $NF}' f)"
"""
    import tempfile
    ok = True
    with tempfile.TemporaryDirectory() as d:
        for name, body, want in (("bad.yml", bad, 1), ("good.yml", good, 0)):
            p = os.path.join(d, name)
            with open(p, "w", encoding="utf-8") as f:
                f.write(body)
            got = lint_file(p, d)
            if len(got) != want:
                ok = False
                print(f"✗ {name}: 期望 {want} 条，实得 {len(got)} 条")
                for g in got:
                    print("   ", g)
            else:
                print(f"✓ {name}: {want} 条" + (f"（{got[0].split('] ', 1)[1]}）" if got else ""))
    return 0 if ok else 1


def main(argv):
    if argv[1:2] == ["--selftest"]:
        return selftest()
    wdir = argv[1] if len(argv) > 1 else ".github/workflows"
    if not os.path.isdir(wdir):
        print(f"找不到 workflow 目录: {wdir}", file=sys.stderr)
        return 2
    root = os.path.normpath(os.path.join(wdir, "..", ".."))
    files = sorted(os.path.join(wdir, f) for f in os.listdir(wdir) if f.endswith((".yml", ".yaml")))
    problems = []
    for p in files:
        try:
            problems += lint_file(p, root)
        except yaml.YAMLError as e:
            print(f"{p}: YAML 解析失败: {e}", file=sys.stderr)
            return 2
    for line in problems:
        print(f"::error::{line}" if os.environ.get("GITHUB_ACTIONS") else line)
    print(f"检查了 {len(files)} 个 workflow，{'发现 ' + str(len(problems)) + ' 处' if problems else '没有'}跨 step 失效的变量引用")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
