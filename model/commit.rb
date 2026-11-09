# SPEC: COMMIT-01, COMMIT-02, COMMIT-03, COMMIT-04, COMMIT-05, COMMIT-09, COMMIT-11, LAYER-02, LAYER-07, PROFILE-10
# 约定引擎：status / due / 落层的单点实现。界面与设备端只读这里的结论（COMMIT-09）。
require_relative 'day'
require_relative 'capability'

module Core
  module Commit
    TIER_ORDER = %w[L0 L1 L1.5 L2 L3 L5].freeze
    # 形态首选层：focused 需要请求暂停，故不低于 L2；ambient 是 L1.5（LAYER-09）。
    FORM_TIER = { 'focused' => 'L2', 'ambient' => 'L1.5' }.freeze
    STRENGTH_DEFAULT_TIER = { 'accompanied' => 'L3', 'negotiated' => 'L2', 'selfManaged' => 'L1' }.freeze

    module_function

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
        return out.merge(status: 'honored', due: nil, tier: 'L1.5', wording: 'statusSentence',
                         shown: %w[恢复时刻], events: [], value: { 'pauseMs' => motion_state['pauseMs'].to_i })
      end

      unless Day.in_slot?(plan)
        shown = Day.slot_mode(plan) == 'onlyWithinSlots' ? %w[下一个可用时刻] : []
        return out.merge(status: 'honored', due: nil, tier: 'L1', shown: shown,
                         value: { 'watchedMs' => watched })
      end

      grace = plan['graceMs'].to_i
      allowance = plan['allowanceMs'].to_i

      if watched >= allowance
        # COMMIT-04：条件是 ≥ allowance；零量不写 OVER（写了只是噪声）
        over = [watched - allowance, 0].max
        out.merge(status: 'overdue', due: nil, tier: 'L1.5', wording: 'statusSentence',
                  events: over.positive? ? %w[OVER] : [], shown: %w[超出约定分钟数],
                  value: { 'overMs' => over, 'watchedMs' => watched })
      elsif watched < grace
        out.merge(status: 'honored', due: nil, tier: 'L1', shown: %w[角标剩余],
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
      out.merge(status: 'honored', due: nil, tier: 'L1.5', shown: %w[选择身份的提示],
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
      quiz_open = watched < move_from && q['answeredInTask'].to_i < round_target
      exercise_open = watched >= move_from && q['roundsDone'].to_i < plan.fetch('exerciseRounds', 1).to_i
      return honored_after_done(out, watched) unless quiz_open || exercise_open

      # 表的字面：COMMIT-02 是 grace ≤ watched < moveFrom；COMMIT-03 是 watched ≥ moveFrom。
      kind = watched >= move_from && exercise_open ? 'exercise' : 'quiz'
      want = (mode || plan['form'] || 'ambient').to_s
      ceiling = STRENGTH_DEFAULT_TIER.fetch(strength.to_s, 'L2')
      want = 'ambient' unless focused_holds?(form: want, capability: capability, probe: probe,
                                             requested: requested, strength: strength)
      tier = tier_min(FORM_TIER.fetch(want, 'L1.5'), ceiling)
      # 回退规则只有一条：该层必需的能力拿不到，就落到最保守的可用档并在画面里写明原因（LAYER-08）。
      missing = Capability.missing_for(tier, capability)
      fallback = nil
      unless missing.empty?
        want = 'ambient'
        tier = tier_min(FORM_TIER.fetch(want, 'L1.5'), ceiling)
        fallback = '当前模式与原因'
      end
      extra = { 'playerPaused' => missing.empty?, 'resumedAfterAnswer' => missing.empty?, 'retried' => false }
      extra['tierCeilingLifted'] = false if want == 'ambient' && ceiling == 'L3'
      shown = want == 'focused' ? %w[约定 该做的事 窗口期] : %w[角标剩余 当前模式与原因]
      out.merge(status: 'due', tier: tier, mode: want, next_action: kind, tierCeiling: ceiling,
                wording: want == 'focused' ? 'nextStep' : 'statusSentence',
                due: { 'kind' => kind, 'mode' => want,
                       'deficit' => kind == 'quiz' ? 'questions' : 'reps',
                       'window' => 'present' },
                events: [], shown: shown, fallbackReason: fallback,
                value: { 'ruleId' => 'present', 'watchedMs' => watched }.merge(extra))
    end

    def honored_after_done(out, watched)
      out.merge(status: 'honored', due: nil, tier: 'L1', events: %w[DONE],
                value: { 'watchedMs' => watched })
    end

    # 受理后的加时：约定线后移，不算收紧（D37、COMMIT-04）。
    def apply_extend(plan, minutes)
      offset = minutes.to_i * 60_000
      [plan.merge('allowanceMs' => plan['allowanceMs'].to_i + offset), offset]
    end
  end
end
