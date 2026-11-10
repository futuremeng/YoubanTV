#!/usr/bin/env ruby
# SPEC: PACK-01, PACK-02, PACK-03, PACK-05, PACK-07, PACK-09
# 内容包这道门。判定不在这里写第二遍——许可那几条调 model/content.rb（PACK-02、D82）。
#
# 三条最要紧的：
#   一、**扫不到东西不算绿**：packs/ 里没有包就报「本地未导出」并以红收（PACK-09）。
#      这条是防「目录空 = 没有违规 = 通过」那种绿——它比红更贵，因为它会让人以为这道门在看守。
#   二、许可是条件条目时，分布一变就得红（contract.contentPack.distribution）。
#   三、高中段的题混进包里就红（D76：大人与老人的约定项不含题目，高中段没有要出题的那一档）。
require 'json'
require 'digest'
require 'openssl'
require 'fileutils'
require 'tmpdir'

root = File.expand_path('..', __dir__)
$LOAD_PATH.unshift File.join(root, 'model')
require 'content'

CONF = Core::Content::CONF
DIR = File.join(root, CONF.fetch('dir').to_s)
REQUIRED = %w[packId version license attribution source checksums signature audience
              presentationHints outline questionCount].freeze
bad = []
found = Dir.glob(File.join(DIR, '*.qpack'))

if found.empty?
  abort "内容包的门扫不到东西：#{DIR.sub("#{root}/", '')} 里没有任何 .qpack——本地未导出就跑 ruby tools/make-pack.rb（PACK-09：空目录不算绿）"
end

found.each do |qpack|
  label = File.basename(qpack)
  Dir.mktmpdir ['qpack', '.d'] do |out|
    system('unzip', '-q', qpack, '-d', out)
    manifest_path = File.join(out, 'manifest.json')
    unless File.exist?(manifest_path)
      bad << "#{label}：没有 manifest.json（PACK-01 的字段齐全是安装前置条件）"
      next
    end
    m = JSON.parse(File.read(manifest_path))
    missing = REQUIRED.reject { |k| m.key?(k) }
    bad << "#{label}：manifest 缺字段 #{missing.join('、')}（PACK-01）" unless missing.empty?
    next unless missing.empty?

    # 许可：调那一处判定；挡住的话要说清是哪一条（PACK-02）。
    lic = m['license'].to_s
    unless Core::Content.license_ok?(lic)
      why = if Core::Content.conditional? && Core::Content.revoked?
              "它走的是那条条件条目，而条件要求 #{Core::Content.conditional_requires}——现在的分布是 #{Core::Content.distribution}（#{Core::Content.revoke_rules.join('、')}，任一发生就要撤）"
            else
              '白名单是 ' + Array(Core::Content::LIC['allowed']).join('/') + '，条件条目只有一条'
            end
      bad << "#{label}：许可 #{lic.inspect} 拒装——#{why}"
    end

    # 校验和逐文件重算；签名用本地那把 key 重算（PACK-07）。
    cs = m['checksums'] || {}
    cs.each do |f, sum|
      p2 = File.join(out, f)
      bad << "#{label}：#{f} 找不到（checksums 里列了它）" and next unless File.exist?(p2)
      bad << "#{label}：#{f} 校验和对不上（被改过或导出中断）" unless Digest::SHA256.file(p2).hexdigest == sum.to_s
    end
    keyfile = File.join(root, m.dig('signature', 'keyFile').to_s)
    unless File.exist?(keyfile)
      bad << "#{label}：签名的 key 不在（#{m.dig('signature', 'keyFile')}）——这条路的签名只防误改，key 没了就验不了"
    else
      payload = JSON.generate(m.merge('signature' => nil))
      want = OpenSSL::HMAC.hexdigest('SHA256', File.read(keyfile).strip, payload)
      bad << "#{label}：签名对不上 manifest（有人动过 manifest 而不是动过数据文件）" unless want == m.dig('signature', 'value').to_s
    end

    # 大纲两表：悬空引用即红（PACK-05）；绑定年级里不许有高中段（D76）。
    topics = File.readlines(File.join(out, m.dig('outline', 'topics').to_s)).map { |l| (JSON.parse(l) unless l.strip.empty?) }.compact
    edges = File.readlines(File.join(out, m.dig('outline', 'edges').to_s)).map { |l| (JSON.parse(l) unless l.strip.empty?) }.compact
    ids = topics.map { |t| t['id'].to_s }
    dangling = edges.reject { |e| ids.include?(e['topicId'].to_s) && ids.include?(e['prerequisiteId'].to_s) }
    bad << "#{label}：#{dangling.size} 条边指向包里没有的知识点（PACK-05 悬空引用）" unless dangling.empty?
    off = topics.reject { |t| Core::Content.grade_ok?('child', t['grade'].to_i) }
    bad << "#{label}：#{off.size} 个知识点的年级不在绑定的年级里（高中段一题不绑，D76）" unless off.empty?

    questions = File.readlines(File.join(out, 'questions.jsonl')).count { |l| !l.strip.empty? }
    bad << "#{label}：题数 #{questions} 与 manifest.questionCount #{m['questionCount']} 不一致" unless questions == m['questionCount'].to_i
    unknown_q = File.readlines(File.join(out, 'questions.jsonl')).map do |l|
      q = JSON.parse(l)
      q['topicId'].to_s unless ids.include?(q['topicId'].to_s)
    end.compact
    bad << "#{label}：#{unknown_q.size} 道题挂在包外知识点上" unless unknown_q.empty?
    # 滤过一遍就得真的滤干净：给出的题里一道都不该再预设「手上有那一本教材」（D82）。
    tb = File.readlines(File.join(out, 'questions.jsonl')).count { |l| Core::Content.textbook_hit?(l) } if Core::Content.textbook_filter?
    bad << "#{label}：#{tb} 道题的题面或解析预设「手上有那一本教材」，导出时没滤干净（D82）" if Core::Content.textbook_filter? && tb.to_i.positive?

    # 署名：ATTRIBUTION.md 要非空、要说清来源与许可（PACK-03；1.0 的落点见 contentPack.attributionVisible）。
    attr = File.join(out, m.dig('attribution', 'file').to_s)
    body = File.exist?(attr) ? File.read(attr) : ''
    bad << "#{label}：ATTRIBUTION.md 空或没有来源 URL（PACK-03）" unless body.length > 80 && body.include?(m.dig('attribution', 'url').to_s)
    bad << "#{label}：ATTRIBUTION.md 没写许可 #{lic}" unless body.include?(lic)

    puts "  #{label}：知识点 #{topics.size} · 边 #{edges.size} · 题 #{questions} · 许可 #{lic} · audience #{Array(m['audience']).join('/')}"
  end
end

landed = Core::Content.attribution_landed
broken = Core::Content.attribution_broken
bad << "署名落点里有 #{broken} 处写着「已落」却在文件里找不到（contentPack.attributionVisible）" unless broken.zero?

abort "内容包的门没过：\n  #{bad.join("\n  ")}" unless bad.empty?
puts "内容包的门：通过（#{found.size} 个包 · 许可判定调 model/content.rb 那一处 · 署名已落 #{landed} 处、未落 #{Core::Content.attribution_pending} 处）"
