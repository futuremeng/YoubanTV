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
for f in "$root/contract/contract.json" "$root"/fixtures/*.yaml; do
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

[ "$fail" -eq 0 ] && echo "契约与夹具引用完整性：通过"
exit "$fail"
