#!/bin/sh
# SPEC: PROFILE-01
# 夹具断言的词汇与结构门禁（数据侧）。词汇表单一来源：fixtures/vocab.yaml；枚举来源：contract/contract.json。
# 规则：given/when 的键 ∈ fields；expect 的键 ∈ predicates；带枚举的类型其取值必须存在于契约；
#       嵌套 kv 的键 ∈ kvKeys；禁用键（then / when2 / expect2 …）出现即红。
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)

cd "$root" || exit 1
ruby -ryaml -rjson -rset -e '
require "set"
vocab = YAML.load_file("fixtures/vocab.yaml")
c     = JSON.parse(File.read("contract/contract.json"))
enums = c["enums"]
evall = enums["event"]["values"] + enums["event"]["auxValues"]
fields, preds, kv = vocab["fields"], vocab["predicates"], Set.new(vocab["kvKeys"] + vocab["metricNames"])
capSet  = Set.new(vocab["capabilityIds"] + vocab["egressNames"])
api   = Set.new(vocab["apiNames"])
entryKeys = Set.new(vocab["structure"]["entry"]["required"] + vocab["structure"]["entry"]["optional"])
caseKeys  = Set.new(vocab["structure"]["case"]["required"] + vocab["structure"]["case"]["optional"])
banned    = Set.new(vocab["structure"]["bannedKeys"])
absentOK  = Set.new(c["forbiddenFields"]["values"] + c["forbiddenFields"]["forbiddenEvents"] + evall +
                    api.to_a + vocab["conceptNames"] + Array(enums["tier"]["reserved"]) +
                    c["retired"]["principals"] + c["retired"]["scopes"] +
                    c["roles"]["values"].map { |r| "role:" + r })
bad = Hash.new { |h, k| h[k] = Set.new }

# 可选：tools/check-fixtures.sh coverage —— 只报夹具覆盖率，不判词汇
if (ARGV[0] == "coverage")
  ids = []
  Dir["spec/*.md"].each do |f|
    txt = File.read(f)
    txt.scan(/^\#{2,3} ([A-Z]{3,7}-\d{2}[a-z]?)/) { |m| ids << m[0] }
    txt.scan(/^\|\s*([A-Z]{3,7}-\d{2}[a-z]?)\s*\|/) { |m| ids << m[0] }
  end
  ids = ids.uniq.sort
  covered = []
  cases = 0
  Dir["fixtures/*.yaml"].sort.each do |f|
    next if File.basename(f) == "vocab.yaml"
    d = YAML.load_file(f)
    covered += d.keys
    cases += d.values.sum { |e| e["cases"].to_a.size }
  end
  missing = (ids - covered.uniq).reject { |i| i.start_with?("GATE-") } # GATE 是退役编号映射，不需要夹具
  puts "规格条目 #{ids.size}，已有夹具 #{covered.uniq.size}，用例 #{cases}"
  puts "无夹具条目 #{missing.size}：#{missing.join(" ")}" unless missing.empty?
  exit 0
end

enumOf = ->(name) { enums.dig(name, "values") }

check_val = lambda do |key, spec, val, where|
  if spec["enum"] && enums[spec["enum"].to_s]
    allowed = enumOf.(spec["enum"].to_s)
    Array(val).each { |v| bad["枚举取值越界 #{key}=#{v}"] << where unless allowed.include?(v.to_s) }
  end
  if spec["values"] || spec[:values]
    Array(val).each { |v| bad["符号取值越界 #{key}=#{v}"] << where unless Array(spec["values"] || spec[:values]).include?(v.to_s) }
  end
  case key.to_s
  when "events"
    Array(val).each { |v| bad["事件名越界 #{v}"] << where unless evall.include?(v.to_s) }
  when "noEvents"
    Array(val).each { |v| bad["noEvents 目标越界 #{v}"] << where unless (evall + c["forbiddenFields"]["forbiddenEvents"]).include?(v.to_s) }
  when "absent"
    Array(val).each do |v|
      next if v.to_s =~ %r{^(GET|POST|PUT|DELETE) /}
      bad["absent 目标未登记 #{v}"] << where unless absentOK.include?(v.to_s)
    end
  when "presentIn"
    Array(val).each { |v| bad["presentIn 位置越界 #{v}"] << where unless %w[core device contract code].include?(v.to_s) }
  end
if val.is_a?(Hash)
    val.each do |k2, v2|
      if key.to_s == "capability"
        bad["能力 id 未登记 #{k2}"] << where unless capSet.include?(k2.to_s)
      elsif key.to_s == "roles"
        bad["角色名越界 #{k2}"] << where unless c["roles"]["values"].include?(k2.to_s)
      elsif key.to_s == "egress"
        bad["出网开关名越界 #{k2}"] << where unless vocab["egressNames"].include?(k2.to_s)
      else
        bad["嵌套键未登记 #{k2}"] << where unless kv.include?(k2.to_s)
      end
      check_val.(k2.to_s, {}, v2, where) unless k2.to_s == "fields"
    end
  end
end

check_hash = lambda do |h, kind, where|
  return if h.nil?
  abort "FAIL #{where}: 不是映射" unless h.is_a?(Hash)
  table = kind == :field ? fields : preds
  h.each do |k, v|
    spec = table[k.to_s]
    if spec.nil?
      bad["#{kind == :field ? %q[状态/动作键] : %q[断言键"]} 未登记 #{k}"] << where
      next
    end
    check_val.(k, spec, v, where)
  end
end

Dir["fixtures/*.yaml"].sort.reject { |f| f.end_with?("vocab.yaml") }.each do |f|
  doc = YAML.load_file(f)
  doc.each do |id, entry|
    where = "#{f}##{id}"
    unless id =~ /\A[A-Z]{3,7}-\d{2}[a-z]?\z/
      bad["顶层键不是规格 id #{id}"] << f
      next
    end
    entry.each_key { |k| bad["条目级键未登记 #{k}"] << where unless entryKeys.include?(k.to_s) }
    bad["缺 spec 引用"] << where unless entry["spec"].is_a?(Array) && !entry["spec"].empty?
    bad["缺 cases"] << where unless entry["cases"].is_a?(Array) && !entry["cases"].empty?
    check_hash.(entry["given"], :field, "#{where}.given") if entry["given"]
    entry["cases"].each_with_index do |cs, i|
      w = "#{where}.cases[#{i + 1}]"
      cs.each_key do |k|
        bad["case 级键未登记 #{k}"] << w unless caseKeys.include?(k.to_s)
        bad["禁用键 #{k}"] << w if banned.include?(k.to_s)
      end
      bad["缺 name"] << w unless cs["name"].is_a?(String) && !cs["name"].empty?
      bad["缺 when"] << w unless cs["when"] || cs["given"]
      bad["缺 expect"] << w unless cs["expect"].is_a?(Hash) && !cs["expect"].empty?
      check_hash.(cs["given"], :field, "#{w}.given") if cs["given"]
      check_hash.(cs["when"], :field, "#{w}.when") if cs["when"]
      check_hash.(cs["expect"], :predicate, "#{w}.expect") if cs["expect"]
    end
  end
end


# 规格页里 fixtures/<file>.yaml#ID 的反向引用：该 id 必须真是那份夹具的顶层键
Dir["spec/*.md"].sort.each do |sf|
  File.read(sf).scan(%r{fixtures/([a-z]+\.yaml)#([A-Z]{3,7}-\d{2}[a-z]?)}) do |name, ident|
    target = "fixtures/" + name
    if !File.exist?(target)
      bad["夹具文件不存在 #{name}"] << sf
    elsif YAML.load_file(target).key?(ident)
      # ok
    else
      bad["规格反向引用无夹具 #{name}##{ident}"] << sf
    end
  end
end


if bad.empty?
  puts "夹具词汇与结构门禁：通过"
else
  bad.sort.each { |k, v| puts "FAIL #{k}（#{v.size} 处，例如 #{v.first}）" }
  exit 1
end
' "$@"

# 电视端设备清单只许引用夹具用例，不许自带期望（D46：期望只留夹具那一份）。
ruby tools/check-tv-list.rb
