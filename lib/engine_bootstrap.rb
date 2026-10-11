# frozen_string_literal: true

# ============================================================================
# lib/engine_bootstrap.rb — 引擎初始化共享 bootstrap（T2.1，P1 验收遗留项②）
#
# 为什么存在（P1 验收实测复现过的坑，见 docs/spike-t1.1-report.md §2 坑点 A）：
#
#   require "bcdice" 之后，BCDice base.rb 末尾已经把 gem 内的
#   i18n/**/*.yml 塞进 I18n.load_path，但 **并没有**触发加载。
#   i18n gem 的 I18n::Backend::Simple 在**首次 translate 时**才跑
#   init_translations，跑完就 mark @initialized = true —— 此后**永不**重读
#   load_path。若在其之后才把本仓库 i18n/**/*.yml 追加进去，注入静默失效，
#   所有 NinjaSlayer*Ex.* 键全部返回 "translation missing: ..." 字符串而
#   **不抛异常**（i18n 缺翻译的默认行为，见 spike 报告坑点 C）。
#
#   正解序列（顺序不可换）：
#     1. require "bcdice"
#     2. I18n.backend.reload!    ← 清 @initialized，让下次 translate 重载全量 load_path
#     3. I18n.load_path.concat(本仓库 yml - 已有 load_path)   ← 去重，防重复调用时单调增长
#     4. require 本仓库 game_systems/*.rb   ← 让 BCDice.all_game_systems 能发现 Ex 类
#
#   旧代码把这个序列**内联复制**在 7 个文件里（scripts/gen_table_toml.rb、
#   test/{test_ext_game_system_commands,i18n_guard,engine_structure,
#   karmarond_semantics,ledger_consistency}_test.rb、test/spike_t1_1.rb、
#   test/spike_t1_6.rb）。任何一处漏掉 reload! 就是静默全量 MissingTranslationData，
#   而漏掉 reload! **不会**让测试变红——它只会让占位字符串"看起来正常"。
#   本文件把序列收敛成唯一副本，是 T2.1 的前置件（计划 §8 T2.1、§12 R2 相邻风险）。
#
# 幂等契约（test/engine_bootstrap_test.rb 钉住）：
#   - 重复调用 EngineBootstrap.bootstrap! 不使 I18n.load_path 增长；
#   - load_path 中不存在"数组元素"（I18n.load_path << Dir[...] 会塞进一个数组，
#     坑点 B）——一律 concat 平展；
#   - 二次调用后 translate 仍能取到 Ex 命名空间的真实值（不是占位串）。
#
# 只读红线：本文件不修改 vendor/bundle/** 与 references/src/**。
# ============================================================================

require "bcdice"
require "bcdice/game_system"
require "bcdice/translate"

module EngineBootstrap
  ROOT = File.expand_path("..", __dir__)
  I18N_DIR = File.join(ROOT, "i18n")
  GAME_SYSTEMS_DIR = File.join(ROOT, "game_systems")

  # 本仓库自有的 i18n yml（去重 + 排序，保证 load_path 注入顺序稳定）
  def self.i18n_files
    Dir[File.join(I18N_DIR, "**/*.yml")].sort
  end

  # 本仓库 game_systems/ 下的扩展类文件（排序保证 require 顺序确定）
  def self.game_system_files
    Dir[File.join(GAME_SYSTEMS_DIR, "*.rb")].sort
  end

  # 注入本仓库 i18n 到 load_path（去重）。
  #
  # 用 `concat(new - existing)` 而不是 `<<`：
  #   - `- existing` 保证重复调用不增长（幂等契约）；
  #   - `concat` 平展数组，而 `<<` 会塞进一个 Array 元素（spike 报告坑点 B）。
  #
  # 返回真正新增的条目数（测试用来断言二次调用为 0）。
  def self.inject_i18n_load_path
    new_files = i18n_files - I18n.load_path.flatten
    I18n.load_path.concat(new_files) unless new_files.empty?
    new_files.size
  end

  # 引擎初始化主入口。可重复调用（幂等）。
  #
  # @param reload_backend [Boolean] 是否强制 backend reload!
  #   true  = 每次调用都 reload（安全但每次触发全量 yml 重载，测试/开发环境用）
  #   false = 仅在首次调用时 reload（生产长驻进程用，避免热路径重复全量重载）
  # @return [Boolean] true=本次调用执行了 reload; false=本次调用是幂等空转
  def self.bootstrap!(reload_backend: false)
    fresh = true
    if reload_backend
      I18n.backend.reload! if I18n.backend.respond_to?(:reload!)
    else
      fresh = !@bootstrapped
    end

    inject_i18n_load_path

    # require game_systems/*.rb —— 类只定义一次，Ruby 的 require 自带幂等，
    # 但这里显式走 require（非 load）以确保重复 bootstrap 不重复执行类体。
    game_system_files.each { |f| require f }

    if fresh
      # 首次：load_path 已注入 + 类已加载，此时 reload! 让下一次 translate
      # 把「gem 内 yml + 本仓库 yml」一次性读全。必须在注入**之后**。
      I18n.backend.reload! if I18n.backend.respond_to?(:reload!)
      @bootstrapped = true
    end

    fresh
  end

  # 供测试与诊断：当前进程是否已完成过 bootstrap
  def self.bootstrapped?
    !!@bootstrapped
  end

  # 供测试与诊断：强制复位（**仅测试用**——让每个用例都能从干净状态验幂等）
  def self.reset!
    @bootstrapped = false
  end
end