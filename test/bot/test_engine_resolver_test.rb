# frozen_string_literal: true

# ============================================================================
# test/bot/test_engine_resolver_test.rb — EngineResolver 防御性加固（2026-10-12）
#
# system_ids 逐项取 ID（filter_map + 逐项 rescue）：任何一个规则类缺 ID 常量
# （或取常量时炸掉）只丢**那一个**系统，不再像旧实现那样整体 rescue → []
# 把整张列表清空。当前钉版 gem 实测 338 类全有 ID（2026-10-12 复核，
# docs/EXTENDING.md 的旧断言已按此订正），本测试钉的是「未来 gem 升级引入
# 无 ID 类」的防御。
# ============================================================================

require "minitest/autorun"
require_relative "test_helper"
require_relative "../../bot/handlers/dice"
require_relative "../../lib/engine_bootstrap"

EngineBootstrap.bootstrap!(reload_backend: true)

class TestEngineResolver < Minitest::Test
  Resolver = TelegramBot::Handlers::EngineResolver

  def test_system_ids_survives_a_class_without_id_constant
    good = Class.new { const_set(:ID, "ZetaTestSystem") }
    broken = Class.new # 无 ID 常量：klass::ID 抛 NameError

    original = BCDice.method(:all_game_systems)
    BCDice.define_singleton_method(:all_game_systems) { [broken, good] }

    ids = Resolver.system_ids
    assert_equal ["ZetaTestSystem"], ids, "无 ID 的类只丢自己，不拖垮整张列表"
  ensure
    BCDice.define_singleton_method(:all_game_systems) { original.call }
  end

  def test_system_ids_real_list_is_sorted_and_nonempty
    ids = Resolver.system_ids
    refute_empty ids
    assert_equal ids.sort, ids, "列表应升序"
    assert_includes ids, "NinjaSlayer2Ex"
  end
end
