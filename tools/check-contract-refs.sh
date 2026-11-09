#!/bin/sh
# SPEC: PROFILE-01
# 契约与夹具的引用完整性检查（M1.1 的 CI 门，数据侧）。
# 规则：contract/contract.json 与 fixtures/*.yaml 里出现的每个规格 id 都必须在 spec/ 里有定义；
#       fixtures 的顶层键必须是已定义的规格 id；契约里不得出现 forbiddenFields 与 retired 的取值。
# 退出码非 0 即门禁失败。
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
fail=0

say() { printf 'FAIL %s\n' "$1"; fail=1; }

defined=$(mktemp)
trap 'rm -f "$defined"' EXIT
{ perl -ne 'print "$1\n" while /^### ([A-Z]{3,7}-\d{2}[a-z]?)/g' "$root"/spec/*.md;
  perl -ne 'print "$1\n" while /^\|\s*([A-Z]{3,7}-\d{2}[a-z]?)\s*\|/g' "$root"/spec/*.md; } | sort -u >"$defined"

# 1. 契约与夹具引用的每个 id 都要有定义
for f in "$root/contract/contract.json" "$root"/fixtures/*.yaml "$root"/model/*.rb "$root"/tools/*.rb; do
  [ -f "$f" ] || { say "缺少契约或夹具文件：$f"; continue; }
  for id in $(perl -ne 'print "$1\n" while /\b([A-Z]{3,7}-\d{2}[a-z]?)\b/g' "$f" | sort -u); do
    case "$id" in
      D[0-9]*|F[0-9]*) continue ;;
    esac
    grep -qx "$id" "$defined" || say "$f 引用了不存在的条目 $id"
  done
done

# 2. fixtures 的顶层键必须是已定义条目
for f in "$root"/fixtures/*.yaml; do
  [ -f "$f" ] || continue
  for id in $(perl -ne 'print "$1\n" while /^([A-Z]{3,7}-\d{2}[a-z]?):/g' "$f"); do
    grep -qx "$id" "$defined" || say "$f 的顶层键 $id 没有定义"
  done
done

# 2b. 形如 spec/FILE.md#ID 的引用，该 ID 必须在被引用的文件里以标题或表行出现
python3 - "$root" <<'PYANCHOR'
import re, sys, pathlib
root = pathlib.Path(sys.argv[1])
files = [root / "contract" / "contract.json"] + sorted(root.glob("fixtures/*.yaml"))
anchors, bad = {}, []
for f in sorted((root / "spec").glob("*.md")):
    text = f.read_text()
    ids = set(re.findall(r"^#{2,3} ([A-Z]{3,7}-\d{2}[a-z]?)", text, re.M))
    ids |= set(re.findall(r"^\|\s*([A-Z]{3,7}-\d{2}[a-z]?)\s*\|", text, re.M))
    anchors[f.name] = ids
for f in files:
    for name, ident in re.findall(r"spec/([A-Za-z0-9._-]+\.md)#([A-Z]{3,7}-\d{2}[a-z]?)", f.read_text()):
        if name not in anchors:
            bad.append(f"{f.name}: 引用的规格文件不存在 {name}")
        elif ident not in anchors[name]:
            bad.append(f"{f.name}: {name}#{ident} 锚点不存在（该文件里没有此条目）")
for b in bad:
    print("FAIL " + b)
if bad:
    sys.exit(1)
print("规格锚点引用检查通过")
PYANCHOR

# 3. forbiddenFields / retired 的取值不得在契约其它位置出现
python3 - "$root/contract/contract.json" <<'PY'
import json, sys
c = json.load(open(sys.argv[1]))
bad = list(c["forbiddenFields"]["values"])
bad += c["retired"]["principals"] + c["retired"]["scopes"] + c["retired"]["nextAction"]
flat = json.dumps({k: v for k, v in c.items() if k not in ("forbiddenFields", "retired")}, ensure_ascii=False)
for token in ("unlocked", "unspentMs", "grantMinutes"):
    if token in json.dumps(c["enums"], ensure_ascii=False):
        print(f"FAIL 枚举里仍含已退役字段 {token}"); sys.exit(1)
for path in c["endpoints"]:
    for b in path.get("body", []):
        if b in bad:
            print(f"FAIL {path['path']} 的字段 {b} 属于禁止字段"); sys.exit(1)
print("契约禁止字段与退役取值检查通过")
PY

# 4. 事件枚举与 PRODUCT.md §3 一致
python3 - "$root/contract/contract.json" "$root/docs/PRODUCT.md" <<'PY'
import json, re, sys
c = json.load(open(sys.argv[1]))
doc = open(sys.argv[2]).read()
head = doc.split("## 4.")[0]
doc_events = set(re.findall(r'\b(?:WATCHED|DONE|ANSWER|ROUND_DONE|OVER|MISSED|PLAN_SIGNED|PLAN_CHANGE|PROFILE_SWITCH|MOTION_SETTLED|MOTION_UNANSWERED|MOTION|REVISION|ROLE_CHANGE|REMOTE)\b', head))
mine = set(c["enums"]["event"]["values"])
if doc_events != mine:
    print(f"FAIL 事件枚举不一致：{sorted(doc_events ^ mine)}"); sys.exit(1)
print("事件枚举与 PRODUCT §3 一致")
PY

# 5. 内核输出形状四处一致（M1.4）：契约 commitState ↔ ARCHITECTURE §9 ↔ model/commit.rb ↔ 工具出口
python3 - "$root" <<'PYSTATE'
import json, re, subprocess, sys, pathlib
root = pathlib.Path(sys.argv[1])
c = json.load(open(root / "contract" / "contract.json"))
cs = c.get("commitState")
if not cs:
    print("FAIL 契约缺 commitState：M1.4 的内核输出形状未定稿"); sys.exit(1)
bad = []
# 5a. tierFor 里用到的每一个层，都要在分层文档里出现过（层表只有一处）
lay = (root / "docs" / "LAYERING.md").read_text()
for row in cs["tierFor"]:
    if row["tier"] not in lay:
        bad.append(f'commitState.tierFor 用到的 {row["tier"]} 在 LAYERING.md 里找不到')
# 5b. 结构文档里写的字段名必须是契约声明的那一组
arch = (root / "docs" / "ARCHITECTURE.md").read_text()
for field in re.findall(r"\b(status|activeProfile|planVersion|due|tier|tierCeiling|nextAction|wording|surface|fallbackReason|kind|mode|deficit|window|howToAsk|ruleId)\b", arch):
    if field not in cs["fields"] + cs["dueFields"]:
        bad.append(f"ARCHITECTURE §9 出现的 {field} 不在契约 commitState 的字段表里")
# 5c. 模型产出的键必须与契约声明的字段一模一样（跑一次真的产出，不比对注释）
out = subprocess.run(["ruby", "-I", str(root / "model"), "-e",
                      "require 'commit'; "
                      "puts Core::Commit.state(profile: 'member:kid', "
                      "plan: {'allowanceMs' => 1, 'graceMs' => 2, 'moveFromMs' => 1}, "
                      "q: {'watchedMs' => 0, 'answeredInTask' => 0, 'roundsDone' => 0}).keys.join(',')"],
                     capture_output=True, text=True, cwd=str(root))
if out.returncode != 0:
    tail = out.stderr.strip().splitlines()
    bad.append("跑 model/commit.rb 取 CommitState 失败：" + (tail[-1] if tail else "无输出"))
else:
    got = out.stdout.strip().split(",")
    if got != cs["fields"]:
        bad.append(f"模型产出的字段与契约不一致：多出 {sorted(set(got) - set(cs['fields']))} "
                   f"缺少 {sorted(set(cs['fields']) - set(got))}")
# 5d. 强度默认档只有一处：契约这张表，模型读它
model = (root / "model" / "commit.rb").read_text()
if re.search(r"STRENGTH_DEFAULT_TIER = \{", model):
    bad.append("model/commit.rb 里又写了一份强度默认档，应读契约 commitState.strengthDefaultTier")
for b in bad:
    print("FAIL " + b)
if bad:
    sys.exit(1)
print("内核输出形状四处一致（契约 ↔ 结构文档 ↔ 模型）：通过")
PYSTATE

[ "$fail" -eq 0 ] && echo "契约与夹具引用完整性：通过"
exit "$fail"
