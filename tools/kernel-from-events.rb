# 把设备上的事件账（一行一条 JSON）喂给 Ruby 那份规范模型，返回这份 CommitState。
# 存在的理由只有一个：设备测试要拿它当基准，与设备上算出的那份逐字段比（两端同源）。
require 'json'
require_relative 'run-fixtures'

def kernel_from_events(events_json)
  w = World.new({})
  events_json.each_line do |line|
    line = line.strip
    next if line.empty?

    e = JSON.parse(line)
    fields = { ms: e.dig('fields', 'ms').to_i, pauseMs: e.dig('fields', 'pauseMs').to_i }
    w.send(:append, e['kind'].to_sym, e['profile'].to_s, **fields.compact)
  end
  w.commit_state
rescue StandardError => e
  "#{e.class}: #{e.message}"
end
