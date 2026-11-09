#!/usr/bin/env ruby
# SPEC: LAYER-07, SENSE-02
# 实测样本录入器：把 F12 / F13 的原始记录写进 docs/facts/probes/，并当场算出结论。
# 只登记事实，不做推断；结论由 tools/probe-gate.sh 复核。
require 'yaml'
require 'optparse'

root = File.expand_path('..', __dir__)
opts = { 'fact' => 'f12' }
OptionParser.new do |o|
  o.banner = '用法：probe-record.rb --fact=f12|f13 [选项]'
  o.on('--fact=F') { |v| opts['fact'] = v }
  o.on('--device=D') { |v| opts['device'] = v }
  o.on('--android=A') { |v| opts['android'] = v }
  o.on('--player=P') { |v| opts['player'] = v }
  o.on('--source=S') { |v| opts['source'] = v }
  o.on('--trials=1,0,1') { |v| opts['trials'] = v.to_s.split(/[, ]+/).map(&:to_i) }
  o.on('--name=N') { |v| opts['name'] = v }
  o.on('--attempts=N', Integer) { |v| opts['attempts'] = v }
  o.on('--false-counts=N', Integer) { |v| opts['falseCounts'] = v }
  o.on('--reference=T:manual:auto') do |v|
    t, m, a = v.split(':')
    opts['reference'] = { 'trials' => t.to_i, 'manualSum' => m.to_i, 'autoSum' => a.to_i }
  end
  o.on('--distance=CM', Integer) { |v| opts['distance'] = v }
  o.on('--lux=N', Integer) { |v| opts['lux'] = v }
  o.on('--frame-ms=N', Integer) { |v| opts['frameMs'] = v }
  o.on('--temp=N', Integer) { |v| opts['temp'] = v }
end.parse!

path = File.join(root, 'docs/facts/probes', "#{opts['fact']}.yaml")
abort "未知事实 #{opts['fact']}" unless File.exist?(path)

doc = YAML.load_file(path)
th = doc['threshold']

if opts['fact'] == 'f12'
  abort 'F12 需要 --device 与 --trials' unless opts['device'] && opts['trials']
  bad = opts['trials'].reject { |t| [0, 1].include?(t) }
  abort "trials 只能是 0/1，收到 #{bad.uniq.join(",")}" unless bad.empty?

  row = (doc['devices'] ||= []).find { |d| d['model'] == opts['device'] && d['player'] == (opts['player'] || 'stock') }
  row ||= (doc['devices'] << { 'model' => opts['device'], 'android' => opts['android'],
                               'player' => opts['player'] || 'stock', 'trials' => [] }).last
  row['android'] = opts['android'] if opts['android']
  row['source'] = opts['source'] || 'manual'
  row['trials'] = opts['trials']
  n = row['trials'].size
  rate = n.zero? ? 0.0 : row['trials'].sum.to_f / n
  verdict = if n < th['sampleMin']
              "样本不足（#{n}/#{th['sampleMin']}）"
            elsif rate >= th['responseRate']
              '可把 focused 抬为该机型默认档'
            else
              '停在 ambient 并写明原因'
            end
  puts "F12 #{row['model']} · #{row['player']} · n=#{n} 响应率=#{(rate * 100).round(1)}% → #{verdict}"
else
  abort 'F13 需要 --name 与 --attempts/--false-counts' unless opts['name'] && opts['attempts']
  row = (doc['projects'] ||= []).find { |p| p['name'] == opts['name'] && p['device'] == opts['device'] }
  row ||= (doc['projects'] << { 'name' => opts['name'], 'device' => opts['device'],
                                'selfTest' => { 'attempts' => 0, 'falseCounts' => 0 },
                                'reference' => { 'trials' => 0, 'manualSum' => 0, 'autoSum' => 0 } }).last
  row['selfTest'] = { 'attempts' => opts['attempts'], 'falseCounts' => opts['falseCounts'].to_i }
  row['reference'] = opts['reference'] if opts['reference']
  row['cameraDistanceCm'] = opts['distance'] if opts['distance']
  row['lightLux'] = opts['lux'] if opts['lux']
  row['frameMs'] = opts['frameMs'] if opts['frameMs']
  row['tempC'] = opts['temp'] if opts['temp']
  row['source'] = opts['source'] || 'manual'
  rate = row['selfTest']['attempts'].zero? ? 1.0 : row['selfTest']['falseCounts'].to_f / row['selfTest']['attempts']
  verdict = if row['selfTest']['attempts'] < th['selfTestAttempts']
              "自检样本不足（#{row['selfTest']['attempts']}/#{th['selfTestAttempts']}）"
            elsif rate <= th['falseCountMax']
              '摄像头通道可开'
            else
              '停在加速度计 + 手动确认'
            end
  puts "F13 #{row['name']} · #{row['device']} · 自检误计率=#{(rate * 100).round(1)}% → #{verdict}"
end

File.write(path, doc.to_yaml)
puts "已写入 #{path.sub("#{root}/", '')}；跑 tools/probe-gate.sh 复核一致性。"
