# SPEC: PACK-02, PACK-09
# 内容包的许可与来源只在这里答一次（D82）：白名单、那唯一一条条件条目、按年级的绑定、署名的落点。
# 判定不在门里写第二遍——tools/check-packs.rb 调这几条，夹具也调这几条。
require 'json'

module Core
  module Content
    ROOT = File.expand_path('..', __dir__)
    CONTRACT = JSON.parse(File.read(File.join(ROOT, 'contract/contract.json')))
    CONF = CONTRACT.fetch('contentPack')
    LIC = CONF.fetch('license')
    SOURCE = CONF.fetch('source')

    module_function

    # 私域还是公开：这一处答（跟着 D29、D30 走）。条件条目就看它。
    def distribution
      CONF['distribution'].to_s
    end

    def pack_license
      SOURCE['license'].to_s
    end

    # 这台设备带没带题库那一行（D82、D84）：措辞只在这里拼一处，两个内核都从这一处拼。
    # 带没带是**声明**不是推断——包体不入库、APK 里不带，拿「本地有没有 packs/」去推断，
    # 在 Mac 上会报成「带了」，而那恰恰是设备上错的那一句。
    def on_device_line
      node = CONF['onDevice'] || {}
      return node['absent'].to_s unless node['carried']

      row = (Array(CONF['attributionVisible']).find { |r| r['check'].to_s == 'pack' } || {})
      node['present'].to_s.sub('{packId}', row['packId'].to_s)
              .sub('{source}', SOURCE['project'].to_s)
              .sub('{license}', pack_license)
    end

    # 那一行的开头那一小段（「题库：」）：夹具与面板用它认这一行，不重抄前缀。
    def on_device_prefix
      line = (CONF.dig('onDevice', 'carried') ? CONF.dig('onDevice', 'present') : CONF.dig('onDevice', 'absent')).to_s
      line.split('：').first.to_s + '：'
    end

    # 那一行属于哪一类（夹具用这个，不拿整句比：拼两句就多出一处措辞）。
    def on_device_line_kind
      CONF.dig('onDevice', 'carried') ? 'present' : 'absent'
    end

    # 白名单 + 那唯一一条条件条目。禁词先判：带 ND/SA/保留所有权利的，一律拒。
    def license_ok?(lic, dist = distribution)
      l = lic.to_s.strip
      return false if Array(LIC['forbiddenMarks']).any? { |m| !m.to_s.strip.empty? && l.upcase.include?(m.to_s.upcase) }
      return true if Array(LIC['allowed']).include?(l)

      cond = Array(LIC['conditional']).find { |x| x['license'].to_s == l }
      return false unless cond

      cond['requiresDistribution'].to_s == dist.to_s
    end

    def conditional?
      Array(LIC['conditional']).any? { |x| x['license'].to_s == pack_license }
    end

    # 条件条目要求的分布（现在写的是 private）；门与夹具都读这一处。
    def conditional_requires
      Array(LIC['conditional']).find { |x| x['license'].to_s == pack_license }&.fetch('requiresDistribution', nil).to_s
    end

    # 撤销那几条：一条都不许省——转公开、开始收费、对外分发，任一发生这一条就得撤。
    def revoke_rules
      Array(LIC['conditional']).flat_map { |x| Array(x['revokeIf']) }
    end

    def revoked?
      return false unless conditional?

      conditional_requires != distribution
    end

    def pack_id
      CONF['packId'].to_s
    end

    # 预设「手上有那一本教材」的那类题：不进给出的题集（导出时滤掉，门再验一遍）。
    # 题的字段那一节只在这里答一次：门与导出都读它，两边各写一份就会漂（PACK-06）。
    # 机检那一格的字段名只在这里答：门与导出读同一格（ASK-08、PACK-06）。
    def verify_field
      CONF.dig('verifyRequired', 'field').to_s
    end

    def question_schema
      Array(CONF['schemas'])
    end

    def textbook_filter?
      CONF.dig('textbookDependent', 'filter') == true
    end

    def textbook_marks
      Array(CONF.dig('textbookDependent', 'marks'))
    end

    def textbook_hit?(text)
      textbook_marks.any? { |m| text.to_s.include?(m.to_s) }
    end

    # 绑表只在这一处：按受众分岔就在这里（内容绑定解析）——PACK-06、PROFILE-02。
    # 下面那个函数只把绑表里那一行的名字递进来，自己不按受众分岔。
    # audience-site: 内容绑定解析（这一档从哪些年级取题）（PACK-06、PROFILE-02）
    def grades_for(audience)
      row = CONF.fetch('audienceBinding').find { |b| b['audience'].to_s == audience.to_s }
      Array(row&.fetch('grades', []))
    end

    def excluded_grades
      Array(CONF['excludedGrades'])
    end

    # 按年级绑：高中段一题都不绑（D76——大人与老人的约定项不含题目，高中段没有要出题的那一档）。
    def grade_ok?(binding_row, grade)
      g = grade.to_i
      return false if excluded_grades.include?(g)

      grades_for(binding_row).include?(g)
    end

    def high_school_bound?
      binding_grades = CONF.fetch('audienceBinding').flat_map { |b| Array(b['grades']) }
      (binding_grades & excluded_grades).any?
    end

    def binding_grades
      CONF.fetch('audienceBinding').flat_map { |b| Array(b['grades']) }.uniq
    end

    # 署名的落点逐条带状态：已落的那几处必须真在文件里找得到，未落的那几处不许冒充已落。
    def attribution_landed
      Array(CONF['attributionVisible']).count { |a| a['state'].to_s == '已落' && landed?(a) }
    end

    def attribution_pending
      Array(CONF['attributionVisible']).count { |a| a['state'].to_s == '未落' }
    end

    # 已写了已落、实际找不到——这一条要红，不是这一条算通过。
    def attribution_broken
      Array(CONF['attributionVisible']).count { |a| a['state'].to_s == '已落' && !landed?(a) }
    end

    def landed?(row)
      case row['check'].to_s
      when 'pack'
        true # 包内 ATTRIBUTION.md 由 tools/check-packs.rb 逐包查
      else
        f = File.join(ROOT, row['check'].to_s)
        File.exist?(f) && File.read(f).include?(row['packId'].to_s)
      end
    end
  end
end
