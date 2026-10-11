# frozen_string_literal: true

# ============================================================================
# 引擎结构守卫（kimi T1.5 评审 P3 落地 / T1.6 泛化 + 追加判定扩展）
#
# 背景：NinjaSlayer2Ex 覆写了 prefixes_pattern（T1.5 给 SEISEN 加 S 前缀保护分支，
# 修 base.rb:47 `(S)?` 先吃首字母 + [KENHU] 字符类误吞 E 的阻塞级 bug；
# T1.6 把它泛化为「自动保护所有 S/s 开头的前缀」）。
# T1.6 追加判定扩展还新增了一条**自带**的 dice 部正则 RE_EX_DICEROLL +
# 一条 appendix 正则 RE_EX_APPENDIX_ONE，两条都触碰引擎层的命令面解析。
# 这些覆写触碰上游核心机制 → R1 升级风险：gem 升级改了 prefixes_pattern /
# 命令正则的签名或语义时，本覆写可能静默劣化。本文件把它们变成**当场红**：
#
#   1. prefixes_pattern 覆写结构形态（**通式**：保护分支 == 动态收集的 S 前缀集合，
#      不是硬编码 "SEISEN"）—— 上游改前缀正则形态时当场红；
#   2. S 保护集合的构成断言（集合、长度降序、与 prefixes 一致）——
#      有人新注册 S 前缀却忘了泛化逻辑时当场红；
#   3. 全前缀 secret 捕获行为与父类逐字节一致（受保护前缀是唯一有意差异）；
#   4. RE_EX_APPENDIX_ONE / RE_EX_DICEROLL 结构断言（判定符集合与父类同源、
#      y 形态与父类同源、记忆符字母表封闭）—— 防止日后单边漂移；
#   5. 天狗对拍：记忆符 [J]/[L] 的边界与标签必须逐字等于天狗 appTransration 的值。
# ============================================================================

require "test/unit"
require "bcdice"
require "bcdice/game_system"
Dir[File.expand_path("../game_systems/*.rb", __dir__)].sort.each { |f| require f }

I18n.backend.reload! if I18n.backend.respond_to?(:reload!)
I18n.load_path.concat(Dir[File.expand_path("../i18n/**/*.yml", __dir__)] - I18n.load_path)
require_relative "randomizer_mock"

class TestEngineStructure < Test::Unit::TestCase
  EX = BCDice::GameSystem::NinjaSlayer2Ex
  PARENT = BCDice::GameSystem::NinjaSlayer2

  # ==========================================================================
  # 1. prefixes_pattern 覆写结构（通式）
  # ==========================================================================
  def test_prefixes_pattern_override_structure
    # 参考产物：父类机制（prefixes_pattern 方法）作用于「与 Ex 相同前缀集合」的
    # 匿名子类——等价于 Ex 覆写内 `super.source` 的期望形态，但不经 Ex 的覆写。
    # 上游 base.rb 若改 pattern 形态（锚点/分组/flag），ref 变而 Ex 不变 → 当场红。
    extra = EX.prefixes - PARENT.prefixes
    ref = Class.new(PARENT) do
      register_prefix_from_super_class()
      register_prefix(*extra)
    end.prefixes_pattern

    # **通式**断言：保护分支的内容 == 「Ex 已注册的 S/s 前缀，按长度降序」，
    # 而不是硬编码某个前缀名。T1.6 泛化的核心就在这里：
    # 若有人把泛化改回单前缀硬编码，本断言立刻红。
    assert_equal("\\A(?:#{EX.s_protected_prefixes.join('|')}|#{ref.source})".b,
                 EX.prefixes_pattern.source.b,
                 "NinjaSlayer2Ex.prefixes_pattern 结构漂移（上游升级或覆写被破坏）")
    assert_equal(ref.casefold?, EX.prefixes_pattern.casefold?, "IGNORECASE flag 不一致")
    assert_predicate(EX.prefixes_pattern, :frozen?)
  end

  # ==========================================================================
  # 2. S 前缀保护集合的构成（T1.6 泛化的核心）
  # ==========================================================================
  def test_s_protected_prefixes_is_dynamic_and_complete
    # 集合完整性：所有以 S/s 开头的已注册前缀都必须在保护集合里，一个不漏。
    all_s = EX.prefixes.grep(/\A[Ss]/).sort
    assert_equal(all_s, EX.s_protected_prefixes.sort,
                 "S 前缀保护集合与已注册前缀不一致（有新 S 前缀未被保护 = 复现 T1.5 阻塞 bug）")

    # 顺序：长度降序（保证最长前缀先试，否则 SB 会吃掉 SBX 的前两字母）
    lengths = EX.s_protected_prefixes.map(&:length)
    assert_equal(lengths.sort.reverse, lengths,
                 "S 前缀保护集合必须按长度降序排列（否则短前缀先命中，吃掉长前缀）")

    # 冻结：注册在类定义期完成，冻结后列表恒定封闭
    assert_predicate(EX.s_protected_prefixes, :frozen?)

    # T1.5 已知受害者 + T1.6 新纳入的 SBX/SB 必须在集合里
    %w[SEISEN SBX SB].each do |p|
      assert_include(EX.s_protected_prefixes, p, "#{p} 应受 S 前缀保护")
    end
  end

  # ==========================================================================
  # 3. secret 捕获行为与父类逐字节一致（S 前缀是唯一有意差异）
  # ==========================================================================
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
    # 保护分支自身的语义：S 前缀命令裸输入不是暗骰，双 S 才是。
    EX.s_protected_prefixes.each do |prefix|
      m_bare = EX.prefixes_pattern.match(prefix)
      assert_nil(m_bare && m_bare[1], "#{prefix}（裸）不应被判为暗骰")
      m_ss = EX.prefixes_pattern.match("S#{prefix}")
      assert_equal("S", m_ss && m_ss[1], "S#{prefix} 应是暗骰（第二个 S 被吃掉）")
    end
    assert_nil(EX.prefixes_pattern.match("SEISEN9")[1], "SEISEN9 不应是暗骰")
    assert_equal("S", EX.prefixes_pattern.match("SSEISEN9")[1], "SSEISEN9 应是暗骰")
  end

  # ==========================================================================
  # 4. 追加判定扩展的两条正则：结构断言（防止日后单边漂移）
  # ==========================================================================
  def test_appendix_regex_structure
    # 判定符集合必须与父类 RE_COUNT_JUDGE 的分组 1 逐字同源。
    # 父类源码：/(=|!=|>=|>|<=|<)([1-6]+\+?|[1-6])/
    # 注意 `!=` 里的 `!`：直接 /\(=[^)]*\)/ 取不到（第一个分支是 `=`，
    # 其后紧跟 `|`），故用「从第一个 `(` 到第一个 `)`」的通用取法。
    parent_op_group = PARENT::RE_COUNT_JUDGE.source[/\(([^()]*)\)/, 1]
    assert_equal("(=|!=|>=|>|<=|<)", "(#{parent_op_group})",
                 "父类 RE_COUNT_JUDGE 的判定符组结构变了（R1 守卫）")
    assert_include(EX::APPENDIX_ONE_FRAGMENT, "(=|!=|>=|>|<=|<)",
                   "APPENDIX_ONE_FRAGMENT 的判定符组必须与父类 RE_COUNT_JUDGE 逐字同源")

    # RE_EX_APPENDIX_ONE 就是片段 + 锚点（构造保证，同源不是靠人工同步）
    assert_equal("\\A#{EX::APPENDIX_ONE_FRAGMENT}\\z".b, EX::RE_EX_APPENDIX_ONE.source.b,
                 "RE_EX_APPENDIX_ONE 必须 == 片段 + \\A…\\z 锚点")

    # RE_EX_DICEROLL 的 dice 部必须与父类 RE_JUDGE_DICEROLL 分组 1 同源。
    # 父类源码：((?:(?:UH|[KENHU])?\d+,?)+)
    assert_include(PARENT::RE_JUDGE_DICEROLL.source, "((?:(?:UH|[KENHU])?\\d+,?)+)",
                   "父类 RE_JUDGE_DICEROLL 的 dice 部结构变了（R1 守卫）")
    assert_include(EX::RE_EX_DICEROLL.source, "((?:(?:UH|[KENHU])?\\d+,?)+)",
                   "RE_EX_DICEROLL 的 dice 部必须与父类同源")

    # 记忆符字母表封闭且与片段的记忆符组一致
    assert_equal(%w[J L], EX::APPENDIX_MEMO_KEYS, "记忆符字母表应恰为 J / L（计划 §5：[C] 不搬）")
    assert_include(EX::APPENDIX_ONE_FRAGMENT, "([JL])", "片段的记忆符组必须覆盖 J / L")
    # [C] 刻意不搬：片段里不含 C
    assert_not_include(EX::APPENDIX_ONE_FRAGMENT, "[C]",
                       "[C] 不得进入记忆符组（计划 §5 拍板：保上游 クリティカル语义）")
  end

  # ==========================================================================
  # 5. 天狗对拍：[J]/[L] 的边界与标签必须等于天狗 appTransration 的值
  #    （标签逐字来自 i18n，此处验证 i18n 的值 == 天狗源码真值）
  # ==========================================================================
  def test_memo_semantics_match_tengu
    # appTransration 实测（tengu_dice/NJShortcutTranslator.js:124）：
    #   j → '=1/ジツ暴走'
    #   l → '=6/LAN直結出目6数'
    expect = {
      "J" => { border: 1, label: "ジツ暴走" },
      "L" => { border: 6, label: "LAN直結出目6数" }
    }
    inst = EX.new("K6[J]")
    expect.each do |memo, want|
      got = inst.send(:appendix_ex_memo, memo)
      assert_equal(want[:border], got[:border], "#{memo} 的 border 应等于天狗 appTransration")
      assert_equal(want[:label], got[:label], "#{memo} 的标签应逐字等于天狗 appTransration")
    end

    # 记忆符的计数逻辑必须与 [=border] 等价（等价改写的正确性）：
    # parse_ex_appendix 对两者产出的 spec 除 label 外完全相同，
    # 且走同一条 proc_ex_appendix 计数路径 → 计数结果必然一致。
    rr = BCDice::CommonCommand::BarabaraDice.eval(
      "6B6>=2", inst, RandomizerMock.new(([1, 2, 3, 4, 5, 6]).map { |v| [v, 6] })
    )
    memo_spec = inst.send(:parse_ex_appendix, "J")
    plain_spec = inst.send(:parse_ex_appendix, "=1*1")
    assert_equal(1, memo_spec[:border].to_i, "[J] 的 border 应为 1")
    assert_equal("=", memo_spec[:op], "[J] 的判定符应为 =（等价于 [=1]）")
    assert_equal(plain_spec.reject { |k, _| k == :label },
                 memo_spec.reject { |k, _| k == :label },
                 "[J] 与 [=1] 的 spec 必须逐字段一致（仅 label 不同）")
    assert_equal(inst.send(:proc_ex_appendix, rr, memo_spec).sub(", ジツ暴走", ", 追加判定"),
                 inst.send(:proc_ex_appendix, rr, plain_spec),
                 "[J] 与 [=1] 的计数结果必须一致（仅标签不同）")
  end

  # ==========================================================================
  # 6. 「非法即不响应且不掷骰」—— parse/count 两层分离的构造保证
  # ==========================================================================
  def test_invalid_appendix_rejected_before_rolling
    inst = EX.new("K6[>=5*101]")
    # 只给 1 颗骰：若实现先掷骰再判非法，这里会抛 "@rands is empty!"。
    inst.randomizer = RandomizerMock.new([[1, 6]])
    assert_nil(inst.eval, "超上界倍率必须整条不响应")
  end
end