# SPEC: ASK-03, ASK-04, ASK-05, ASK-10, PACK-04, PRODUCT-§5
# 知识点状态机与补一补池：状态只由答题事件推，不由时间、也不由他人手工设定（ASK-03）。
# 星级只是「下一次选题」的输入，不是可扣的账（AUTO-13、ASK-10）。
module Core
  module Kp
    STATES = %w[unseen learning shaky weak mastered].freeze
    # 同一个知识点连对 3 题入 mastered（ASK-03）；答错先出一道 basic 确认题（ASK-05 的去重上限）。
    MASTERED_RUN = 3
    CONFIRMATION_TO = { 'correct' => 'shaky', 'wrong' => 'weak' }.freeze
    # 补一补池的容量是四量 backlogSize 的封顶值，不在这里再写一个数（ASK-04、PACK-04）。
    def pool_cap
      Core::Ledger::BACKLOG_CAP
    end
    EVICTED = 'oldest'.freeze
    # 答错过的题按大纲相关度优先重问一次；一个任务内最多一道确认题（ASK-04、ASK-05）。
    REASK_AFTER_WRONG = 1

    module_function

    # 一次作答之后这个知识点落到哪个状态。confirmation 是那道确认题的结果，没有就还定不下来。
    def after_answer(state:, correct:, confirmation: nil, run: 0)
      if correct
        return 'mastered' if run.to_i + 1 >= MASTERED_RUN

        state.to_s == 'unseen' ? 'learning' : state.to_s
      elsif confirmation
        CONFIRMATION_TO.fetch(confirmation.to_s, state.to_s)
      else
        # 答错但要等确认题的结果才迁移；这一步先把错题入池，状态不动。
        state.to_s
      end
    end

    # 激励只入星与掌握进度：答对入星，答错也不扣（AUTO-13、ASK-10）。
    def stars(_correct)
      'credited'
    end

    # 星数就是答对题数的入账，没有扣分这一项（AUTO-13）。
    def star_count(correct_answers)
      correct_answers.to_i
    end

    def priority_reask(wrong_answers)
      wrong_answers.to_i >= REASK_AFTER_WRONG ? 1 : 0
    end

    # 前置未掌握不阻塞出后续题，但依赖关系要显示在面板上（ASK-02）。
    def dependency_shown?(_prereq_state)
      true
    end
  end
end
