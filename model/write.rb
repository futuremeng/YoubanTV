# 写入口这一处规则（D42：一类规则只写一处）。
#
# 谁来改这一份约定，只有一个问法：这个写入落到哪一档、是不是本人、是不是面板。
# 面板只能修订不能改约定（present() 那一面、writeGuards.enforcementSurface）；
# 跨身份的写入根本不存在这条路（writeGuards.noCrossMemberWrite、PROFILE-10）；
# 长期令牌不带角色，越界只读（PROFILE-02）。
#
# 生效时间也只由这一处答：自己那一档能改的字段（约定 signers 里 signer=self 的那些）当场生效；
# 要双方签的字段进了 PLAN_CHANGE，等签了才生效（AUTO-04）。别在界面上猜是哪一种。
require 'json'

module Core
  # 一次写入的判定。契约里没有的那条路径就是不存在：404，不是「权限不够」。
  class Write
    CONTRACT = JSON.parse(File.read(File.expand_path('../contract/contract.json', __dir__))).freeze

    def self.endpoints
      @endpoints ||= CONTRACT.fetch('endpoints').each_with_object({}) do |e, h|
        h["#{e['method']} #{e['path']}"] = e
      end.freeze
    end

    # 要双方签的字段 / 自己当场生效的字段：只从 agreement.signers 那一张表读。
    def self.joint_fields
      @joint_fields ||= Array(CONTRACT.dig('agreement', 'signers', 'joint', 'fields')).freeze
    end

    def self.self_fields
      # 自管那几项的名字只有 selfManagedFields 那一处清单；signers.self 那边只说「谁来签」。
      @self_fields ||= Array(CONTRACT.dig('selfManagedFields', 'values')).freeze
    end

    # endpoint: 'PUT /api/myPlan'；profile: 写入口的 profile 参数（nil = 没带）；
    # actor: 谁在操作；via: 'panel' 表示从面板；scopes: 令牌带的范围；fields: 这一次要改的字段名。
    def self.call(endpoint:, profile: nil, actor: nil, via: nil, scopes: nil, fields: [], active: nil)
      ep = endpoints[endpoint.to_s]
      return deny(404, '这条路径在契约里没有', roles: false) if ep.nil?

      target = profile.nil? ? active : profile
      # 一条规则，两种说法同一个意思：这一档的约定由这一档的自己改；带 profile 参数时它只许是
      # 当前激活身份或 none（writeGuards.profileParameter + noCrossMemberWrite、PROFILE-10）。
      # 原来这里是两个分支，夹具里谁都能被对方兜住——同一类规则分两处写就是这个下场。
      if target != active && target != 'none'
        return deny(403, '跨身份的写入这条路不存在：这一档的约定由这一档的自己改', roles: false)
      end
      # 长期令牌只带读范围：越界就是只读，角色也不能从令牌推出来（PROFILE-02）。
      if Array(scopes).any? && Array(scopes).none? { |s| s.to_s == 'write' }
        return deny(403, '这一条令牌只带了读的范围', roles: false)
      end
      # 面板（present()）那一面只能查阅与修订，不能代设——连本人从面板这一档也不行
      # （writeGuards.enforcementSurface）。这一条只有它自己管得着：本人从面板写，下面两条都是过的。
      if via.to_s == 'panel'
        return deny(403, '面板那一面只能查阅与修订', roles: false)
      end
      # 这台设备同一时刻只有一个操作者（PROFILE-10）：不是这一档的自己在场，就不能直接改这一档的约定；
      # 要动它走「动议 + 对方本人受理」或「修订建议」那两条路。
      if !actor.nil? && actor != active
        return deny(403, '这台设备当前不是这一档的自己：改约定要走动议或修订', roles: false)
      end


      changed = Array(fields)
      joint = changed.select { |f| joint_fields.include?(f.to_s) }
      solo = changed.select { |f| self_fields.include?(f.to_s) }
      {
        'allowed' => true,
        'httpStatus' => 200,
        # 当场生效只有这一种：改的全是自己那一档能定的字段。掺了要双方签的字段，
        # 这一笔就是一份待签的修订，writable 是 false（AUTO-02、AUTO-04）。
        'writable' => joint.empty?,
        'rolesDerivableFromToken' => false,
        # 有要双方签的字段就得等签；全是自己那档的字段就当场生效（AUTO-07）。
        'effective' => joint.empty? ? 'now' : 'nextPlanVersion',
        'events' => changed.empty? ? [] : ['PLAN_CHANGE'],
        'fields' => { 'joint' => joint, 'self' => solo },
        'reason' => nil
      }
    end

    def self.deny(status, reason, roles:)
      { 'allowed' => false, 'httpStatus' => status, 'writable' => false,
        'rolesDerivableFromToken' => roles, 'effective' => nil, 'events' => [],
        'fields' => { 'joint' => [], 'self' => [] }, 'reason' => reason }
    end
  end
end
