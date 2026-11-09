#!/usr/bin/env ruby
# 设备清单的结构门禁：fixtures/tv-device.yaml 只许**引用**夹具用例，不许自带期望。
# 理由与 D46 同一类：判定期望只留夹具那一份，清单再写一份就会各自漂。
require 'yaml'

ROOT = File.expand_path('..', __dir__)
LIST = File.join(ROOT, 'tools/tv-device.yaml')

bad = Hash.new { |h, k| h[k] = [] }
doc = YAML.load_file(LIST)
scenarios = doc['scenarios'].to_a
bad['设备清单为空'] << LIST if scenarios.empty?

scenarios.each do |s|
  file, cid = s['case'].to_s.split('#')
  bad['设备清单的每一项都要有 case: 路径#ID'] << s.inspect if file.nil? || cid.nil?
  next if file.nil? || cid.nil?

  path = File.join(ROOT, file)
  unless File.exist?(path)
    bad['设备清单引用的夹具不存在'] << s['case'].to_s
    next
  end
  body = YAML.load_file(path)[cid.split('.').first]
  bad['设备清单引用的用例不存在'] << s['case'].to_s unless body
  bad['设备清单不许自带期望（期望留在夹具那一份）'] << s['case'].to_s if s.key?('expect')
  bad['设备清单的每一项都要写清这一步验什么（why）'] << s['case'].to_s unless s['why']
end

if bad.empty?
  puts "电视端设备清单结构：通过（#{scenarios.size} 步，期望全部引用夹具）"
else
  bad.sort.each { |k, v| puts "FAIL #{k}：#{v.join(', ')}" }
  exit 1
end
