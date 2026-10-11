# frozen_string_literal: true

# ============================================================================
# i18n 守卫测试（kimi-code T1.1 评审提案 P6 落地）
#
# 背景（T1.1 机制③实证结论）：
#   - 父类（NinjaSlayer / NinjaSlayer2）的 i18n 键是硬编码字符串，子类只能
#     「新增」NinjaSlayer*Ex.* 键空间的表，不能借父类命名空间续写/覆盖；
#   - 若本仓库 i18n/ 下出现 NinjaSlayer2.* / NinjaSlayer.* 键，加载顺序上
#     本仓库后注入会**静默遮蔽** gem 内上游表文本——笔误即事故，且无 toml
#     覆盖的表无任何回归保护。
#
# 本守卫三层断言：
#   1. 本仓库 i18n/ 顶层命名空间白名单（只允许 NinjaSlayerEx / NinjaSlayer2Ex）
#   2. 上游全部表（NinjaSlayer + NinjaSlayer2）运行时解析值 == gem 内 yml 原值
#      （全量逐字比对，非抽查——任何遮蔽/漂移当场红）
#   3. 本仓库 i18n yml 均可被 psych 正常解析（格式与上游 name/type/items 一致）
# ============================================================================

require "test/unit"
require "yaml"
require "bcdice"
require "bcdice/translate"
require_relative "../game_systems/NinjaSlayer2Ex"
require_relative "../game_systems/NinjaSlayerEx"

# 注入本仓库 i18n（与 runner 同一序列：reload! → 去重 concat）
I18n.backend.reload! if I18n.backend.respond_to?(:reload!)
new_i18n_yml = Dir[File.expand_path("../i18n/**/*.yml", __dir__)]
I18n.load_path.concat(new_i18n_yml - I18n.load_path)

class TestI18nGuard < Test::Unit::TestCase
  REPO_I18N = File.expand_path("../i18n", __dir__)
  GEM_I18N = File.join(Gem::Specification.find_by_name("bcdice").gem_dir, "i18n")

  # 扩展只准新增 Ex 键空间（T1.1 机制③结论）
  ALLOWED_TOP = %w[NinjaSlayerEx NinjaSlayer2Ex].freeze

  def test_repo_yml_parseable_and_structured
    Dir[File.join(REPO_I18N, "**/*.yml")].each do |f|
      doc = YAML.load_file(f, aliases: true)
      tables = doc.dig("ja_jp", doc["ja_jp"].keys.first, "table") || {}
      tables.each do |key, tbl|
        assert(tbl.key?("name") && tbl.key?("items"),
               "#{f} 表 #{key} 缺 name/items（须与上游 name/type/items 结构一致）")
      end
    end
  end

  def test_repo_yml_top_namespaces_whitelisted
    Dir[File.join(REPO_I18N, "**/*.yml")].each do |f|
      doc = YAML.load_file(f, aliases: true)
      tops = (doc["ja_jp"] || {}).keys
      assert_equal([], tops - ALLOWED_TOP,
                   "#{f} 出现白名单外顶层命名空间 #{(tops - ALLOWED_TOP).inspect}；" \
                   "只允许 #{ALLOWED_TOP.inspect}（禁借父类命名空间续写，防静默遮蔽上游）")
    end
  end

  def test_upstream_tables_not_shadowed
    # 只巡检 gem 内真实存在 i18n 目录的命名空间（1版 NinjaSlayer 表在 rb 代码内联，
    # 无 i18n yml——2026-10-11 实证 gem 仅 i18n/NinjaSlayer2/）
    %w[NinjaSlayer2 NinjaSlayer].each do |ns|
      gem_yml = File.join(GEM_I18N, ns, "ja_jp.yml")
      next unless File.exist?(gem_yml)

      doc = YAML.load_file(gem_yml, aliases: true)
      tables = doc.dig("ja_jp", ns, "table") || {}
      assert(!tables.empty?, "#{ns} gem yml 应有表（守卫自身健全性）")
      tables.each do |key, tbl|
        %w[name items].each do |attr|
          next unless tbl.key?(attr)

          assert_equal(tbl[attr], I18n.t("#{ns}.table.#{key}.#{attr}", locale: :ja_jp),
                       "#{ns}.table.#{key}.#{attr} 运行时解析值与 gem 原值不一致（被遮蔽或漂移）")
        end
      end
    end
  end

  # Ex 类展示常量守卫（kimi-code T1.1 评审 P5）
  #
  # 背景：bot 侧列举游戏系统走 bcdice-api 的 NAME / SORT_KEY（dicebots.rb、
  #   controller/v2.rb 都是 sort_by { |k| k::SORT_KEY } + map { NAME }）。
  #   Ex 类若裸继承父类常量，列表里会出现两个一模一样的条目、排序还退化，
  #   bot 的 /system 作用域选择会认不准。
  #
  # 三条断言：
  #   1. Ex 的 NAME 不等于其父类 NAME（不撞名）
  #   2. Ex 的 SORT_KEY 不等于其父类 SORT_KEY（排序键不撞）
  #   3. 在**全部**已注册游戏系统里，NAME 与 SORT_KEY 都全局唯一
  #      （只查本仓两个 Ex 不够——真实风险是全局撞名）
  EX_CLASSES = {
    "NinjaSlayer2Ex" => BCDice::GameSystem::NinjaSlayer2Ex,
    "NinjaSlayerEx" => BCDice::GameSystem::NinjaSlayerEx
  }.freeze

  def test_ex_classes_dont_inherit_parent_display_constants
    EX_CLASSES.each do |id, klass|
      parent = klass.superclass
      assert_not_equal(parent::NAME, klass::NAME,
                       "#{id}::NAME 裸继承了父类 NAME（#{parent::NAME.inspect}），" \
                       "bot 列系统时会与 #{parent} 撞名")
      assert_not_equal(parent::SORT_KEY, klass::SORT_KEY,
                       "#{id}::SORT_KEY 裸继承了父类 SORT_KEY（#{parent::SORT_KEY.inspect}）")
    end
  end

  def test_ex_display_constants_globally_unique
    systems = BCDice.all_game_systems

    %w[NAME SORT_KEY].each do |const|
      dup = systems.group_by { |g| g.const_get(const) }
                  .select { |_, v| v.size > 1 }
                  .map { |val, v| [val, v.map { |g| g.name.split("::").last }] }
      assert_equal([], dup, "#{const} 在已注册游戏系统中不唯一（#{dup.inspect}）")
    end
  end
end
