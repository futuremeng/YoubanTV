# SPEC: PET-01, PET-02, PET-03, PET-04, PET-05, PET-06, PET-07, PET-08
# 角上那只小宠物的规矩只在这里答一次（D83）。这里没有清单第二份：
# 不许有的那批词读 forbiddenFields.values 那一处（pet.neverFrom），默认那一只由 agreement.defaults 那张表递进来。
require 'json'

module Core
  module Pet
    CONTRACT = JSON.parse(File.read(File.expand_path('../contract/contract.json', __dir__)))
    CONF = CONTRACT.fetch('pet')
    # 一份清单在这一处答：不分档、不按人分派哪一只（PET-04）。
    PICKABLE = Array(CONF['pickable']).freeze
    NEVER_STATE = Array(CONF['neverState']).freeze
    NO_PROGRESS = Array(CONF['noProgressFields']).freeze
    APPEAR_NEVER = CONF.dig('appearance', 'never').to_a.freeze
    PERSONALITY_NEVER = CONF.dig('personalitySource', 'never').to_a.freeze
    # 不许有的那批词只有一份清单，写在 forbiddenFields.values（D45）：这一节读同一份，不抄第二份。
    NEVER_SOURCE = CONF.dig('neverFrom', 'fields').to_s
    FORBIDDEN = NEVER_SOURCE.split('.').reduce(CONTRACT) { |n, k| n.is_a?(Hash) ? n[k] : nil }.to_a.freeze

    # 扫描面是**界面上真会出现的那些串**，不是谁临时编的一句：契约里的措辞、面板那 12 页的答句、
    # 首启那六步的每一句、拉起失败那一句……「把清单清空就绿」这种假绿就此堵住（清单条数另有断言）。
    SURFACE_SKIP = %w[x-note spec why note never neverState noProgressFields neverFrom style forbiddenFields].freeze

    module_function

    def surface_strings(node = CONTRACT, out = [])
      case node
      when Hash then node.each { |k, v| next if SURFACE_SKIP.include?(k.to_s); surface_strings(v, out) }
      when Array then node.each { |v| surface_strings(v, out) }
      when String then out << node
      end
      out
    end

    def hits(list, node)
      strings = node.is_a?(String) ? [node] : surface_strings(node)
      strings.flat_map { |s| Array(list).select { |w| s.to_s.include?(w.to_s) } }.size
    end

    # 那条分界：它的关键在那一条布尔上——没有一条路让「孩子没做什么」变成「宠物少了什么」。
    def state_never_from_usage?
      CONF['stateNeverDerivedFromUsage'] == true
    end

    def state_carries
      Array(CONF['stateCarries'])
    end

    # 那批不许的状态词在界面上出现几次——这里就是那堵墙的读数。
    def never_state_hits(node = surface_strings)
      hits(NEVER_STATE, node)
    end

    # 呈现那批不许有的东西：入场动画、声音、自己成为一条提示……扫的是这一节自己那批取值。
    def never_appearance_hits(node = CONF.fetch('appearance'))
      hits(APPEAR_NEVER, node)
    end

    # 性格那一路不许有的东西：扫界面那一片（面板那 12 页的页名与答句），不是那份不许有的清单本身。
    def personality_never_hits(node = CONTRACT.fetch('panel'))
      hits(PERSONALITY_NEVER, node)
    end

    def forbidden_single_source?
      NEVER_SOURCE == 'forbiddenFields.values' && FORBIDDEN.is_a?(Array) && !FORBIDDEN.empty?
    end

    def forbidden_in(node = surface_strings)
      hits(FORBIDDEN, node)
    end

    # 换一只的代价：契约里写的是「零」；这里把它读成一个可断言的数（要扣的东西有几样）。
    def switch_cost_items
      CONF.dig('choiceIsAutonomy', 'switchCost').to_s =~ /\A零/ ? 0 : -1
    end

    def autonomy?
      %w[canPick canRename canSwitch notProgress].all? { |k| CONF.dig('choiceIsAutonomy', k) == true }
    end

    # 清单里没有的那一只不存在；选过的那一只永远还能选回来。
    def pickable?(name)
      PICKABLE.include?(name.to_s)
    end

    # 默认那一只由 agreement.defaults 那张表递进来——这一处不分岔、不自己推（PET-04）。
    # 表那一侧才是默认值挑选那个位点；这里只验「表里给的这一只确实在清单里」。
    def default_pick(plan_default)
      name = plan_default.to_s
      pickable?(name) ? name : PICKABLE.first
    end

    def layer
      CONF.dig('appearance', 'layer').to_s
    end

    def frame_interval_ms
      CONF.dig('appearance', 'frameIntervalMs').to_i
    end

    def draws_only_when_moving?
      CONF.dig('appearance', 'drawOnlyWhenMoving') == true
    end

    def measured_devices
      Array(CONF.dig('appearance', 'measuredOn'))
    end

    def gate_requires_measured?
      CONF.dig('appearance', 'measuredBeforeOn') == true
    end

    # 开这一层的唯一条件：这台设备在那份实测名单里。名单现在是空的，所以谁都开不了（PET-07）。
    def enabled_on(device)
      return false unless gate_requires_measured?

      measured_devices.include?(device.to_s)
    end

    def default_on?
      CONF.dig('appearance', 'default').to_s == 'on'
    end
  end
end
