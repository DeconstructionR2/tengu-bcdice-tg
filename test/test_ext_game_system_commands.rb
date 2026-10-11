# frozen_string_literal: true

# ============================================================================
# T1.1④ 自研 toml 确定性测试 runner
#
# 上游 BCDice 把 runner（test/test_game_system_commands.rb + randomizer_mock.rb）
# 放在 test/ 目录下，但 bcdice gem 包并不发布 test/（计划 §0.1 / §15.5 V6），
# 我们用钉版快照 references/src/BCDice/test/ 中的原版做底，按本仓库结构改造。
#
# 改造点（v.s. 上游原版）：
#   1. 去掉 simplecov（我们要的是 runner，不跑覆盖率）；
#   2. 路径：相对仓库根；可用 TEST_TARGET 环境变量筛选单文件/单 system；
#   3. 在 require "bcdice" 后立即加载本仓库 game_systems/* 与本仓库 i18n/，
#      保持与 spike_t1_1.rb 同一套初始化序列（顺序：reload! → load_path 去重注入）；
#   4. 子类对照网：test/data/ 内置放 NinjaSlayer2Ex.toml / NinjaSlayerEx.toml
#      （上游用例仅改 game_system 字段的孪生副本），默认全量跑时子类复跑父类全部
#      用例，验证子类化不破坏父类行为（= T1.1③ 的 toml 形式重复确认）。
#
# 跑法：
#   bundle exec rake test                 # 跑 test/data/*.toml 全量
#   TEST_TARGET=NinjaSlayer2 bundle exec rake test   # 仅 NinjaSlayer2.toml
# ============================================================================

require "test/unit"
require "tomlrb"
require "json"

# 引擎初始化统一走共享 bootstrap（T2.1）：
#   reload! → 本仓库 i18n 去重注入 → require game_systems/*.rb
# 序列曾内联复制在 8 处，任何一处漏 reload! 就是**静默**全量 MissingTranslationData
# （i18n 缺翻译默认返回占位串不抛异常，测试照样绿）。收敛为唯一副本。
require_relative "../lib/engine_bootstrap"
EngineBootstrap.bootstrap!(reload_backend: true)

EXT_GAME_SYSTEMS = EngineBootstrap::GAME_SYSTEMS_DIR

require_relative "randomizer_mock"

class TestExtGameSystemCommands < Test::Unit::TestCase
  class << self
    # 目标文件：
    #   - 默认 test/data/*.toml
    #   - 环境变量 TEST_TARGET，可为逗号分隔的多值；不加扩展名则补 .toml；
    #     显式指定时只跑指定文件（不自动孪生子类对照——双跑交给默认全量流程）。
    def target_files
      env_target = ENV["TEST_TARGET"]
      unless env_target
        return Dir.glob(File.expand_path("data/*.toml", __dir__))
      end

      paths = env_target.split(",").flat_map do |target|
        target_with_extension = target.end_with?(".toml") ? target : "#{target}.toml"
        path = File.expand_path("data/#{target_with_extension}", __dir__)

        unless File.exist?(path)
          warn("Unknown target: #{path}")
          next []
        end

        # 用户显式指定了 TEST_TARGET 就只跑指定文件，不自动孪生。
        # 双跑 + 子类对照交给默认 rake test 流程（无 TEST_TARGET 时）做。
        [path]
      end.compact

      paths.uniq
    end
  end

  data do
    data_set = {}

    files = target_files()
    if files.empty?
      warn("No target found!")
      exit(1)
    end

    files.each do |filename|
      filename_base = File.basename(filename, ".toml")
      data = Tomlrb.load_file(filename, symbolize_keys: true)

      systems = data[:test].map { |t| t[:game_system] }.uniq
      unless systems.count == 1
        warn("Multiple game_system (#{systems.join(',')}) in #{filename}.")
        exit(1)
      end

      data[:test].each.with_index(1) do |test_case, index|
        test_case[:filename] = filename
        test_case[:output] = nil if test_case[:output].empty? # TOML用空串代 nil
        test_case[:secret] ||= false
        test_case[:success] ||= false
        test_case[:failure] ||= false
        test_case[:critical] ||= false
        test_case[:fumble] ||= false

        key = [filename_base, index, test_case[:input]].join(":")

        data_set[key] = test_case
      end
    end

    data_set
  end

  def test_diceroll(data)
    klass = BCDice.game_system_class(data[:game_system])
    game_system = klass.new(data[:input])

    rands = data[:rands].map { |r| [r[:value], r[:sides]] }
    game_system.randomizer = RandomizerMock.new(rands)

    msg = JSON.pretty_generate(data)

    result = game_system.eval()

    if result.nil?
      assert_nil(data[:output])
      return
    end

    assert_equal(data[:output], result.text, msg)
    assert_equal(data[:secret], result.secret?, msg)
    assert_equal(data[:success], result.success?, msg)
    assert_equal(data[:failure], result.failure?, msg)
    assert_equal(data[:critical], result.critical?, msg)
    assert_equal(data[:fumble], result.fumble?, msg)
    assert_match(klass.command_pattern, data[:input])
  end
end
