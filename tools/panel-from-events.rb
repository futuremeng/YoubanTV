#!/usr/bin/env ruby
# 把设备上的事件账与每一档存过的那一份喂给 Ruby 那份规范模型，返回「这一档现在按哪几项跑」那一屏。
# 与 kernel-from-events 同一个理由：设备测试要拿它当基准，与设备上算出的那一屏逐字比（AGREE-14、两端同源）。
require 'json'
require_relative 'run-fixtures'

ledger = File.read(ARGV[0]).to_s
plans = File.exist?(ARGV[1].to_s) ? JSON.parse(File.read(ARGV[1])) : {}
profile = ARGV[2].to_s

events = ledger.each_line.map do |line|
  line = line.strip
  next unless line.start_with?('{')

  JSON.parse(line)
end.compact

puts JSON.generate(Core::Agreement.panel(events: events, profile: profile, plans: plans))
