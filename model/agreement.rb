# SPEC: AGREE-05, AGREE-06, AGREE-13, DAY-08, PROFILE-01
# 首启那六步的屏幕内容只在这里生成（AGREE-05）：问什么、有哪些可选、按默认是什么、
# 按默认的那一步去哪儿改，全都读契约 agreement。设备端（Kotlin Kernel.setup）与这条必须同源，
# 由 tools/align-core.rb 逐屏比对——一边多一句、少一句都会红（D42、D47）。
# 界面上不出现字段名：要改哪一项，屏上带着 field 这个键，壳层原样交回 cycle。
require 'json'

module Core
  module Agreement
    CONTRACT = JSON.parse(File.read(File.expand_path('../contract/contract.json', __dir__)))
    AGREEMENT = CONTRACT.fetch('agreement')
    FIELDS = AGREEMENT.fetch('fields').to_a.map { |f| [f['id'].to_s, f] }.to_h.freeze
    UI = AGREEMENT.fetch('ui').to_h.freeze
    STEPS = AGREEMENT.fetch('firstRun').to_a.freeze

    module_function

    # 六步的描述：每一步问哪几项、当前值是什么（没存过的按契约那张默认表）。
    def setup(plan = {})
      plan = plan.reject { |_, v| v.nil? }
      {
        'ui' => UI,
        'total' => STEPS.size,
        'steps' => STEPS.map do |step|
          asks = Array(step['asks']).map(&:to_s)
          {
            'step' => step['step'].to_i,
            'do' => step['do'],
            'asks' => asks,
            'note' => note_of(step),
            'where' => step['where'],
            'fields' => asks.map do |id|
              f = FIELDS.fetch(id)
              choices = Array(f['choices']).map { |c| { 'value' => c['value'], 'label' => c['label'] } }
              current = plan.key?(id) ? plan[id] : f['default']
              current = defaults_for(plan)[id] if current.nil?
              {
                'id' => id,
                'label' => f['uiWords'],
                'choices' => choices,
                'value' => current,
                'valueLabel' => label_for(choices, current)
              }
            end
          }
        end
      }
    end

    # 第 index 屏：一屏只改一项（遥控器上一步一项）。抬头、那一项的现值、脚下那句提示，
    # 全都来自契约 agreement.ui 那一处（AGREE-05）。
    def setup_screen(plan = {}, index = 0, version = 1, signed = false)
      described = setup(plan)
      list = screens(described)
      at = list[[index.to_i, 0].max] || list.last
      at = list.last if at.nil?
      total = list.size
      lines = [UI['header'].to_s.sub('{step}', (index + 1).to_s).sub('{total}', total.to_s).sub('{do}', at['do'].to_s)]
      if at['note']
        # 按默认的那一步必须写明去哪儿改；契约没写 where 就是这条没做完，屏幕上不留空话（AGREE-13）。
        line = UI['noteOnly'].to_s.sub('{note}', at['note'].to_s)
        line += at['where'] ? UI['defaultsWhere'].to_s.sub('{where}', at['where'].to_s) : ''
        lines << line
      elsif at['id']
        lines << UI['field'].to_s.sub('{label}', at['label'].to_s).sub('{value}', at['valueLabel'].to_s)
      end
      lines << (signed ? UI['signing'] : UI['sign']).to_s.sub('{version}', version.to_s) if index + 1 == total
      {
        'title' => at['do'],
        'where' => at['where'],
        'lines' => lines,
        'field' => at['id'],
        'foot' => at['id'].nil? ? UI['leave'] : UI['hint'],
        'last' => index + 1 == total
      }
    end

    # 左右键在一项的可选值里走一步：可选值与顺序都在契约 fields.choices（界面上不许另列一份）。
    def cycle(plan, field_id, backward = false)
      step = STEPS.find { |s| Array(s['asks']).map(&:to_s).include?(field_id.to_s) }
      return plan if step.nil?

      f = FIELDS.fetch(field_id.to_s)
      choices = Array(f['choices']).map { |c| c['value'] }
      return plan if choices.empty?

      current = plan.key?(field_id) ? plan[field_id] : f['default']
      at = choices.index(current) || 0
      nxt = backward ? (at - 1) % choices.size : (at + 1) % choices.size
      plan.merge(field_id.to_s => choices[nxt])
    end

    # 把六步摊成屏：不用选的步骤出一屏说明，要选的每项出一屏。
    # 契约最后一步就是「双方签署」，不另加一屏（那一屏只出「确认后写入第几份」那句）。
    def screens(described)
      out = []
      described['steps'].each do |step|
        if step['asks'].empty?
          out << { 'do' => step['do'], 'note' => step['note'], 'where' => step['where'],
                   'id' => nil, 'label' => nil, 'valueLabel' => step['do'] }
        else
          step['fields'].each do |f|
            out << { 'do' => step['do'], 'note' => nil, 'where' => nil,
                     'id' => f['id'], 'label' => f['label'], 'valueLabel' => f['valueLabel'] }
          end
        end
      end
      out
    end

    # 「第 N 步」与「第 N 屏」不是一回事：一步可能出好几屏（一项一屏）。
    # 这条换算只在这里写一次，界面上与夹具里都不要再数一遍（AGREE-05）。
    def screen_index_for_step(step)
      at = 0
      STEPS.each do |s|
        return at if s['step'].to_i == step.to_i

        at += Array(s['asks']).size.zero? ? 1 : Array(s['asks']).size
      end
      nil
    end

    # 「这一步为什么不用选」那句话的唯一出处：契约写了 note 用 note，没写就不显示这一行。
    def note_of(step)
      step['note']
    end

    # 按默认那一行读的那张表：换受众就是换那一行（契约 agreement.defaults，D45）。
    # audience-site: 默认值挑选 —— 按受众挑默认那一行，是允许的两处分支之一（PROFILE-01、PROFILE-02）。
    def defaults_for(plan)
      Day.default_plan(plan['audience'] || 'child', plan['dayType'] || 'schoolday')
    end

    def label_for(choices, value)
      hit = choices.find { |c| c['value'] == value }
      hit ? hit['label'].to_s : value.to_s
    end
  end
end
