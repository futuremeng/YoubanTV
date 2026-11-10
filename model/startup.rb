# SPEC: LAYER-14, ONBOARD-11, ONBOARD-12
# 这台电视上的启动形态只在这里答一次（LAYER-14、ONBOARD-11、ONBOARD-12、D81）：
# 被系统作为开机启动项拉起 → 加载完那一帧就交回前台 → 按指定拉起那一个应用。
# 本应用不自启（不声明 BOOT_COMPLETED、不起 service），那一处禁令由 tools/check-manifest.rb 守着。
require 'json'

module Core
  module Startup
    CONTRACT = JSON.parse(File.read(File.expand_path('../contract/contract.json', __dir__)))
    CONF = CONTRACT.fetch('startup')
    COLD = CONF.fetch('coldStart')
    BOOT = CONF.fetch('bootStart')
    OPEN = CONF.fetch('autoOpen')
    # 这一条是壳层与设备自检共用的那一句；失败不重试、不催，只写这一句。
    def self.fail_text(pkg)
      OPEN['failWords'].to_s.sub('{pkg}', pkg.to_s)
    end

    module_function

    def collapse?
      COLD['collapse'] == true
    end

    def full_screen_forbidden?
      COLD['fullScreenForbidden'] == true
    end

    # 例外只有那一处列出的两处；界面上不许自己再添第三处。
    def exceptions
      Array(COLD['exceptions'])
    end

    def self_start_forbidden?
      BOOT['selfStartForbidden'] == true
    end

    # 自启不许要权限：要了就是自启那条路又开了一次。
    def boot_permission_declared?
      BOOT['permission'] != nil
    end

    def auto_open_count
      OPEN['count'].to_i
    end

    # 缩起之后要不要拉起那一个应用：由这台设备存着的那一个包名决定；没有就不拉。
    def auto_open_target(setting)
      pkg = setting.to_s.strip
      pkg.empty? ? nil : pkg
    end

    # 拉起失败之后重试几次：只有这一处答；壳层读它，不许自己排一个退避表（ONBOARD-12）。
    def retries
      OPEN['retries'].to_i
    end

    # 壳层与设备自检读的那一个形状：两个内核同源，由 tools/align-core.rb 逐字段比（LAYER-13 同一个理由）。
    def startup_shape(pkg)
      target = auto_open_target(pkg)
      {
        'collapse' => collapse?,
        'fullScreenForbidden' => full_screen_forbidden?,
        'exceptions' => exceptions.size,
        'selfStartForbidden' => self_start_forbidden? && !boot_permission_declared?,
        'autoOpen' => target,
        'retries' => retries,
        'failLine' => target.nil? ? nil : fail_text(target)
      }
    end

    # 那批不许有的词只有一份清单，写在 agreement.panel.never（D45）：这一条路的产出读同一份。
    NEVER = CONTRACT.dig('agreement', 'panel', 'never').to_a.freeze

    def never_hits(setting)
      body = [auto_open_target(setting), fail_text(setting)].join('|')
      NEVER.count { |w| body.include?(w.to_s) }
    end
  end
end
