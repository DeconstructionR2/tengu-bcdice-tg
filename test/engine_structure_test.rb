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
#
# T1.7 为 1版 NinjaSlayerEx 也加了一组**独立**的 prefixes_pattern 覆写，
# 且形态与 2版**刻意不同**：
#   1版：`\A(S)?(<全部前缀，长度降序>)`
#   2版：`\A(?:<S 前缀降序>|^(S)?(<全部前缀>))`
# 原因是 1版 父类**没有** `[KENHU]` 字符类、且 14 个前缀两两无遮蔽
# （2版 的 SEISEN 阻塞 bug 正是「`[KENHU]` 字符类 + `(S)?` 回溯」所致）。
# 把「照抄 2版 的 S 前缀保护形态」套到 1版 前缀上，会让保护分支抢在 `(S)?` 之前
# 命中 `SB`，**回归掉合法暗骰**：
#   风险集 = { 非 S 前缀 q | "S"+q 以某 S 前缀开头 } = [BIOCYBER, BK]
#   · **精确风险集**（2 风险前缀 × 6 后缀形态 = 裸/`_`/`_A`/`@`/`@1`/`@36`）
#     = **12 条全部回归**（本文件 test_..._would_regress_secret_commands 的口径）；
#   · **宽候选集**（2 风险前缀 × 22 后缀形态 = 上面 6 种 + 上面 `suffixes` 的其余
#     15 种 + 空串，即本文件 test_..._is_behaviour_neutral 的 suffixes+[""]）
#     = **44 条全部回归**。
# 两个数字不是同一集合的两种数法，是**枚举集合不同**；引用时务必带上口径。
#
# 故本文件新增第 6~8 组断言覆盖 1版 侧：
#   6. 1版 prefixes_pattern 覆写的结构形态（**通式**，非硬编码前缀名）
#   7. 1版 的 secret parity 样本（**按 1版 自己的前缀重建**——
#      照抄 2版 样本会是**假绿**：1版 无 WS/WSE/NRS/UH/[KENHU]，
#      样本两边都匹配不上，assert_equal(nil, nil) 恒过）
#   8. 1版 前缀降序覆写与**引擎原生 pattern 的行为等价性**（穷举探针）——
#      证明它是行为中性的预防性覆写，而非引入了行为漂移
# ============================================================================

require "test/unit"

# 引擎初始化统一走共享 bootstrap（T2.1）。
# 注意：顺序上必须由 bootstrap 先完成 i18n 注入与 reload!，再 require 扩展类——
# 旧代码把 require game_systems/ 放在 reload! 之前，序列不对但因本仓库 yml
# 只被 translate 读取而侥幸没炸；收敛后不再依赖这类巧合。
require_relative "../lib/engine_bootstrap"
EngineBootstrap.bootstrap!(reload_backend: true)
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

  # ==========================================================================
  # 6~8. T1.7：1版 NinjaSlayerEx 的 prefixes_pattern 覆写 + secret parity
  # ==========================================================================
  EX1 = BCDice::GameSystem::NinjaSlayerEx
  PARENT1 = BCDice::GameSystem::NinjaSlayer

  # T1.7 的 9 张表新增前缀
  EDITION1_PREFIXES = %w[WS JITSB DKKI KRM CYBER BIOCYBER SOUL SUMMON BK].freeze

  # 1版 的 secret parity 样本 = **1版 实际存在的**前缀（父类 5 个 + 新增 9 个）。
  #
  # 为何 1版 侧不需要「S 前缀保护」（与 2版的差异根源）：
  #   2版 SEISEN 阻塞 bug 源于 `[KENHU]` 这个**字面量被当作字符类**——
  #   `SEISEN9` 的 S 被 `(S)?` 吃掉后剩 `EISEN9`，其 E 命中 `[KENHU]` 字符类。
  #   1版 父类**没有** `[KENHU]`，且 14 个前缀两两无遮蔽
  #   （无一是另一的前缀），`(S)?` 吃掉首字母 S 后剩余串必然不匹配任何前缀
  #   → 回溯让 `(S)?` 匹配空 → 命令正常命中。故 1版 **不复现**该 bug，
  #   只需保留 `(S)?` 分组 + 降序排列即可（第 8 组断言证明行为等价）。
  EDITION1_SECRET_SAMPLES = %w[NJ EV AT EL SB WS JITSB DKKI KRM CYBER BIOCYBER SOUL SUMMON BK].freeze

  def test_edition1_prefixes_pattern_override_structure
    # R1 守卫的**参考产物**：父类自己的 prefixes_pattern。
    # 上游 base.rb 若改 pattern 的锚点/分组/flag（如从 `^(S)?(...)` 改成别的形态），
    # 这条断言当场红——而不变的话，Ex 的覆写会**静默**与上游语义脱钩
    # （比如上游若把 `(S)?` 改成 `(s)?i` 或加了 \\A 锚点，
    #   Ex 仍按旧假设拼装 → 暗骰捕获行为悄悄变）。
    ref = PARENT1.prefixes_pattern

    # **通式**断言：降序前缀 + 保留 `(S)?` 捕获组。
    # 与 2版 形态的差异（不写保护分支、不丢 `(S)?`）是**刻意**的，
    # 不是笔误——理由见文件头注释与 test_edition1_prefixes_pattern_is_behaviour_neutral。
    want = "\\A(S)?(?:#{EX1.prefixes_desc.join('|')})"
    assert_equal(want.b, EX1.prefixes_pattern.source.b,
                 "NinjaSlayerEx.prefixes_pattern 结构漂移（上游升级或覆写被破坏）")
    # 父类原生 pattern 仍应是 `(S)?(前缀表)` 形态——若上游改了，这条会红
    assert_equal("^(S)?(#{PARENT1.prefixes.join('|')})".b, ref.source.b,
                 "父类 prefixes_pattern 的形态变了（R1 守卫）")
    assert_predicate(EX1.prefixes_pattern, :casefold?, "IGNORECASE flag 缺失")
    assert_predicate(EX1.prefixes_pattern, :frozen?)
    assert_predicate(EX1.prefixes_desc, :frozen?, "prefixes_desc 必须冻结（时序铁律）")

    # 降序：长度相同时保持注册顺序（稳定排序，使 source 逐字节可复现）
    lengths = EX1.prefixes_desc.map(&:length)
    assert_equal(lengths.sort.reverse, lengths,
                 "1版 前缀必须按长度降序排列（否则短前缀先命中，吃掉长前缀）")
  end

  def test_edition1_secret_parity_with_parent
    EDITION1_SECRET_SAMPLES.each do |prefix|
      ["#{prefix}", "S#{prefix}"].each do |input|
        # 只对**父类也存在**的前缀比对「与父类逐字节一致」：
        # 新增前缀（WS/JITSB/…）在父类里本就不匹配，比对会得到
        # nil vs "WS" 的假差异——那是**预期**的注册差异，不是漂移。
        next unless PARENT1.prefixes.include?(prefix)

        m_ex = EX1.prefixes_pattern.match(input)
        m_pa = PARENT1.prefixes_pattern.match(input)
        assert_equal(m_pa && m_pa[1], m_ex && m_ex[1],
                     "1版 secret 捕获不一致 @ #{input.inspect}" \
                     "（父 #{m_pa && m_pa[1].inspect} vs Ex #{m_ex && m_ex[1].inspect}）")
      end
    end

    # 新增前缀的自身语义：裸输入不是暗骰，S 前缀输入才是。
    EDITION1_PREFIXES.each do |prefix|
      m_bare = EX1.prefixes_pattern.match(prefix)
      assert_nil(m_bare && m_bare[1], "#{prefix}（裸）不应被判为暗骰")
      m_s = EX1.prefixes_pattern.match("S#{prefix}")
      assert_equal("S", m_s && m_s[1], "S#{prefix} 应是暗骰（S 被 (S)? 吃掉）")
    end

    # **S 开头的表前缀不得被 `(S)?` 吃掉首字母后失配**（2版 SEISEN bug 的 1版 对照组）
    %w[SOUL SUMMON].each do |prefix|
      m = EX1.prefixes_pattern.match(prefix)
      assert_not_nil(m, "#{prefix} 必须命中前缀（1版 无 [KENHU]，不应复现 2版 的阻塞 bug）")
      assert_nil(m[1], "#{prefix} 首字母 S 不应被当作暗骰标记吃掉")
    end
  end

  # **穷举等价性**：本覆写与「未覆写的引擎原生 pattern」行为必须完全一致。
  #
  # 这是 T1.7 覆写的**核心价值证明**：它当前是**行为中性的预防性覆写**
  # （1版 无 [KENHU]、无前缀遮蔽 → 2版 的 bug 不复现），
  # 价值在于「日后注册新前缀时不依赖 alternation 顺序恰好正确」。
  # 若此断言失败 = 覆写引入了行为漂移（比不改更糟），必须当场红。
  def test_edition1_prefixes_pattern_is_behaviour_neutral
    native = Regexp.new("^(S)?(#{EX1.prefixes.join('|')})", Regexp::IGNORECASE)

    # 候选集用**生成式**而非手写清单：前缀 × {裸 / S / SS} × 后缀形态。
    #
    # 初版这里手写了 30 来条，实测（攻击实验）真正被 2版形态破坏的是 **44 条**，
    # 手写清单只覆盖到其中一小部分——穷举强度不够的断言等于半盲。
    # 生成式覆盖 928 条候选，任何前缀集合变化都自动跟着变。
    suffixes = %w[
      _ _A _B _C _D @ @0 @1 @2 @6 @12 @36 @99 @03
      Q X 6 x x_ _@3 _A@1
    ] + [""]
    candidates = []
    EX1.prefixes.each do |prefix|
      ["", "S", "SS"].each do |lead|
        suffixes.each { |suffix| candidates << "#{lead}#{prefix}#{suffix}" }
      end
    end
    # 另加几条**不属于任何前缀**的畸形串（验证「不该命中就不命中」）
    candidates += %w[QQQ SEISEN9 SEISEN SWSQ SBKX SSOULX BKK WS@ WS_ BK]
    candidates.uniq!
    assert_operator(candidates.size, :>=, 500,
                    "候选集退化了（#{candidates.size} 条）；穷举强度不足时本断言接近半盲")

    diffs = candidates.reject do |c|
      a = native.match(c)
      b = EX1.prefixes_pattern.match(c)
      ta = a ? [a[1], c[a.end(0)..]] : nil
      tb = b ? [b[1], c[b.end(0)..]] : nil
      ta == tb
    end
    assert_empty(diffs,
                 "1版 prefixes_pattern 覆写与引擎原生 pattern 行为不一致：#{diffs.inspect}" \
                 "（覆写引入了行为漂移，必须当场红）")
  end

  # **反向对照**：证明「照抄 2版 的 S 前缀保护形态」在 1版 上是**错的**。
  #
  # 这是本组断言里最重要的一条：它把「为什么 1版 不采用 2版 形态」
  # 从注释升级为**可执行的事实**。若没有它，后人看到两版 Ex 类形态不一致，
  # 极可能「统一风格」把 1版 改成 2版 形态——而那会静默回归掉
  # 44 条合法暗骰命令（实测 SBIOCYBER_ / SBK / SBKX … 全被截成 IO 前缀）。
  #
  # 反向逻辑：2版 形态把「保护分支」放在 `(S)?` **之前**，于是 `SBIOCYBER`
  # 先命中保护分支的 `SB` → 剩 `IOCYBER` → 命令失配 → 合法暗骰静默失效。
  # 1版 无 `[KENHU]`、无前缀遮蔽，故根本不需要这个保护分支。
  def test_edition1_two_version_form_would_regress_secret_commands
    s_prefixes = EX1.prefixes.grep(/\A[Ss]/)
    protected = Regexp.new(
      "\\A(?:#{s_prefixes.sort_by { |p| [-p.length, p] }.join('|')}" \
      "|^(S)?(#{EX1.prefixes.join('|')}))",
      Regexp::IGNORECASE
    )

    # 构造**真实受影响**的样本：`S` + 某个**非 S 开头**的前缀 + 后缀。
    #
    # ⚠ 受影响集合的精确刻画（初版两次踩坑后才定准，务必读懂再改）：
    #   2版 形态的保护分支 `\A(?:SUMMON|SOUL|SB|...)` 排在 `(S)?` **之前**。
    #   命令 `S{prefix}…` 会先被保护分支试匹配，只有当字符串 **`S{prefix}` 本身
    #   以某个 S 前缀开头** 时才命中保护分支并留下错误残串。
    #     · `SBK`     → `SBK` 以 `SB` 开头  → 保护分支吃掉 `SB`，剩 `K`  → 失配 ✗
    #     · `SBIOCYBER` → 以 `SB` 开头        → 剩 `IOCYBER`            → 失配 ✗
    #     · `SNJ4`    → `SNJ4` 不以任何 S 前缀开头 → 保护分支不命中，
    #                    回溯到 `(S)?` 分支，行为与原生一致 → 不构成回归 ✓
    #   所以风险集 = { 非 S 前缀 q | ("S"+q) 以某个 S 前缀开头 }，
    #   1版 实测恰好 = [BIOCYBER, BK]（因 1版 只有 SB/SOUL/SUMMON 三个 S 前缀）。
    #   「S + S 前缀」本身**不**受影响（两条路径都判 secret，结果一致）。
    risky = EX1.prefixes.reject { |q| q.match?(/\A[Ss]/) }
                       .select { |q| s_prefixes.any? { |s| "S#{q}".start_with?(s) } }
    assert_include(risky, "BIOCYBER", "BIOCYBER 以 SB 开头，必须是本对照的风险样本之一")
    assert_include(risky, "BK", "BK 与 SB 构成 SBK，必须是本对照的风险样本之一")

    affected = risky.flat_map do |prefix|
      ["", "_", "_A", "@", "@1", "@36"].map { |suffix| "S#{prefix}#{suffix}" }
    end
    assert_operator(affected.size, :>=, 12,
                    "受影响样本退化了（#{affected.size} 条）；前缀集合变了需重估")

    regressions = affected.reject do |c|
      a = native_edition1_pattern.match(c)
      b = protected.match(c)
      ta = a ? [a[1], c[a.end(0)..]] : nil
      tb = b ? [b[1], c[b.end(0)..]] : nil
      ta == tb
    end

    # 实测：2 个风险前缀 × 6 个后缀 = 12 条候选，**全部**回归。
    assert_equal(affected.size, regressions.size,
                 "2版 形态的回归样本只有 #{regressions.size}/#{affected.size} 条（预期全部）：" \
                 "若此变红，说明 2版 的 prefixes_pattern 语义变了，1版 的形态选择需要重评")

    # 逐条确认「原生能捕获 secret、2版 形态留下错误残串」——这是回归的实际后果。
    regressions.each do |c|
      a = native_edition1_pattern.match(c)
      assert_equal("S", a && a[1], "#{c}: 引擎原生 pattern 下应是暗骰")

      b = protected.match(c)
      rest2 = c[(b && b[1] ? 1 : 0) + b[2].to_s.size..]
      assert_not_equal(rest2, c[1..],
                       "#{c}: 2版 形态下剩余串被改写成 #{rest2.inspect}" \
                       "——这正是它不可用于 1版 的原因")
    end
  end

  # **刻意差异：`\A` vs 父类的 `^`**（kimi T1.7 评审事实 #3，改为可执行断言）。
  #
  # 父类用行锚 `^` → `"X\nSB"` 在原生 pattern 下也匹配（第二行）；
  # 本覆写用串首锚 `\A` → 不匹配。这是**刻意**的（BCDice 命令面语义是整串匹配），
  # 且**经 eval 不可达**（Preprocessor 先在首个空白处截断）。
  #
  # 把这个「已知差异」写成断言，是为了让日后有人发现它时第一反应是
  # 「哦，这是登记过的取舍」而不是「覆写引入了未知分叉」。
  def test_edition1_uses_string_anchor_not_line_anchor
    multiline = "X\nSB"

    assert_nil(EX1.prefixes_pattern.match(multiline),
               "1版 覆写用 \\A（串首锚），多行输入的第二行不应被匹配")
    assert_not_nil(PARENT1.prefixes_pattern.match(multiline),
                   "父类用的是 ^（行锚）；若上游改锚点，这条会红——\\A 与之的差异需重评")

    # 差异在端到端不可达：Preprocessor 先截断到首个空白
    inst = EX1.new(multiline)
    assert_nil(inst.eval, "多行输入经 Preprocessor 截断后不应响应（两边一致的失败路径）")
  end

  # 引擎原生 pattern（1版，未加任何覆写）的参照物。
  def native_edition1_pattern
    Regexp.new("^(S)?(#{EX1.prefixes.join('|')})", Regexp::IGNORECASE)
  end
end
