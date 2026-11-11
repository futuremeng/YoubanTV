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
require 'pack'

CONF = Core::Content::CONF
DIR = File.join(root, CONF.fetch('dir').to_s)
REQUIRED = %w[packId version license attribution source checksums signature audience
              presentationHints outline questionCount].freeze
bad = []
found = Core::Pack.installed

if found.empty?
  abort "内容包的门扫不到东西：#{Core::Pack::DIR.sub("#{root}/", '')} 里没有任何 .qpack——本地未导出就跑 ruby tools/make-pack.rb（PACK-09：空目录不算绿）"
end

# 验包这件事的每一条判定在 model/pack.rb 那一处：门只负责把它报出来——
# 判定写两遍会出「门绿着而模型取到没验过的题」那种错（D84）。
found.each do |qpack|
  bad.concat(Core::Pack.verify(qpack))
  c = Core::Pack.counts[File.basename(qpack)] || {}
  puts "  #{File.basename(qpack)}：知识点 #{c['topics']} · 边 #{c['edges']} · 题 #{c['questions']} · 许可 #{c['license']} · audience #{Array(Core::Content.binding_grades).join('/')}"
end

landed = Core::Content.attribution_landed
broken = Core::Content.attribution_broken
bad << "署名落点里有 #{broken} 处写着「已落」却在文件里找不到（contentPack.attributionVisible）" unless broken.zero?

abort "内容包的门没过：\n  #{bad.join("\n  ")}" unless bad.empty?
puts "内容包的门：通过（#{found.size} 个包 · 许可与验包调 model/pack.rb 与 model/content.rb 那两处 · 署名已落 #{landed} 处、未落 #{Core::Content.attribution_pending} 处）"
