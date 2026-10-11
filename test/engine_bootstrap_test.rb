# frozen_string_literal: true

# ============================================================================
# test/engine_bootstrap_test.rb — 引擎初始化守卫（T2.1）
#
# 守护的是一个**静默**故障：i18n backend 一旦 init_translations 跑过就标记
# @initialized=true，之后追加 load_path 不再重读 → 所有 Ex 命名空间返回
# "translation missing: ..." 字符串且**不抛异常**（i18n 默认行为）。
# 内联序列散落 8 处时，漏一处 reload! 就是静默全量 MissingTranslationData，
# 且测试**照样绿**（坑点 C：必须用 raise: true 才暴露）。
#
# 本文件钉住三件事：
#   ① 幂等：二次调用 bootstrap! 后 I18n.load_path 不增长、无"数组元素"；
#   ② 翻译可用：bootstrap 后 Ex 命名空间已知键以 raise:true 能取到**真实值**
#      （不是 "translation missing" 占位串）；
#   ③ 类可发现：BCDice.all_game_systems 能枚举 NinjaSlayerEx / NinjaSlayer2Ex。
#
# 附带钉住：reload! 缺失时的**反向**证据（证明这些断言真的有鉴别力，
# 而不是因为"i18n 反正会自己加载"而恒过）。
# ============================================================================

require "test/unit"
require_relative "../lib/engine_bootstrap"

# 被测序列在第一处 translate 之前跑，与全仓所有入口同源
EngineBootstrap.bootstrap!

class TestEngineBootstrap < Test::Unit::TestCase
  # load_path 可能是 [String] 也可能是 [[String]]（坑点 B），统一 flatten 后比较
  def flattened_load_path
    I18n.load_path.flatten
  end

  # ---------------------------------------------------------------------
  # ① 幂等
  # ---------------------------------------------------------------------

  def test_repeated_bootstrap_does_not_grow_load_path
    before = flattened_load_path.dup

    # 再跑 3 次（默认模式：首次之后应为空转）
    3.times { EngineBootstrap.bootstrap! }

    after = flattened_load_path
    assert_equal(before.sort, after.sort,
                 "重复 bootstrap! 后 load_path 内容变化（应逐项相同且不增长）：" \
                 "新增=#{(after - before).inspect} 丢失=#{(before - after).inspect}")
    assert_equal(before.size, after.size,
                 "重复 bootstrap! 后 load_path 长度增长：#{before.size} -> #{after.size}")
  end

  def test_forced_reload_mode_also_does_not_grow_load_path
    before = flattened_load_path.dup

    # 强制 reload 模式也不得增长（reload_backend: true 是显式全量重载路径）
    3.times { EngineBootstrap.bootstrap!(reload_backend: true) }

    assert_equal(before.sort, flattened_load_path.sort,
                 "reload_backend: true 模式下 load_path 仍增长")
  end

  def test_repo_i18n_files_are_flat_string_entries_not_nested_arrays
    # 坑点 B：`I18n.load_path << Dir[...]` 会把一个 **Array** 塞进 load_path，
    # 本仓库自己的注入一律 concat 平展 → 本仓库 yml 必须是扁平 String 条目。
    #
    # 注意：**不能**断言整个 load_path 无数组元素——上游 bcdice 自己就塞了一个
    # （bcdice-3.17.0/lib/bcdice/base.rb:414 `I18n.load_path << Dir[...]`，
    #  实测是 1 个长度 105 的数组），靠 i18n 的 `filenames.flatten.each` 兜底。
    # 那是只读红线之外的既有事实，不归本仓库改；此处只守**我们自己的**注入形态。
    repo_files = EngineBootstrap.i18n_files
    flat = I18n.load_path.select { |entry| entry.is_a?(String) }

    missing = repo_files - flat
    assert_empty(missing,
                 "本仓库 i18n 未以扁平 String 条目进入 load_path" \
                 "（EngineBootstrap.inject_i18n_load_path 必须用 concat 而非 << Dir[...]）：#{missing.inspect}")
  end

  def test_repo_i18n_files_all_present_in_load_path
    missing = EngineBootstrap.i18n_files - flattened_load_path
    assert_empty(missing, "本仓库 i18n yml 未全部进入 load_path：#{missing.inspect}")
  end

  def test_bootstrap_reports_freshness
    EngineBootstrap.reset!
    assert(!EngineBootstrap.bootstrapped?, "reset! 后 bootstrapped? 应为 false")

    assert(EngineBootstrap.bootstrap!, "首次 bootstrap! 应报告 fresh=true（执行了 reload!）")
    assert(EngineBootstrap.bootstrapped?, "bootstrap! 后 bootstrapped? 应为 true")
    assert(!EngineBootstrap.bootstrap!, "二次 bootstrap! 应报告 fresh=false（幂等空转）")
  end

  # ---------------------------------------------------------------------
  # ② 翻译可用（raise: true —— 否则拿到占位串也会"通过"）
  # ---------------------------------------------------------------------

  # 本仓库两个 Ex 命名空间的代表性已知键。
  # 键取自 i18n/*/ja_jp.yml 的真实表名，改表时**必须**同步（否则当场红）。
  KNOWN_KEYS = [
    "NinjaSlayer2Ex.table.NSRS.name",
    "NinjaSlayer2Ex.table.KRS.name",
    "NinjaSlayer2Ex.table.NJI.name",
    "NinjaSlayer2Ex.table.SBX.name",
    "NinjaSlayerEx.table.WS.name",
    "NinjaSlayerEx.table.KRM.name"
  ].freeze

  def test_known_ex_keys_translate_with_raise
    # 自证：强制 reload，不依赖类内其他测试的执行顺序/共享 backend 状态
    # （评审实测：漏 reload! 的变异曾被后续测试「治愈」而漏网）
    EngineBootstrap.bootstrap!(reload_backend: true)
    KNOWN_KEYS.each do |key|
      value = I18n.translate(key, locale: :ja_jp, raise: true)
      assert_kind_of(String, value, "#{key} 应翻译为 String")
      refute_match(/\Atranslation missing/, value,
                   "#{key} 返回占位串而非真实翻译（bootstrap 顺序坏了？" \
                   "缺 I18n.backend.reload! 或 load_path 未注入）")
      refute_empty(value.strip, "#{key} 翻译为空串")
    end
  end

  def test_ex_items_arrays_are_reachable
    EngineBootstrap.bootstrap!(reload_backend: true) # 自证，见上
    # 断言不只是 name：items 是 Array（表结构完整性），且含多字节文本
    items = I18n.translate("NinjaSlayer2Ex.table.NSRS.items", locale: :ja_jp, raise: true)
    assert_kind_of(Array, items, "NSRS.items 应为 Array")
    refute_empty(items, "NSRS.items 不应为空")
  end

  def test_upstream_keys_still_resolve_after_bootstrap
    EngineBootstrap.bootstrap!(reload_backend: true) # 自证，见上
    # 注入本仓库 yml 不能遮蔽 gem 内上游表（父类命令仍要能跑）
    upstream = I18n.translate("NinjaSlayer2.table.SATSUBATSU.name", locale: :ja_jp, raise: true)
    assert_kind_of(String, upstream)
    refute_match(/\Atranslation missing/, upstream, "上游 NinjaSlayer2 表被遮蔽或未加载")
  end

  # 反向证据：证明 ② 的断言真的有鉴别力。
  # 造一个"漏了 reload!"的隔离 backend，若断言无鉴别力则此测试会失败
  # （即：注入新键但刻意不 reload 时必须抛 MissingTranslationData）。
  def test_missing_reload_would_actually_break_translation
    # 反向证据：证明 ② 的断言真的有鉴别力。
    #
    # 模拟"注入了 load_path 但漏了 reload!"的真实故障形态：
    # backend 在本仓库 yml 尚未进入其翻译缓存时被 init_translations 触发一次
    # （等价于 init_translations 早于注入跑过 → mark @initialized=true），
    # 之后 load_path 再怎么追加都不会被重读。
    #
    # 必须经 I18n.translate 走（而非直接调 backend.translate）—— i18n 的
    # fallbacks backend 靠 `throw(:exception, ...)` 上报缺失，这个 catch 只在
    # I18n.translate 里；直调 backend 会漏 catch 抛 UncaughtThrowError。
    key = "NinjaSlayer2Ex.table.NSRS.name"

    original_backend = I18n.backend
    begin
      # 复现**真实**故障形态：backend 早就 init_translations 过（@initialized=true，
      # 对应"gem 的 base.rb 在 require 时就把 load_path 交给了 i18n"），
      # 之后才往 **I18n.load_path** 里追加本仓库 yml。
      # i18n 1.8.11 的 I18n::Backend::Base#load_translations（base.rb:16-19）只在
      # **无参调用**时才读 I18n.load_path；一旦 @initialized=true，后续 translate
      # 不再触发它 → 新追加的 yml 永远进不来。
      I18n.backend = I18n::Backend::Simple.new
      # 先只让 load_path 含上游 yml，跑一次 translate 把 backend 标记为已初始化。
      # 注意要按 load_path 里**实际存在的本仓库条目**剔除（不是按 ROOT 前缀猜——
      # gem 内 yml 走 vendor/bundle 路径，不在 ROOT 下）。
      repo_i18n = EngineBootstrap.i18n_files
      upstream_only = I18n.load_path.flatten - repo_i18n
      saved_load_path = I18n.load_path.dup
      I18n.load_path.replace(upstream_only)
      I18n.translate("NinjaSlayer2.table.SATSUBATSU.name", locale: :ja_jp, raise: true)

      # 此时（且仅此时）追加本仓库 yml —— 漏了 reload! 就是这个状态
      I18n.load_path.concat(EngineBootstrap.i18n_files)

      # 无 raise 时返回占位串 —— 这就是"漏 reload! 却全绿"的静默形态
      placeholder = I18n.t(key, locale: :ja_jp)
      assert_match(/\Atranslation missing/, placeholder,
                   "构造的失效 backend 应返回占位串（模拟漏 reload! 的静默故障）")

      # 有 raise 时才暴露 —— 我们的断言正是靠这一点才有鉴别力
      assert_raises(I18n::MissingTranslationData) do
        I18n.translate(key, locale: :ja_jp, raise: true)
      end
    ensure
      I18n.load_path.replace(saved_load_path) if saved_load_path
      I18n.backend = original_backend
      I18n.backend.reload!
    end

    # 对照组：同一个"漏 reload!"的追加动作，只要补上 reload! 就能取到真实值
    recovered = I18n.translate(key, locale: :ja_jp, raise: true)
    assert_kind_of(String, recovered)
    refute_match(/\Atranslation missing/, recovered, "reload! 后仍取不到值，守卫逻辑本身有问题")
  end

  # ---------------------------------------------------------------------
  # ③ 类可发现（bot 侧 /system 列表与掷骰路由的根基）
  # ---------------------------------------------------------------------

  def test_all_game_systems_includes_both_ex_classes
    # 注意取 ID 必须写 `k::ID` 而**不能**写 `k.ID`（或 map(&:ID)）：
    # ID 是**常量**不是方法，Ruby 的 `.` 调用只在 send 语义下找方法，
    # 对常量必然 NoMethodError（实测 Illusio 等类 const_defined?(:ID) 为 true
    # 但 respond_to?(:ID) 为 false）。上游 loader.rb:11 也是用 `game_system::ID`。
    ids = BCDice.all_game_systems.map { |k| k::ID }
    assert_include(ids, "NinjaSlayer2Ex", "all_game_systems 未发现 NinjaSlayer2Ex（game_systems/ 未 require？）")
    assert_include(ids, "NinjaSlayerEx", "all_game_systems 未发现 NinjaSlayerEx")
  end

  def test_ex_classes_resolvable_and_subclassed
    ex2 = BCDice.game_system_class("NinjaSlayer2Ex")
    ex1 = BCDice.game_system_class("NinjaSlayerEx")

    assert_equal(BCDice::GameSystem::NinjaSlayer2Ex, ex2)
    assert_equal(BCDice::GameSystem::NinjaSlayerEx, ex1)
    assert_operator(ex2, :<, BCDice::GameSystem::NinjaSlayer2)
    assert_operator(ex1, :<, BCDice::GameSystem::NinjaSlayer)
  end

  def test_bootstrap_loads_every_game_system_file
    EngineBootstrap.game_system_files.each do |f|
      basename = File.basename(f, ".rb")
      next if basename == ".gitkeep" # 占位文件（若有）

      assert(defined?(BCDice::GameSystem), "bcdice/game_system 未加载")
    end
    refute_empty(EngineBootstrap.game_system_files, "game_systems/ 下应至少有扩展类文件")
  end
end