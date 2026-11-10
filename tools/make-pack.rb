#!/usr/bin/env ruby
# SPEC: PACK-01, PACK-09
# 把编写源仓（本机 ../cn-math-taxonomy）导成一个内容包：manifest + 题目 + 大纲两表 + ATTRIBUTION + 校验和 + 本地签。
#
# 三条要记在前面的规矩：
#   一、按契约 contentPack.audienceBinding 的年级过滤——高中段一题不绑（D76），裁掉的边报出条数；
#   二、包本体不入库（trackedInRepo = false）：它是本地一次导出的产物，编写源在别人的仓（PACK-08）；
#   三、签名是本地随机 key 的 HMAC——只防误改与半途中断，不作信任锚（integrity.signature 那一处写明了）。
#
# 用法：ruby tools/make-pack.rb [--from=../cn-math-taxonomy]
require 'json'
require 'set'
require 'digest'
require 'openssl'
require 'fileutils'
require 'time'

root = File.expand_path('..', __dir__)
$LOAD_PATH.unshift File.join(root, 'model')
require 'content'

CONF = Core::Content::CONF
SRC_ARG = ARGV.find { |a| a.start_with?('--from=') }&.split('=', 2)&.at(1) || '../cn-math-taxonomy'
SRC = File.expand_path(SRC_ARG, root)
DIR = File.join(root, CONF.fetch('dir').to_s)
PACK_ID = Core::Content.pack_id
STAGE = File.join(DIR, "#{PACK_ID}.build")
QPACK = File.join(DIR, "#{PACK_ID}.qpack")
KEY = File.join(DIR, CONF.dig('integrity', 'keyFile').to_s.split('/').last)
ABORT_UNBOUND = ->(msg) { abort "导出中止：#{msg}" }

abort "找不到编写源：#{SRC}（用 --from=… 指过去）" unless Dir.exist?(File.join(SRC, 'data'))

topics = JSON.parse(File.read(File.join(SRC, 'data/topics.json')))
topics = topics.values if topics.is_a?(Hash)
edges = JSON.parse(File.read(File.join(SRC, 'data/dependencies.json')))
questions = JSON.parse(File.read(File.join(SRC, 'data/questions.json')))
ABORT_UNBOUND.call('topics.json 不是数组也不是哈希') unless topics.is_a?(Array) && edges.is_a?(Array) && questions.is_a?(Array)

# 一、按年级留点。小学 g1–g6 与初中 g7–g9 进包；高中段 g10–g16 一题不绑（D76）。
keep_grades = Core::Content.binding_grades
ABORT_UNBOUND.call('契约里 audienceBinding 的年级是空的——绑定没定就别导出') if keep_grades.empty?
kept_topics = topics.select { |t| keep_grades.include?(t['grade'].to_i) }
kept_ids = kept_topics.map { |t| t['id'].to_s }.to_set
dropped_nodes = topics.size - kept_topics.size
# 二、边只留两端都在包里的：另一端是高中点时，那条边指向不存在的东西（PACK-05 的悬空引用就是这么来的）。
kept_edges = edges.select { |e| kept_ids.include?(e['topicId'].to_s) && kept_ids.include?(e['prerequisiteId'].to_s) }
dropped_edges = edges.size - kept_edges.size
# 三、题跟着点走；再滤掉预设「手上有那一本教材」的那类（D82：这台设备不知道孩子用的是哪一版课本）。
in_scope = questions.select { |q| kept_ids.include?(q['topicId'].to_s) }
# 看的是整道题——选项里那句「不必看课文」同样是预设（第一版只看题面与解析，门当场抓到 32 道漏网）。
dropped_textbook = in_scope.select { |q| Core::Content.textbook_filter? && Core::Content.textbook_hit?(JSON.generate(q)) }
kept_questions = in_scope - dropped_textbook

FileUtils.rm_rf(STAGE)
FileUtils.mkdir_p(STAGE)
File.write(File.join(STAGE, 'outline_topics.jsonl'),
           kept_topics.map { |t| JSON.generate(t) }.join("\n") + "\n")
File.write(File.join(STAGE, 'outline_edges.jsonl'),
           kept_edges.map { |e| JSON.generate(e) }.join("\n") + "\n")
File.write(File.join(STAGE, 'questions.jsonl'),
           kept_questions.map { |q| JSON.generate(q) }.join("\n") + "\n")

attrib = [
  "# 署名与来源 · #{PACK_ID}",
  '',
  "本包由 #{Core::Content::SOURCE['project']} 导出：#{Core::Content::SOURCE['url']}",
  "许可：**#{Core::Content.pack_license}**（原文见该仓 LICENSE；其中「商业使用需单独授权」的声明一并保留）。",
  Core::Content::SOURCE['attribution'].to_s,
  '',
  "取的是义务教育段（#{keep_grades.min}–#{keep_grades.max} 年级）：知识点 #{kept_topics.size} 个、先修边 #{kept_edges.size} 条、题 #{kept_questions.size} 道。",
  "裁掉的：知识点 #{dropped_nodes} 个（高中段与非义教段）、先修边 #{dropped_edges} 条（指向未装知识点的边不留，`PACK-05`）。",
  '',
  '本项目的绑定与许可判定只在一处：`contract.contentPack`（`spec/PACK.md#PACK-02、#PACK-09`）。',
  '本项目私域自用、不分发、不收费（D29、D30）；那三条撤销条件任一发生，这个包按 PACK-04 卸干净。',
  ''
].join("\n")
File.write(File.join(STAGE, 'ATTRIBUTION.md'), attrib)

checksums = Dir.children(STAGE).sort.reject { |f| f == 'checksums.json' }.to_h do |f|
  [f, Digest::SHA256.file(File.join(STAGE, f)).hexdigest]
end
File.write(File.join(STAGE, 'checksums.json'), JSON.pretty_generate(checksums))

FileUtils.mkdir_p(DIR)
File.write(KEY, OpenSSL::Random.random_bytes(32).unpack1('H*')) unless File.exist?(KEY)
manifest = {
  'packId' => PACK_ID,
  'version' => Time.now.utc.strftime('%Y%m%d.%H%M%S'),
  'license' => Core::Content.pack_license,
  'attribution' => { 'text' => "#{Core::Content::SOURCE['project']}（#{Core::Content::SOURCE['url']}）· CC BY-NC 4.0 · 保留其商业授权声明",
                     'url' => Core::Content::SOURCE['url'], 'file' => 'ATTRIBUTION.md' },
  'source' => { 'project' => Core::Content::SOURCE['project'], 'acquired' => '由本地导出脚本按年级过滤（tools/make-pack.rb）',
                'authoringRepo' => File.basename(SRC) },
  'checksums' => checksums,
  'signature' => nil,
  'audience' => CONF.fetch('audienceBinding').map { |b| b['audience'] },
  'presentationHints' => { 'byDueKind' => { 'quiz' => 'focused' } }, # 内容类型决定默认 mode（COMMITMENTS.md §4）
  'outline' => { 'topics' => 'outline_topics.jsonl', 'edges' => 'outline_edges.jsonl' },
  'questionCount' => kept_questions.size,
  'gradesIncluded' => kept_topics.map { |t| t['grade'].to_i }.uniq.sort,
  'exportNote' => "知识点 #{kept_topics.size}／先修边 #{kept_edges.size}／题 #{kept_questions.size}；裁掉点 #{dropped_nodes}、边 #{dropped_edges}"
}
payload = JSON.generate(manifest.merge('signature' => nil))
manifest['signature'] = { 'alg' => 'HMAC-SHA256', 'keyFile' => "packs/#{File.basename(KEY)}",
                          'value' => OpenSSL::HMAC.hexdigest('SHA256', File.read(KEY).strip, payload) }
File.write(File.join(STAGE, 'manifest.json'), JSON.pretty_generate(manifest))

FileUtils.rm_f(QPACK)
ok = system('zip', '-q', '-r', QPACK, '.', chdir: STAGE)
abort '打包失败：zip 没跑成' unless ok
FileUtils.rm_rf(STAGE)

puts "导出 #{QPACK}"
puts "  知识点 #{kept_topics.size}（裁 #{dropped_nodes}）· 先修边 #{kept_edges.size}（裁 #{dropped_edges}）· 题 #{kept_questions.size}（滤掉预设课本的 #{dropped_textbook.size}）"
puts "  年纪 #{manifest['gradesIncluded'].inspect} · 许可 #{manifest['license']}（#{Core::Content.distribution} 那一条下#{Core::Content.license_ok?(manifest['license']) ? '可装' : '拒装'}）"
puts '  下一步：ruby tools/check-packs.rb'
