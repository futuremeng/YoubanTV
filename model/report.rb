# SPEC: REPORT-01, REPORT-02, REPORT-03, REPORT-04
# 「这段时间的账」那一页：本项目没有周报，只有这一页（REPORT-01）。
# 每一行都从事件数出来——这一页不落第二本账（REPORT-02，与 D40 那条清单同一个理由）。
require 'json'

module Core
  module Report
    CONTRACT = JSON.parse(File.read(File.expand_path('../contract/contract.json', __dir__)))
    CONF = CONTRACT.fetch('report')
    # 不许有的那批词只有一份：写在 agreement.panel.never 那一处，这一页读同一份，不抄第二份（D45）。
    NEVER_SOURCE = CONF.fetch('neverFrom').to_s
    NEVER = NEVER_SOURCE.split('.').reduce(CONTRACT) { |n, k| n.is_a?(Hash) ? n[k] : nil }.to_a.freeze

    module_function

    def title
      CONF.fetch('title').to_s
    end

    def window_days(days = nil)
      return CONF.fetch('windowDefaultDays').to_i unless days

      days.to_i.positive? ? days.to_i : CONF.fetch('windowDefaultDays').to_i
    end

    # 行由契约那张表给；每一行都得指明是哪一种事件，不然就红——不许在这里另算一个数（REPORT-02）。
    def rows(ledger, profile)
      CONF.fetch('rows').map do |row|
        kind = row['kind'].to_s
        raise "这一行没指明事件种类：#{row.inspect}" if kind.empty?

        value = row['field'].to_s == 'count' ? ledger.count(profile, kind) : ledger.sum_ms(profile, kind, row['field'].to_s)
        { 'label' => row['label'].to_s, 'value' => value }
      end
    end

    def row_count(ledger, profile)
      rows(ledger, profile).size
    end

    def text(ledger, profile)
      ([title] + rows(ledger, profile).map { |r| CONF.fetch('row').sub('{label}', r['label']).sub('{value}', r['value'].to_s) }).join("\n")
    end

    # 这一页没有推送、没有区间对比、只看自己的（REPORT-01、REPORT-03）：三个都读契约那一处。
    def push?
      CONF['push'] == true
    end

    def comparison?
      CONF['comparison'] == true
    end

    def visible_to
      Array(CONF['visibleTo'])
    end

    def forbidden_words(ledger, profile)
      body = text(ledger, profile)
      NEVER.count { |w| body.include?(w.to_s) }
    end

    # 「清单不进那一页的账」（ONBOARD-05）不用另写一个 false：那一页的行只由 report.rows 那张表给，
    # 表里每一项都得是一种**事件**（REPORT-02）。有人加一行 from: checklist，这一条就自己变了。
    def includes_checklist?
      CONF.fetch('rows').to_a.any? { |r| r['from'].to_s == 'checklist' }
    end

    # 那一处只有这一处：不许有的那批词写在 agreement.panel.never（AGREE-14 那一处）。
    # 在这里另抄一份、或把 neverFrom 指到别处，都算第二份清单——那条断言就靠这个判（D45）。
    NEVER_SOURCE_CANONICAL = 'agreement.panel.never'.freeze

    def never_single_source?
      NEVER_SOURCE.to_s == NEVER_SOURCE_CANONICAL && NEVER.is_a?(Array) && !NEVER.empty?
    end
  end
end
