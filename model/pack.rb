# SPEC: PACK-01, PACK-02, PACK-05, PACK-06, PACK-07, PACK-09, ASK-01
# 装包与验包只在这里判一次（D84）：门（tools/check-packs.rb）调它，选题也调它——
# 两边各验一遍会出「门绿着而模型取到没验过的题」那种错。
# 许可那几条仍然不在这儿写：调 model/content.rb 那一处（PACK-02、D82）。
require 'json'
require 'digest'
require 'openssl'
require 'fileutils'
require 'tmpdir'
require_relative 'content'

module Core
  module Pack
    ROOT = File.expand_path('..', __dir__)
    CONF = Core::Content::CONF
    DIR = File.join(ROOT, CONF.fetch('dir').to_s)
    REQUIRED = %w[packId version license attribution source checksums signature audience
                  presentationHints outline questionCount schemas].freeze

    module_function

    def installed
      Dir.glob(File.join(DIR, '*.qpack'))
    end

    # 这道门要报的每一条红，都在这里生成（门只负责把它们打出来）。
    def verify(qpack)
      label = File.basename(qpack)
      bad = []
      Dir.mktmpdir ['qpack', '.d'] do |out|
        system('unzip', '-q', qpack, '-d', out)
        manifest_path = File.join(out, 'manifest.json')
        unless File.exist?(manifest_path)
          return ["#{label}：没有 manifest.json（PACK-01 的字段齐全是安装前置条件）"]
        end
        m = JSON.parse(File.read(manifest_path))
        missing = REQUIRED.reject { |k| m.key?(k) }
        return ["#{label}：manifest 缺字段 #{missing.join('、')}（PACK-01）"] unless missing.empty?

        lic = m['license'].to_s
        unless Core::Content.license_ok?(lic)
          why = if Core::Content.conditional? && Core::Content.revoked?
                  "它走的是那条条件条目，而条件要求 #{Core::Content.conditional_requires}——现在的分布是 " \
                  "#{Core::Content.distribution}（#{Core::Content.revoke_rules.join('、')}，任一发生就要撤）"
                else
                  '白名单是 ' + Array(Core::Content::LIC['allowed']).join('/') + '，条件条目只有一条'
                end
          bad << "#{label}：许可 #{lic.inspect} 拒装——#{why}"
        end

        cs = m['checksums'] || {}
        cs.each do |f, sum|
          p2 = File.join(out, f)
          if !File.exist?(p2)
            bad << "#{label}：#{f} 找不到（checksums 里列了它）"
            next
          end
          bad << "#{label}：#{f} 校验和对不上（被改过或导出中断）" unless Digest::SHA256.file(p2).hexdigest == sum.to_s
        end
        keyfile = File.join(ROOT, m.dig('signature', 'keyFile').to_s)
        if File.exist?(keyfile)
          payload = JSON.generate(m.merge('signature' => nil))
          want = OpenSSL::HMAC.hexdigest('SHA256', File.read(keyfile).strip, payload)
          bad << "#{label}：签名对不上 manifest（有人动过 manifest 而不是动过数据文件）" unless want == m.dig('signature', 'value').to_s
        else
          bad << "#{label}：签名的 key 不在（#{m.dig('signature', 'keyFile')}）——这条路的签名只防误改，key 没了就验不了"
        end

        topics = jsonl(File.join(out, m.dig('outline', 'topics').to_s))
        edges = jsonl(File.join(out, m.dig('outline', 'edges').to_s))
        questions = questions(m, out)
        grade_by_id = index_of(topics)
        ids = topics.map { |t| t['id'].to_s }
        dangling = edges.reject { |e| ids.include?(e['topicId'].to_s) && ids.include?(e['prerequisiteId'].to_s) }
        bad << "#{label}：#{dangling.size} 条边指向包里没有的知识点（PACK-05 悬空引用）" unless dangling.empty?
        off = topics.reject { |t| grade_in?(t['grade']) }
        bad << "#{label}：#{off.size} 个知识点的年级不在绑定的年级里（高中段一题不绑，D76）" unless off.empty?

        # 题的字段按契约那一节齐（PACK-06）：缺 id 就没法判重，缺 verify 就没法机检。
        schema = Array(CONF.fetch('schemas'))
        off_schema = questions.reject { |q| schema.all? { |k| q.key?(k.to_s) } }
        bad << "#{label}：#{off_schema.size} 道题的字段不齐契约那一节的 #{schema.join('/')}（PACK-06）" unless off_schema.empty?
        noverify = questions.count { |q| q[Core::Content.verify_field].to_s.strip.empty? }
        bad << "#{label}：#{noverify} 道题的 #{Core::Content.verify_field} 是空的——机检不过的题不该进包（ASK-08）" if noverify.positive?
        bad << "#{label}：题数 #{questions.size} 与 manifest.questionCount #{m['questionCount']} 不一致" unless questions.size == m['questionCount'].to_i
        unknown_q = questions.reject { |q| ids.include?(q['topicId'].to_s) }
        bad << "#{label}：#{unknown_q.size} 道题挂在包外知识点上" unless unknown_q.empty?
        if Core::Content.textbook_filter?
          tb = questions.count { |q| Core::Content.textbook_hit?(JSON.generate(q)) }
          bad << "#{label}：#{tb} 道题的题面或解析预设「手上有那一本教材」，导出时没滤干净（D82）" if tb.positive?
        end

        attr = File.join(out, m.dig('attribution', 'file').to_s)
        body = File.exist?(attr) ? File.read(attr) : ''
        bad << "#{label}：ATTRIBUTION.md 空或没有来源 URL（PACK-03）" unless body.length > 80 && body.include?(m.dig('attribution', 'url').to_s)
        bad << "#{label}：ATTRIBUTION.md 没写许可 #{lic}" unless body.include?(lic)

        bad << "#{label}：这道门扫到的包里没有一道题可出（题数 0 或全在绑定年级外）" if questions.none? { |q| grade_in?(grade_by_id[q['topicId'].to_s]) }
        counts[label] = { 'topics' => topics.size, 'edges' => edges.size, 'questions' => questions.size, 'license' => lic }
      end
      bad
    end

    def counts
      @counts ||= {}
    end

    def present?
      !installed.empty?
    end

    # 取题走这一处：验过才打开（验不过就抛出来——取到没验过的题比不出题坏）。开过一次就缓存：
    # 一个 1.4MB 的包在夹具里被开上百次会慢到没法跑。
    def open(qpack = installed.first)
      raise ArgumentError, 'packs/ 里没有任何 .qpack：先 ruby tools/make-pack.rb（PACK-09）' if qpack.nil?

      # 缓存只在验过之后写：未验过的包不能因为谁先碰过它就被后续调用当真包用。
      @opened ||= {}
      return @opened[qpack] if @opened.key?(qpack)

      bad = verify(qpack)
      raise ArgumentError, "这道包没过验包：#{bad.join('；')}" unless bad.empty?

      dir = Dir.mktmpdir ['qpack', '.d']
      system('unzip', '-q', qpack, '-d', dir)
      m = JSON.parse(File.read(File.join(dir, 'manifest.json')))
      pack = { 'dir' => dir, 'manifest' => m,
               'topics' => jsonl(File.join(dir, m.dig('outline', 'topics').to_s)),
               'edges' => jsonl(File.join(dir, m.dig('outline', 'edges').to_s)),
               'questions' => questions(m, dir) }
      pack['gradeById'] = index_of(pack['topics'])
      @opened[qpack] = pack
      pack
    end

    def questions(m, dir)
      jsonl(File.join(dir, 'questions.jsonl'))
    end

    def jsonl(path)
      return [] unless File.exist?(path)

      File.readlines(path).map { |l| (JSON.parse(l) unless l.strip.empty?) }.compact
    end

    # 知识点 → 年级那一张表一次建好：每题都去知识点列表里现找，9562 题乘 2591 点就是 2500 万次比较，
    # 取一道题要 1.8 秒——这条是夹具跑到一半才发现的（一次建表，后面只查表）。
    def index_of(topics)
      topics.each_with_object({}) { |t, h| h[t['id'].to_s] = t['grade'] }
    end

    # 绑定年级这一处只有一张表（contentPack.audienceBinding，D82）：这里只查在不在表里，不另判。
    def grade_in?(grade)
      Core::Content.grade_ok?('child', grade.to_i)
    end

    def topic_ok?(topic_id, pack_or_topics)
      grade = if pack_or_topics.is_a?(Hash) && pack_or_topics['gradeById']
                pack_or_topics['gradeById'][topic_id.to_s]
              else
                index_of(Array(pack_or_topics))[topic_id.to_s]
              end
      grade_in?(grade)
    end

    # 大纲查询那一处（/api/topics 的名字，D86）：知识点与先修边只从包里的两张表答，
    # 不在别处再存一份大纲（PACK-05）。年级绑不绑这一处不自己判——问 contentPack.audienceBinding 那张表。
    # 大纲查询那一处（/api/topics 的名字，D86）：知识点与先修边只从包里的两张表答，
    # 不在别处再存一份大纲（PACK-05）。年级绑不绑这一处不自己判——问绑定表里那批年级（那张表只有一处）。
    # 这里不收 audience：1.0 里出题只属于那一档（D76），要问哪个年级直接问那张表，少一个分支位点。
    def outline(grade: nil, pack: nil)
      row = endpoint_row
      return { 'refusal' => row['refusal'].to_s.sub('{grade}', grade.to_s) } unless in_binding?(grade)

      pack ||= open
      by_id = pack['topics'].each_with_object({}) { |x, h| h[x['id'].to_s] = x }
      prereqs = pack['edges'].each_with_object({}) { |e, h| (h[e['topicId'].to_s] ||= []) << e['prerequisiteId'].to_s }
      counts = pack['questions'].each_with_object(Hash.new(0)) { |q, h| h[q['topicId'].to_s] += 1 }
      rows = pack['topics'].select { |x| grade.nil? || x['grade'].to_i == grade.to_i }.map do |x|
        { 'grade' => x['grade'], 'topicId' => x['id'].to_s, 'title' => x['title'].to_s,
          'gradeBound' => grade_in?(x['grade']), 'prerequisites' => prereqs[x['id'].to_s].to_a,
          'questionCount' => counts[x['id'].to_s] }
      end
      { 'rows' => rows.sort_by { |r| r['topicId'] }, 'fields' => Array(row['fields']) }
    end

    # 年级绑不绑：只问那张表（D76：高中段不在绑，那一档一题不出）。判定不在这里写第二遍。
    def in_binding?(grade)
      return Core::Content.binding_grades.include?(grade.to_i) unless grade.nil?

      Core::Content.binding_grades.any?
    end

    def endpoint_row
      (Core::Content::CONTRACT['endpoints'] || []).find { |e| e['path'].to_s == '/api/topics' } || {}
    end

    # 这一档该出哪一道：绑定年级 → 该知识点的难度那一档 → 账里答过的排除掉（ASK-01 的 pack 层）。
    # 池空了就 return nil——按 ASK-01 那一条顺序往下落一层，不在这里编一道题，也不重复出答过的。
    def pick(plan, answered_ids: [], seed: nil, pack: nil)
      pack ||= open
      ladder = CONF.dig('pick', 'difficultyLadder') || {}
      order = Array(CONF.dig('pick', 'difficultyOrder'))
      pool = pack['questions'].select { |q| topic_ok?(q['topicId'], pack) }
      pool = pool.reject { |q| answered_ids.include?(q['id'].to_s) } if CONF.dig('pick', 'excludeAnswered') != false
      return nil if pool.empty?

      want = ladder[plan.to_s] || ladder['default']
      step = order.index(want) || 0
      # 难度阶梯：这一档没人答对过就往上退一级找，退到底也没有就拿整池的第一个——
      # 顺序是确定的（按 id 排），同一天的同一轮跑两次出同一道题（不靠随机数）。
      cand = pool.select { |q| q['difficulty'].to_s == want.to_s }
      cand = pool.select { |q| order.index(q['difficulty'].to_s).to_i <= step } while cand.empty? && (step -= 1).positive?
      cand = pool if cand.empty?
      cand.sort_by { |q| q['id'].to_s }.first
    end

    # 答过的题的集合：只有一个出处——账里 ANSWER 那条的 questionId（没有这个字段就没法判重，D84）。
    def answered_ids(ledger_rows)
      Array(ledger_rows).map do |e|
        h = e.respond_to?(:to_h) ? e.to_h : e
        next unless h[:kind].to_s == 'ANSWER' || h['kind'].to_s == 'ANSWER'

        (h[:fields] || h['fields']).to_h.transform_keys(&:to_s)['questionId']
      end.compact
    end

    def in_pack?(id)
      !installed.empty? && !pick({}, seed: nil, pack: nil).nil?
    rescue StandardError
      false
    end
  end
end
