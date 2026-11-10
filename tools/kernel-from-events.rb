# 把设备上的事件账（一行一条 JSON）喂给 Ruby 那份规范模型，返回这份 CommitState。
# 存在的理由只有一个：设备测试要拿它当基准，与设备上算出的那份逐字段比（两端同源）。
require 'json'
require_relative 'run-fixtures'

def kernel_from_events(events_json, plans = nil)
  w = World.new({})
  w.send(:load_plans, plans) if plans # 这两个入口是给两端同源用的，不当公共接口
  events_json.each_line do |line|
    line = line.strip
    next if line.empty?

    e = JSON.parse(line)
    fields = { ms: e.dig('fields', 'ms').to_i, pauseMs: e.dig('fields', 'pauseMs').to_i }
    kind = e.dig('fields', 'kind')
    fields[:kind] = kind if kind # 动议是哪一种也要进账：受理了的「延一延」不是暂停（COMMIT-07）
    accepted = e.dig('fields', 'accepted')
    fields[:accepted] = accepted unless accepted.nil? # 婉拒与接受是同一条事件，靠这一项分（AUTO-03）
    fields[:at] = e['at'].to_i if e['at']
    w.send(:append, e['kind'].to_sym, e['profile'].to_s, **fields.compact)
    w.send(:activate, e['profile'].to_s) if e['kind'] == 'PROFILE_SWITCH' # 换到哪一档就按那一组算（AGREE-08）
  end
  w.commit_state
rescue StandardError => e
  "#{e.class}: #{e.message}"
end
