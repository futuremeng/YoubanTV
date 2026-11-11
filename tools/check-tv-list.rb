#!/usr/bin/env ruby
# 电视端设备测试清单的结构门。
#
# 两条硬规矩：
#   一、判定期望只能引用夹具，不许在这份清单里再写一份（D46：一类规则只留一处）；
#   二、probes 里只放「设备能力本身」的自检（按键能不能落到、文本码位对不对），
#       这类没有对应的判定夹具，但同样必须写清验什么。
require 'yaml'

ROOT = File.expand_path('..', __dir__)
body = YAML.load_file(File.join(ROOT, 'tools/tv-device.yaml'))
scenarios = body['scenarios'] || []
probes = body['probes'] || []
bad = Hash.new { |h, k| h[k] = [] }

scenarios.each do |s|
  bad['设备清单不许自带期望（期望留在夹具那一份）'] << s.inspect if s.key?('expect')
  bad['设备清单的每一项都要写清这一步验什么（why）'] << s.inspect unless s['why']
  file, cid = s['case'].to_s.split('#')
  bad['设备清单的每一项都要有 case: 路径#ID'] << s.inspect if file.nil? || cid.nil?
  next if file.nil? || cid.nil?

  path = File.join(ROOT, file)
  unless File.exist?(path)
    bad['设备清单引用的夹具不存在'] << s['case'].to_s
    next
  end
  bad['设备清单引用的用例不存在'] << s['case'].to_s unless YAML.load_file(path)[cid.split('.').first]
end

# 自检名字以 tools/tv-at.rb 那张表为准，这里不另登一份（D87：一个名字登三处，漏一处就是
# 跑到一半 nil.call——一半自检没跑而看不出来）。拿不到那张表就红，不许绿着跳过。
KNOWN_PROBES = begin
  out = `ruby #{File.join(__dir__, 'tv-at.rb')} --list-probes 2>/dev/null`
  raise '拿不到自检名单' unless $?.success? && !out.strip.empty?

  out.split("\n").sort.freeze
rescue StandardError
  []
end
bad['拿不到自检名单（tools/tv-at.rb --list-probes）'] << KNOWN_PROBES.inspect if KNOWN_PROBES.empty?
probes.each do |p|
  bad['probes 的每一项都要有 probe: 名字'] << p.inspect if p['probe'].to_s.empty?
  bad['probes 的每一项也要写清验什么（why）'] << p.inspect unless p['why']
  bad['probes 里不许放 case: 或 expect:（那是 scenarios 的活）'] << p.inspect if p.key?('case') || p.key?('expect')
  bad["probes 里的名字不认识：#{p['probe']}（tools/check-tv-list.rb 里注册过的只有 #{KNOWN_PROBES.join('/')}）"] << p.inspect unless KNOWN_PROBES.include?(p['probe'].to_s)
end

if bad.empty?
  puts "电视端设备清单结构：通过（#{scenarios.size} 步判定引用夹具 + #{probes.size} 步设备自检）"
else
  bad.sort.each { |k, v| puts "FAIL #{k}：#{v.join(', ')}" }
  exit 1
end
