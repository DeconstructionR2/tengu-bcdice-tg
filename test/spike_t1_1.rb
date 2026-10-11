# frozen_string_literal: true

# ============================================================================
# T1.1 spike 实证脚本：四项机制一次性验证
#
# 跑法：bundle exec ruby test/spike_t1_1.rb
#   （或在仓库根）
#
# 各项通过/失败汇总输出；失败不 throw，便于报告。
# ============================================================================

$LOAD_PATH.unshift(File.expand_path("..", __dir__))

require "bcdice"
require "bcdice/game_system"
require "bcdice/translate"

# ---------------------------------------------------------------------------
# ① 外部插件类注册
#   加载本仓库的 NinjaSlayer2Ex.rb / NinjaSlayerEx.rb，断言：
#     - BCDice.game_system_class("NinjaSlayer2Ex") 返回我们写的类
#     - 父类 NinjaSlayer2 / NinjaSlayer 不受污染，仍可发现且 ID 一致
# ---------------------------------------------------------------------------
def check_plugin_registration
  require_relative "../game_systems/NinjaSlayer2Ex.rb"
  require_relative "../game_systems/NinjaSlayerEx.rb"

  results = []

  ex2_class = BCDice.game_system_class("NinjaSlayer2Ex")
  results << ["① BCDice.game_system_class('NinjaSlayer2Ex') 命中",
              ex2_class == BCDice::GameSystem::NinjaSlayer2Ex,
              "got=#{ex2_class.inspect}"]

  ex1_class = BCDice.game_system_class("NinjaSlayerEx")
  results << ["① BCDice.game_system_class('NinjaSlayerEx') 命中",
              ex1_class == BCDice::GameSystem::NinjaSlayerEx,
              "got=#{ex1_class.inspect}"]

  orig2_class = BCDice.game_system_class("NinjaSlayer2")
  results << ["① 父类 NinjaSlayer2 ID 仍为 NinjaSlayer2",
              orig2_class == BCDice::GameSystem::NinjaSlayer2 &&
                BCDice::GameSystem::NinjaSlayer2::ID == "NinjaSlayer2",
              "got=#{orig2_class.inspect}/ID=#{BCDice::GameSystem::NinjaSlayer2::ID}"]

  orig1_class = BCDice.game_system_class("NinjaSlayer")
  results << ["① 父类 NinjaSlayer ID 仍为 NinjaSlayer",
              orig1_class == BCDice::GameSystem::NinjaSlayer &&
                BCDice::GameSystem::NinjaSlayer::ID == "NinjaSlayer",
              "got=#{orig1_class.inspect}/ID=#{BCDice::GameSystem::NinjaSlayer::ID}"]

  results << ["① NinjaSlayer2Ex < NinjaSlayer2（子类关系）",
              BCDice::GameSystem::NinjaSlayer2Ex < BCDice::GameSystem::NinjaSlayer2,
              "ancestors include? #{BCDice::GameSystem::NinjaSlayer2Ex.ancestors.include?(BCDice::GameSystem::NinjaSlayer2)}"]

  results << ["① prefixes_pattern 含父类所有 prefix（UH/[KENHU]/SB/WS/WSE/NRS）",
              BCDice::GameSystem::NinjaSlayer2 == BCDice::GameSystem::NinjaSlayer2Ex.superclass &&
                (BCDice::GameSystem::NinjaSlayer2Ex.prefixes ==
                 BCDice::GameSystem::NinjaSlayer2.prefixes),
              "ex.prefixes=#{BCDice::GameSystem::NinjaSlayer2Ex.prefixes.inspect} " \
              "vs ns2.prefixes=#{BCDice::GameSystem::NinjaSlayer2.prefixes.inspect}"]

  results
end

# ---------------------------------------------------------------------------
# ② 外部 i18n 加载：把本仓库 i18n/ 目录注入 I18n.load_path
#   关键顺序：必须在 I18n.backend 第一次 init_translations 之前注入，
#   否则 backend 标记 @initialized=true，新加的 yml 不会被读。
#   BCDice base.rb 末尾会在 require "bcdice" 时把 gem 内 yml 加进 load_path，
#   但 init_translations 直到首次 translate 才触发——所以我们赶在那之前注入。
#   验证：
#     - NinjaSlayer2Ex.table.SPIKE_DUMMY 可 translate
#     - 父类 NinjaSlayer2.table.SATSUBATSU.items 仍然可 translate（**没被遮挡**）
#     - 两套键空间互不污染
# ---------------------------------------------------------------------------
def check_i18n_load_path
  # 必须抢在首次 translate 之前；按理 require "bcdice" 后还没人 translate。
  # 强制 reload! 确保 i18n backend 接受新 yml。
  I18n.backend.reload! if I18n.backend.respond_to?(:reload!)
  I18n.load_path.concat(Dir[File.expand_path("../i18n/**/*.yml", __dir__)])

  results = []

  # 复用一个 BCDice instance 即可（Translate mixin 提供 translate 方法）。
  # 这里直接验证 I18n.t 可命中（不必先建 game system 实例）。
  results << ["② I18n.t('NinjaSlayer2Ex.table.SPIKE_DUMMY.name') 命中",
              I18n.t("NinjaSlayer2Ex.table.SPIKE_DUMMY.name") == "T1.1 spike dummy 表(D6) ＞ ",
              "got=#{I18n.t('NinjaSlayer2Ex.table.SPIKE_DUMMY.name').inspect}"]

  results << ["② I18n.t('NinjaSlayer2Ex.table.SPIKE_DUMMY.items')[0] 命中第 1 项",
              I18n.t("NinjaSlayer2Ex.table.SPIKE_DUMMY.items")[0] == "SPIKE_DUMMY 1",
              "got=#{I18n.t('NinjaSlayer2Ex.table.SPIKE_DUMMY.items').first.inspect}"]

  # 上游父类键应**仍然**可命中（关键是注入操作不能破坏上游）
  results << ["② I18n.t('NinjaSlayer2.table.SATSUBATSU.name') 仍命中上游",
              I18n.t("NinjaSlayer2.table.SATSUBATSU.name") ==
                "サツバツ!!(D6) ＞ ",
              "got=#{I18n.t('NinjaSlayer2.table.SATSUBATSU.name').inspect}"]

  # 键空间隔离：从 NinjaSlayer2 找 SPIKE_DUMMY 必须不存在（用 raise:true 显式断言）
  isolation_ok =
    begin
      I18n.t("NinjaSlayer2.table.SPIKE_DUMMY.name", raise: true)
      false
    rescue I18n::MissingTranslationData
      true
    end
  results << ["② 键空间隔离：NinjaSlayer2.table.SPIKE_DUMMY.name 不存在",
              isolation_ok,
              "raise I18n::MissingTranslationData as expected（NinjaSlayer2 不继承到 SPIKE_DUMMY）"]

  # 反向：从 NinjaSlayerEx 找 SPIKE_DUMMY 也应 raise（1版扩展未声明 dummy）
  forward_iso_ok =
    begin
      I18n.t("NinjaSlayerEx.table.SPIKE_DUMMY.name", raise: true)
      true
    rescue I18n::MissingTranslationData
      false
    end
  results << ["② 键空间隔离反向：NinjaSlayerEx.table.SPIKE_DUMMY.name 应 raise",
              !forward_iso_ok,
              "raise I18n::MissingTranslationData as expected（1版扩展未声明 dummy 表）"]

  # 切片强制为 Array，方便后续断言
  extras = I18n.t("NinjaSlayer2Ex.table.SPIKE_DUMMY.items", raise: true)
  array_ok = extras.is_a?(Array) && extras.first == "SPIKE_DUMMY 1"
  results << ["② I18n.t('NinjaSlayer2Ex.table.SPIKE_DUMMY.items') 是数组且首项= SPIKE_DUMMY 1",
              array_ok,
              "class=#{extras.class}, first=#{extras.first.inspect}"]

  results
end

# ---------------------------------------------------------------------------
# ③ 继承键空间行为
#   拿子类 NinjaSlayer2Ex 的实例，调用父类命令（SB / WSE / NRS_E4），
#   验证输出文本来自 gem 内 yml（NinjaSlayer2.*），未跑向 NinjaSlayer2Ex.*。
# ---------------------------------------------------------------------------
class FixedSidesRandomizer < BCDice::Randomizer
  # 总是返回 3（够调用 SATSUBATSU/SATSUBATSU 表）
  def initialize(value = 3)
    super()
    @next = value
  end

  def random(sides)
    if sides != 6
      raise "unexpected sides #{sides}"
    end
    @next
  end
end

def check_inherited_keyspace
  klass = BCDice.game_system_class("NinjaSlayer2Ex")
  results = []

  # SB（SATSUBATSU 表）的固定骰序：randomizer 总是返回 3 → 命中第 3 项
  inst = klass.new("SB")
  inst.randomizer = FixedSidesRandomizer.new(3)
  res = inst.eval
  results << ["③ 子类 SB 输出命中父表 SATSUBATSU 第 3 项（V3 硬编码键旁证）",
              !res.nil? && res.text.start_with?("サツバツ!!(D6) ＞ ") &&
                res.text.include?("「苦しみ抜いて死ぬがいい！」"),
              "text=#{res&.text.to_s[0, 80].inspect}"]

  # SB@6（指定 type=6）——父类硬编码分支，无骰序
  inst = klass.new("SB@6")
  res = inst.eval
  results << ["③ 子类 SB@6 输出命中父表 SATSUBATSU 第 6 项",
              !res.nil? && res.text.include?("ゴウランガ"),
              "text=#{res&.text.to_s[0, 80].inspect}"]

  # WSE（随机骰 1 颗 + 父表 WASSHOI 命中）
  inst = klass.new("WSE")
  inst.randomizer = FixedSidesRandomizer.new(4)
  res = inst.eval
  results << ["③ 子类 WSE 输出命中父表 WASSHOI",
              !res.nil? && res.text.include?("ニンジャスレイヤー=サンのエントリー!!"),
              "text=#{res&.text.to_s[0, 80].inspect}"]

  results << ["③ 子类 instance.class 链确认经子类",
              inst.instance_of?(klass),
              "is instance_of? #{inst.instance_of?(klass)}"]

  results
end

# ---------------------------------------------------------------------------
# Runner
# ---------------------------------------------------------------------------
def render(rows, header)
  puts "=" * 78
  puts header
  puts "=" * 78
  all_passed = true
  rows.each do |label, passed, evidence|
    mark = passed ? "PASS" : "FAIL"
    all_passed &&= passed
    printf("[%s] %s\n", mark, label)
    printf("         evidence: %s\n", evidence)
  end
  puts
  all_passed ? "✅ #{header} 全部通过" : "❌ #{header} 有失败"
  puts
  all_passed
end

overall = true

overall &&= render(check_plugin_registration, "① 外部插件类注册")
overall &&= render(check_i18n_load_path,        "② 外部 i18n 加载")
overall &&= render(check_inherited_keyspace,   "③ 继承键空间行为")

exit(overall ? 0 : 1)
