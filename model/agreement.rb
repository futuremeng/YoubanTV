# SPEC: AGREE-05, AGREE-06, AGREE-13, DAY-08, PROFILE-01
# 首启那六步的屏幕内容只在这里生成（AGREE-05）：问什么、有哪些可选、按默认是什么、
# 按默认的那一步去哪儿改，全都读契约 agreement。设备端（Kotlin Kernel.setup）与这条必须同源，
# 由 tools/align-core.rb 逐屏比对——一边多一句、少一句都会红（D42、D47）。
# 界面上不出现字段名：要改哪一项，屏上带着 field 这个键，壳层原样交回 cycle。
require 'json'
require 'panel'

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
        # 那一页还没做界面时，这一句得带上「这条路径现在没有」（PANEL-02、D80）：可用性只在 panel.availability 那一处答。
        line += at['where'] ? UI['defaultsWhere'].to_s.sub('{where}', Core::Panel.where_text(at['where'])) : ''
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

    PANEL = AGREEMENT.fetch('panel').to_h.freeze
    MOTION = CONTRACT.fetch('motion').to_h.freeze
    HISTORY = MOTION.fetch('history').to_h.freeze

    # 动议那一路的历史（AUTO-03）：只读，挂在同一屏的下半段——不另开一屏、不催第二次。
    # 种类的名字只在契约 motion.kinds 那一处；受理那一条在账上是 MOTION_SETTLED，
    # 婉拒与没受理在账上是同一条（没受理记 MOTION_UNANSWERED），这里不替谁编结论。
    # 婉拒与没受理在账上不是两条结论：accepted=false 才是婉拒，没这一条就是接受了。
    # 0 / false 两种写法同一个意思（设备上字段曾按数字存过），两边一处认。
    def declined?(v)
      v == false || v == 0
    end

    def history_lines(events)
      kinds = MOTION.fetch('kinds').reject { |k, _| k == 'x-note' }
      events.to_a.map do |e|
        h = e.to_h.transform_keys(&:to_sym)
        h[:fields] = h[:fields].to_h.transform_keys(&:to_sym) if h[:fields].is_a?(Hash)
        kind = kinds[h[:fields][:kind].to_s] || kinds['unknown']
        who = h[:actor] || h[:profile]
        when_ms = (h[:at].to_i / 1000).to_i
        stamp = when_ms.positive? ? when_ms.to_s : '—'
        line = case h[:kind].to_s
               when 'MOTION' then HISTORY['proposed']
               when 'MOTION_SETTLED' then declined?(h[:fields][:accepted]) ? HISTORY['declined'] : HISTORY['accepted']
               when 'MOTION_UNANSWERED' then HISTORY['unanswered']
               end
        next if line.nil?

        line.sub('{kind}', kind).sub('{by}', who.to_s).sub('{when}', stamp)
      end.compact
    end

    # 「这一档现在按哪几项跑」那一屏（AGREE-14）：全是读——没有按钮、没有红点、没有完成度。
    # 取值只从两处来：契约那张默认表垫底 + 这一档存过的那份盖上来；签署那一行取自账里的 PLAN_SIGNED。
    # 取值怎么写只在这一处（timeFields / units / trueWord / falseWord 都在 agreement.panel 里）。
    # audience-site: 默认值挑选 —— 这一档的受众挑默认那一行（PROFILE-01、PROFILE-02）。
    def panel(events: [], profile: nil, plans: {})
      stored = plans[profile.to_s] || plans[profile.to_sym] || {}
      plan = Day.default_plan(stored['audience'] || stored[:audience] || 'child',
                              stored['dayType'] || stored[:dayType] || 'schoolday')
      stored.each { |k, v| plan[k.to_s] = v unless v.nil? }

      lines = []
      # 事件可能是符号键（模型内部）也可能是字符串键（从设备读回来的那一份）：两边一律当同一种读。
      events = events.to_a.map do |e|
        h = e.to_h.transform_keys(&:to_sym)
        h[:fields] = h[:fields].to_h.transform_keys(&:to_sym) if h[:fields].is_a?(Hash)
        h
      end
      signed = events.reverse.find { |e| e[:kind].to_s == 'PLAN_SIGNED' && e[:profile].to_s == profile.to_s }
      if signed.nil?
        lines << PANEL['unsigned']
      else
        at = (signed[:at].to_i / 1000).to_i
        version = (signed[:fields].to_h[:version] || 1).to_i
        who = signed[:actor] || profile
        lines << PANEL['signed'].sub('{version}', version.to_s).sub('{who}', who.to_s)
                          .sub('{when}', at.positive? ? at.to_s : '—')
      end
      FIELDS.each_value do |f|
        id = f['id'].to_s
        next unless plan.key?(id)

        lines << PANEL['row'].sub('{label}', f['uiWords'].to_s).sub('{value}', shown_value(id, plan[id]))
      end
      lines += history_lines(events)
      { 'title' => PANEL['title'], 'lines' => lines, 'foot' => [PANEL['timeSource'], HISTORY['foot']].join(' · '),
        'never' => (PANEL['never'].to_a + HISTORY['never'].to_a).uniq }
    end

    def shown_value(id, raw)
      if PANEL['timeFields'].to_a.include?(id) && raw.is_a?(Numeric)
        "#{(raw.to_i / 60_000)}#{PANEL.dig('units', 'minutes')}"
      elsif raw == true
        PANEL['trueWord']
      elsif raw == false
        PANEL['falseWord']
      else
        raw.to_s
      end
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
