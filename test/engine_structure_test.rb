# frozen_string_literal: true

# ============================================================================
# 引擎结构守卫（kimi T1.5 评审 P3 落地）
#
# 背景：NinjaSlayer2Ex 覆写了 prefixes_pattern（给 SEISEN 加 S 前缀保护分支，
# 修 base.rb:47 `(S)?` 先吃首字母 + [KENHU] 字符类误吞 E 的阻塞级 bug）。
# 该覆写触碰上游核心机制 → R1 升级风险：gem 升级改了 prefixes_pattern 的
# 签名/语义时，本覆写可能静默劣化。本测试把它变成**当场红**：
#   1. 覆写结构形态断言（source 与 flags 与「父类机制原生产物」的关系锁死）
#   2. 全前缀 secret 捕获行为与父类逐字节一致（SEISEN 是唯一有意差异）
# ============================================================================

require "test/unit"
require "bcdice"
require "bcdice/game_system"
Dir[File.expand_path("../game_systems/*.rb", __dir__)].sort.each { |f| require f }

class TestEngineStructure < Test::Unit::TestCase
  EX = BCDice::GameSystem::NinjaSlayer2Ex
  PARENT = BCDice::GameSystem::NinjaSlayer2

  def test_prefixes_pattern_override_structure
    # 参考产物：父类机制（prefixes_pattern 方法）作用于「与 Ex 相同前缀集合」的
    # 匿名子类——等价于 Ex 覆写内 `super.source` 的期望形态，但不经 Ex 的覆写。
    # 上游 base.rb 若改 pattern 形态（锚点/分组/flag），ref 变而 Ex 不变 → 当场红。
    extra = EX.prefixes - PARENT.prefixes
    ref = Class.new(PARENT) do
      register_prefix_from_super_class()
      register_prefix(*extra)
    end.prefixes_pattern

    assert_equal("\\A(?:SEISEN|#{ref.source})".b, EX.prefixes_pattern.source.b,
                 "NinjaSlayer2Ex.prefixes_pattern 结构漂移（上游升级或覆写被破坏）")
    assert_equal(ref.casefold?, EX.prefixes_pattern.casefold?, "IGNORECASE flag 不一致")
    assert_predicate(EX.prefixes_pattern, :frozen?)
  end

  # 对父类每个前缀的代表性输入，Ex 与父类的 secret 捕获必须一致
  def test_secret_capture_parity_with_parent
    samples = { "UH" => "UH", "[KENHU]" => "E", "SB" => "SB", "WS" => "WS",
                "WSE" => "WSE", "NRS" => "NRS" }
    samples.each_value do |cmd|
      ["#{cmd}", "S#{cmd}"].each do |input|
        m_ex = EX.prefixes_pattern.match(input)
        m_pa = PARENT.prefixes_pattern.match(input)
        assert_equal(m_pa && m_pa[1], m_ex && m_ex[1],
                     "secret 捕获不一致 @ #{input.inspect}（父 #{m_pa && m_pa[1].inspect} vs Ex #{m_ex && m_ex[1].inspect}）")
      end
    end
    # SEISEN 保护分支自身的语义
    assert_nil(EX.prefixes_pattern.match("SEISEN9")[1], "SEISEN9 不应是暗骰")
    assert_equal("S", EX.prefixes_pattern.match("SSEISEN9")[1], "SSEISEN9 应是暗骰")
  end
end
