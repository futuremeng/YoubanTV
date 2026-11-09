#!/usr/bin/env ruby
# 把一轮 given/when 跑成内核输出的 CommitState —— 这就是电视端将来 fetch 的那一份东西。
# 输出结构由 contract.json 的 commitState 定义，模型实现见 model/commit.rb（M1.4：四处一致）。
#
# 用法：
#   ruby tools/tv-status.rb fixtures/commit.yaml COMMIT-01        # 该条的第一条用例
#   ruby tools/tv-status.rb fixtures/commit.yaml COMMIT-07.2      # 该条的第 2 条用例
#   ruby tools/tv-status.rb --state '{"given":{...},"when":{...}}' # 自己拼一轮
#   ruby tools/tv-status.rb fixtures/day.yaml DAY-08 --raw        # 只出 JSON，给脚本接
require 'json'
require 'yaml'
require_relative 'run-fixtures'

def build(argv)
  state_arg = argv.find { |a| a.start_with?('--state=') }
  return JSON.parse(state_arg.sub('--state=', '')) if state_arg

  file, id = argv.reject { |a| a.start_with?('--') }
  abort '用法：tv-status.rb <fixtures/x.yaml> <ID[.n]> | --state=\'{"given":…,"when":…}\'' unless file && id

  doc = YAML.load_file(file)
  _, body = doc.find { |k, _| k == id.split('.').first }
  abort "#{id} 不在 #{file} 里" unless body

  idx = id.include?('.') ? id.split('.').last.to_i - 1 : 0
  cs = body['cases'][idx]
  abort "#{id.split('.').first} 没有第 #{idx + 1} 条用例" unless cs

  [(body['given'] || {}).merge(cs['given'] || {}), cs['when'] || {}]
end

def commit_state(given, when_)
  world = World.new(given)
  unless world.unconsumed.empty?
    abort "这一轮的状态键 #{world.unconsumed.join(', ')} 模型尚未消费，不硬凑结论"
  end

  world.apply(when_)
  world.commit_state
end

given, when_ = build(ARGV)
st = begin
  commit_state(given, when_)
rescue Unsupported => e
  # 答不上就说答不上，不硬凑一个结论出来（D41）。
  abort "这一轮答不上：#{e.message}"
end

puts JSON.pretty_generate(st)
exit 0 if ARGV.include?('--raw')

puts '-' * 46
puts format('状态 %s · 落层 %s（天花板 %s）· 呈现 %s',
            st['status'], st['tier'], st['tierCeiling'], Array(st['surface']).join('/'))
if st['due']
  puts format('到期项 %s（%s）· 还差 %s %s · 怎么问 %s',
              st['due']['kind'], st['due']['mode'], st['due']['deficit']['amount'],
              st['due']['deficit']['unit'], st['due']['howToAsk'])
else
  puts '无到期项：只有角标与状态句，不打断观看'
end
puts "回退原因 #{st['fallbackReason'].inspect}" if st['fallbackReason']
