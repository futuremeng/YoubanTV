$stdout.sync = true
src = File.read('tools/run-fixtures.rb').sub(/^exit run\(\$ARGV\).*$/m, '')
eval(src, TOPLEVEL_BINDING, 'tools/run-fixtures.rb')
doc = YAML.load_file('fixtures/agree.yaml')
e = doc[ENV['ID']]
c = e['cases'][ENV['N'].to_i - 1]
g = e.key('given'); g = (e['given'].dup).merge(c.fetch('given', {})) if e['given']
w = World.new((e["given"] || {}).merge(c["given"] || {}))
s=w.commit_state
puts({nextAction:s["nextAction"],status:s["status"],panels:s["panels"]}.inspect)
d = w.derived
puts "otherProfileUnchanged=#{d['otherProfileUnchanged'].inspect} effective=#{w.effective.inspect} defaultsOnly=#{d['defaultsOnly'].inspect}"
