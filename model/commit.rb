# SPEC: COMMIT-01, COMMIT-02, COMMIT-03, COMMIT-04, COMMIT-05, COMMIT-09, COMMIT-11, LAYER-02, LAYER-07, PROFILE-10
# 约定引擎：status / due / 落层的单点实现。界面与设备端只读这里的结论（COMMIT-09）。
require 'json'

require_relative 'day'
require_relative 'capability'

module Core
  module Commit
    TIER_ORDER = %w[L0 L1 L1.5 L2 L3 L5].freeze
    # 形态首选层只由 due 的形状定，这张表就是那一处（契约 commitState.tierFor、ARCHITECTURE §9）：
    # focused 要请求播放器暂停，故不低于 L2；ambient 与「free / 动议」这类状态类结论落 L1.5；
    # 没有到期项时是 L1 角标，持续状态（overdue、已受理的暂停、未选身份）落 L1.5（LAYER-02、LAYER-09）。
    CONTRACT_COMMIT_STATE = JSON.parse(File.read(File.expand_path('../contract/contract.json', __dir__)))
                               .fetch('commitState')
    # 契约那张表按 id 取用：行序与措辞留在契约里，这里只拿层，不再抄一遍档位。
    TIER_ROW = CONTRACT_COMMIT_STATE.fetch('tierFor').to_h { |r| [r.fetch('id'), r.fetch('tier')] }.freeze
    FORM_TIER = { 'focused' => TIER_ROW.fetch('focused'), 'ambient' => TIER_ROW.fetch('ambient') }.freeze
    STRENGTH_DEFAULT_TIER = CONTRACT_COMMIT_STATE.fetch('strengthDefaultTier').freeze
    STATE_FIELDS = CONTRACT_COMMIT_STATE.fetch('fields').freeze

    module_function

    # 形态首选层：一个函数答完契约那张表的五行，别处不再各写一份 tier（D45）。
    def tier_for(due: nil, next_action: nil, persistent: false)
      return TIER_ROW.fetch('persistent') if due.nil? && persistent
      return TIER_ROW.fetch('noDue') if due.nil?
      return TIER_ROW.fetch('freeOrMotion') if due['kind'].to_s == 'free' || next_action.to_s == 'motion'

      TIER_ROW.fetch(due['mode'].to_s, TIER_ROW.fetch('persistent'))
    end

    # 内核输出的形状：字段名就是契约 commitState.fields 那一行，电视端读的是这一份（M1.4）。
    def state(profile:, plan:, q:, strength: 'negotiated', mode: nil, motion_state: {}, capability: {},
              probe: nil, requested: false, signed: true, pending: nil)
      v = decide(profile: profile, plan: plan, q: q, strength: strength, mode: mode,
                 motion_state: motion_state, capability: capability, probe: probe, requested: requested)
      {
        'status' => v[:status],
        'activeProfile' => profile.to_s == 'none' ? nil : profile.to_s,
        'planVersion' => plan.fetch('planVersion', 1),
        'due' => due_shape(v, q, plan),
        'tier' => v[:tier],
        'tierCeiling' => v[:tierCeiling],
        # 一份签过的约定都没有：下一步就是去把它立起来（AGREE-01、AGREE-04）。
        # 这一条不抬档位——界面上仍是 L1 那一行提示加常驻的一栏（AGREE-04）。
        'nextAction' => (signed || v[:due] ? v[:next_action] : 'agreement'),
        'wording' => v[:wording],
        'surface' => v[:surface],
        'fallbackReason' => v[:fallbackReason],
        'text' => text_of(v, q, plan),
        'panels' => panels_of(v, q, plan) + (signed ? [] : [PANELS.fetch('约定未立')]),
        'pendingMotion' => pending
      }
    end

    # 那句措辞的唯一拼法：句子与填空的小表都在契约里（commitState.sentences / .fill），
    # 界面那边不许再拼一遍——Java 里那份四条 if 的复制品就是从这个坑里长出来的（D47）。
    COMMIT_STATE = JSON.parse(File.read(File.expand_path('../contract/contract.json', __dir__)))
                         .fetch('commitState')
    SENTENCES = COMMIT_STATE.fetch('sentences')
    FILL = COMMIT_STATE.fetch('fill')
    PANELS = COMMIT_STATE.fetch('panels')

    # 常驻提示条与角标上那些小条：名字在 shown 里，句子在这张表里，数量从事件账的量来填。
    # 常驻栏只装契约里有句子模板的那几条（commitState.panels）。
    # 卡在 L2 那张卡上的段落（约定 / 该做的事 / 窗口期，LAYER-02）不是常驻栏，别把它们印成裸名字。
    def panels_of(v, q, plan)
      value = v[:value] || {}
      Array(v[:shown]).select { |name| PANELS.key?(name) }.map do |name|
        case name
        when '角标剩余' then PANELS.fetch(name).sub('{minutes}', ((value['remainingMs'].to_i / 60_000.0).ceil).to_s)
        when '超出约定分钟数' then PANELS.fetch(name).sub('{minutes}', ((value['overMs'].to_i / 60_000.0).ceil).to_s)
        when '进度'
          PANELS.fetch(name).sub('{done}', q['answeredInTask'].to_i.to_s)
                       .sub('{target}', (Day.effective_groups(plan) * plan.fetch('groupsPerTask', 1).to_i).to_s)
        else PANELS.fetch(name)
        end
      end
    end

    def text_of(v, q, plan)
      key = v[:sentence] || (v[:status] == 'overdue' ? 'overdue' : 'honored')
      text = SENTENCES.fetch(key)
      deficit = due_shape(v, q, plan)&.fetch('deficit') || {}
      unit = FILL.fetch('unit').fetch(deficit['unit'].to_s, '')
      kind = FILL.fetch('kind').fetch(v.dig(:due, 'kind').to_s, '')
      text.sub('{amount}', deficit.fetch('amount', 0).to_s).sub('{unit}', unit).sub('{kind}', kind)
    end

    # due 的形状照契约 dueFields；绝对时刻由设备端时钟填，模型只给相对量与当下窗口。
    def due_shape(v, q, plan)
      return nil unless v[:due]

      kind = v[:due]['kind']
      deficit = if kind == 'quiz'
                  { 'kind' => 'questions', 'unit' => 'questions',
                    'amount' => [plan.fetch('roundTarget', 5).to_i - q['answeredInTask'].to_i, 0].max }
                elsif kind == 'exercise'
                  { 'kind' => 'reps', 'unit' => 'reps',
                    'amount' => [plan.fetch('exerciseRounds', 1).to_i - q['roundsDone'].to_i, 0].max }
                else
                  { 'kind' => 'none', 'unit' => 'none', 'amount' => 0 }
                end
      {
        'kind' => kind,
        'mode' => v[:due]['mode'],
        'deficit' => deficit,
        'window' => { 'earliest' => v[:due]['window'], 'latest' => v[:due]['window'] },
        'howToAsk' => v[:due]['mode'] == 'focused' ? 'requestPauseThenAnswer' : 'badgeOnly',
        'ruleId' => v[:value]['ruleId'] || 'present',
        'nextAction' => v[:next_action]
      }
    end

    def tier_min(a, b)
      TIER_ORDER[[TIER_ORDER.index(a).to_i, TIER_ORDER.index(b).to_i].min]
    end

    # 单一入口：给当日方案 + 四量 + 强度与形态，产出判定与要写的事件。
    def decide(profile:, plan:, q:, strength: 'negotiated', mode: nil, motion_state: {}, capability: {},
               probe: nil, requested: false)
      watched = q['watchedMs'].to_i
      # 天花板由强度定，与身份无关（LAYER-07）；结论里一并给出，界面只读这一个值。
      out = base.merge(tierCeiling: Day.tier_ceiling(strength))
      return unselected(out) if profile.to_s == 'none'

      if motion_state['pause']
        # 已受理的暂停：冻结倒数，pauseMs 单列，状态层 L1.5（COMMIT-07）
        return out.merge(status: 'honored', due: nil, tier: tier_for(persistent: true),
                         wording: 'statusSentence', shown: %w[恢复时刻], events: [],
                         sentence: 'paused',
                         value: { 'pauseMs' => motion_state['pauseMs'].to_i })
      end

      # 免题段覆盖全天（老人那一行）：这句说明放常驻位置，不是不给理由（DAY-03、LAYERING §4）。
      quiet_note = plan['quiet'].to_s == 'allDay' ? %w[免题段说明] : []
      unless Day.in_slot?(plan)
        shown = Day.slot_mode(plan) == 'onlyWithinSlots' ? %w[下一个可用时刻] : []
        return out.merge(status: 'honored', due: nil, tier: tier_for, shown: shown,
                         sentence: 'outOfSlot',
                         value: { 'watchedMs' => watched })
      end

      grace = plan['graceMs'].to_i
      allowance = plan['allowanceMs'].to_i

      if watched >= allowance
        # COMMIT-04：条件是 ≥ allowance；零量不写 OVER（写了只是噪声）
        over = [watched - allowance, 0].max
        out.merge(status: 'overdue', due: nil, tier: tier_for(persistent: true), wording: 'statusSentence',
                  sentence: 'overdue',
                  events: over.positive? ? %w[OVER] : [], shown: %w[超出约定分钟数],
                  value: { 'overMs' => over, 'watchedMs' => watched })
      elsif watched < grace
        # 有当日任务额度时，常驻呈现要带今天的次数进度（DAY-05、LAYERING §4）。
        shown = %w[角标剩余] + quiet_note
        shown += %w[进度] if plan['groupsPerTask']
        out = out.merge(sentence: 'honored')
        out.merge(status: 'honored', due: nil, tier: tier_for, shown: shown,
                  value: { 'remainingMs' => grace - watched, 'watchedMs' => watched })
      else
        due_of(out, plan, q, strength, mode, watched, capability, probe, requested)
      end
    end

    def base
      { status: 'honored', due: nil, tier: 'L1', next_action: nil, wording: nil,
        surface: %w[self], events: [], shown: [], value: {}, blocked: false,
        tierCeiling: 'L2', fallbackReason: nil }
    end

    # 未选身份：只落账不判定，也不发任何邀请（COMMIT-11）。
    def unselected(out)
      out.merge(status: 'honored', due: nil, tier: tier_for(persistent: true), sentence: 'unselected',
                shown: %w[选择身份的提示],
                value: { 'eventProfile' => 'none', 'quizIssued' => false,
                         'exerciseInvite' => false, 'coWatchInvite' => false })
    end

    # focused 站不站得住，判据只有这三条，别处不要再各写一遍（D42、D45、LAYER-07、LAYER-08）：
    # 一、强度的天花板低于 focused 的下限 L2；二、实测样本没过 95% 这条线（D36）；
    # 三、走的是默认档、而本机有权能拿不到——显式请求时不看第三条，
    # 因为那时该由使用者负责，而不是让一条无关的能力把他的选择抹掉。
    def focused_holds?(form:, capability:, probe: nil, requested: false, strength: 'negotiated')
      return false unless form.to_s == 'focused'

      ceiling = STRENGTH_DEFAULT_TIER.fetch(strength.to_s, 'L2')
      return false if TIER_ORDER.index(ceiling) < TIER_ORDER.index('L2')
      return false if probe && !Capability.focused_default_ok?(probe)
      form_caps = Capability.enforcement_only(capability)
      return false unless Capability.missing_for(FORM_TIER['focused'], form_caps).empty?
      return true if requested

      !form_caps.values.any? { |v| Capability.fallback_for(v) == :fallback }
    end

    def due_of(out, plan, q, strength, mode, watched, capability = {}, probe = nil, requested = false)
      round_target = plan.fetch('roundTarget', 5).to_i
      move_from = plan['moveFromMs'].to_i
      # 这一档的约定项有哪几类，只由默认值挑选那一处给（PROFILE-11、D76）：清单里没有的种类不出到期项。
      # 大人与老人的约定项**不含题目**——屏上就不会出现「还差 N 题」那种兑现不了的承诺（内容不是本产品的前提）。
      # 存过的方案没这一项时按两类都开来算（老账原样跑，不因为这条改动而换结论）。
      kinds = plan.fetch('dueKinds', %w[quiz exercise])
      quiz_open = watched < move_from && q['answeredInTask'].to_i < round_target && kinds.include?('quiz')
      exercise_open = watched >= move_from && q['roundsDone'].to_i < plan.fetch('exerciseRounds', 1).to_i &&
                      kinds.include?('exercise')
      return honored_after_done(out, watched) unless quiz_open || exercise_open

      # 表的字面：COMMIT-02 是 grace ≤ watched < moveFrom；COMMIT-03 是 watched ≥ moveFrom。
      kind = watched >= move_from && exercise_open ? 'exercise' : 'quiz'
      want = (mode || plan['form'] || 'ambient').to_s
      ceiling = STRENGTH_DEFAULT_TIER.fetch(strength.to_s, 'L2')
      want = 'ambient' unless focused_holds?(form: want, capability: capability, probe: probe,
                                             requested: requested, strength: strength)
      tier = tier_min(tier_for(due: { 'kind' => kind, 'mode' => want }, next_action: kind), ceiling)
      # 回退规则只有一条：该层必需的能力拿不到，就落到最保守的可用档并在画面里写明原因（LAYER-08）。
      missing = Capability.missing_for(tier, capability)
      fallback = nil
      unless missing.empty?
        want = 'ambient'
        tier = tier_min(tier_for(due: { 'kind' => kind, 'mode' => want }), ceiling)
        fallback = '当前模式与原因'
      end
      extra = { 'playerPaused' => missing.empty?, 'resumedAfterAnswer' => missing.empty?, 'retried' => false }
      extra['tierCeilingLifted'] = false if want == 'ambient' && ceiling == 'L3'
      shown = want == 'focused' ? %w[约定 该做的事 窗口期] : %w[角标剩余 当前模式与原因]
      out.merge(status: 'due', sentence: want == 'focused' ? 'dueFocused' : 'dueAmbient',
                tier: tier, mode: want, next_action: kind, tierCeiling: ceiling,
                wording: want == 'focused' ? 'nextStep' : 'statusSentence',
                due: { 'kind' => kind, 'mode' => want,
                       'deficit' => kind == 'quiz' ? 'questions' : 'reps',
                       'window' => 'present' },
                events: [], shown: shown, fallbackReason: fallback,
                value: { 'ruleId' => 'present', 'watchedMs' => watched }.merge(extra))
    end

    def honored_after_done(out, watched)
      out.merge(status: 'honored', due: nil, tier: tier_for, sentence: 'honored', events: %w[DONE],
                value: { 'watchedMs' => watched })
    end

    # 受理后的加时：约定线后移，不算收紧（D37、COMMIT-04）。
    def apply_extend(plan, minutes)
      offset = minutes.to_i * 60_000
      [plan.merge('allowanceMs' => plan['allowanceMs'].to_i + offset), offset]
    end
  end
end
