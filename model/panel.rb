# SPEC: PANEL-01, PANEL-02
# 面板那 12 页在 1.0 里只有这张表 + 设备端那一屏只读面板；浏览器那套界面推到 2.0（D80）。
# 于是「要改去 X 页」那句在 1.0 里说的是一条**还不存在的路**——这一处负责把它说明白，
# 而不是让屏上把人指到一条没有的路径上。可用性只有这一处答，两个内核都从这里取。
require 'json'

module Core
  module Panel
    CONTRACT = JSON.parse(File.read(File.expand_path('../contract/contract.json', __dir__)))
    CONF = CONTRACT.fetch('panel')
    AVAIL = CONF.fetch('availability', {})

    module_function

    # 面板可用与否只看契约那一处写的状态；别在这里另判一次。
    def available?
      AVAIL['state'].to_s == '可用'
    end

    def stage
      AVAIL['stage'].to_s
    end

    # 不可用时那句必须带上的那一句；有人把它抹空、或者把状态改成「可用」却不写依据，靠下面那条抓。
    def suffix
      AVAIL['suffix'].to_s
    end

    def where_text(where)
      return where.to_s if available?

      "#{where}#{suffix}"
    end

    # 断言用：只要状态不是「可用」，那一句就得非空——「还没做」不能只是心里知道。
    def marker_stated?
      available? || !suffix.strip.empty?
    end

    # 首启每一屏里凡是指出某一页的那一行，都得带上那一句（界面上一处不漏）。
    # 这条是**渲染之后**再看的：有人把那一行改回裸的 step['where']，这里就红。
    def marked_in_first_run?
      return true if available?

      list = Core::Agreement.screens(Core::Agreement.setup({}))
      (0...list.size).all? do |i|
        screen = Core::Agreement.setup_screen({}, i)
        w = screen['where']
        next true if w.nil? || w.to_s.strip.empty?

        screen['lines'].any? { |l| l.include?(w.to_s) && l.include?(suffix) }
      end
    end
  end
end
