#!/usr/bin/env ruby
# 装包清单与实现是否一致的一道门：声明的权限必须契约里有交代且真做了；不许有后台常驻与开机自启。
# 「权限声明比实现多」在屏上看不出来——装的时候看着正常，只是白要了一样东西（ONBOARD-06）。
require 'json'

root = File.expand_path('..', __dir__)
manifest = File.read(File.join(root, 'device/android/app/src/main/AndroidManifest.xml'))
contract = JSON.parse(File.read(File.join(root, 'contract/contract.json')))
rows = contract.dig('devicePermissions', 'rows').map { |r| [r['permission'], r] }.to_h
bad = []

declared = manifest.scan(/<uses-permission[^>]*android:name="([^"]+)"/).flatten
declared.each do |perm|
  row = rows[perm]
  bad << "清单声明了 #{perm}，契约 devicePermissions 里没交代" and next unless row
  bad << "#{perm} 声明了但实现还没做（#{row['use']}）" if row['declared'] != true
end
rows.each do |perm, row|
  bad << "契约说 #{perm} 该声明，清单里没有" if row['declared'] == true && !declared.include?(perm)
end

bad << '清单里有 <service>：这台设备上不许有后台常驻' if manifest.include?('<service')
bad << '清单里有 BOOT_COMPLETED：开机不许自启（F3：重探在下一次打开时）' if manifest.include?('BOOT_COMPLETED')
bad << '清单里 allowBackup 不是 false：这台设备上的账与约定不许备份到别处' unless manifest =~ /android:allowBackup="false"/
bad << '清单里有 ACCESS_FINE_LOCATION 之类的定位权限：体感与上下文都不该要定位' if declared.any? { |p| p.include?('LOCATION') }

abort "装包清单与实现不一致：\n  #{bad.join("\n  ")}" unless bad.empty?
puts "装包清单与实现一致（声明 #{declared.size} 条权限，逐条在契约里有交代）"
