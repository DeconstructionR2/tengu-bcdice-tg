# frozen_string_literal: true

# ============================================================================
# T1.4 独立语义抽查：カルマロンダリング 钳制 + 索引（**不依赖生成器自证**）
#
# 为什么单独落一个文件：
#   scripts/gen_table_toml.rb 的 toml 用例是「从真实 eval 采集 output」——
#   逻辑上正确但**自证循环**：实现错了，生成的期望值也跟着错，测试照样绿。
#   本文件从 ledger（dice_ranges / datarange / min_index）+ i18n yml 的 items
#   **独立手推**期望值，断言引擎输出——两者独立成文，互为交叉验证。
#
# 跑法：bundle exec rake default（含在 test_files 里）
# 覆盖：4 组手推（任务书要求 ≥3）
#   ① KRS_C@6  → 出目 13 > max 12 → 钳到 items[11]
#   ② KRS_A@-2 → 出目 -1 < min 1  → 钳到 items[0]；另钉住 1（==min）不钳的边界
#   ③ KRO_D    → d3+3 的 4/5/6 三档（ledger min_sum=4 / max_sum=6）
#   ④ KRZ_D@1  → 出目 8 > max 6   → 钳到 items[5]
# ============================================================================

require "test/unit"
require "bcdice"
require "bcdice/game_system"
require "bcdice/translate"

I18n.backend.reload! if I18n.backend.respond_to?(:reload!)
I18n.load_path.concat(Dir[File.expand_path("../i18n/**/*.yml", __dir__)] - I18n.load_path)
Dir[File.expand_path("../game_systems/*.rb", __dir__)].sort.each { |f| require f }
require_relative "randomizer_mock"

KLASS = BCDice.game_system_class("NinjaSlayer2Ex")

class TestKarmarondSemantics < Test::Unit::TestCase
  # 跑一条命令，返回 Result（未响应时 nil）
  def roll(input, rands)
    gs = KLASS.new(input)
    gs.randomizer = RandomizerMock.new(rands.map(&:dup))
    gs.eval
  end

  # 独立从 yml 取第 n 项（n 为 1 基绝对索引，min_index=1）
  def item(key, face)
    I18n.t("NinjaSlayer2Ex.table.#{key}.items", locale: :ja_jp, raise: true)[face - 1]
  end

  # 从输出里取表文本部分。
  #
  # 输出形态为 `表名(骰型) ＞ (出目) ＞ 本文`，故按分隔符切成**恰好 3 段**
  # （limit=3：段数上限 3，第 3 段含可能含分隔符的本文全文，不被再切）。
  def body_of(text)
    parts = text.split(" ＞ ", 3)
    assert_equal(3, parts.size, "输出应恰为「表名(骰型) ＞ (出目) ＞ 本文」三段形态：#{text[0, 80].inspect}")
    parts[2]
  end

  # ① KRS_C@6：1D6+1，掷 6 → 6+1+6 = 13 > max(12) → 钳到 12 → items[11]
  def test_krs_c_clamps_upper_bound_to_items_11
    r = roll("KRS_C@6", [[6, 6]])
    assert_not_nil(r, "KRS_C@6 应响应")
    text = r.text
    assert_include(text, "(13→12)（クランプ）", "出目 13 应钳到 12 并明示钳制")
    assert_equal(item("KRS", 12), body_of(text),
                 "钳制后应逐字命中 items[12-1]（ledger max_index=12）")
  end

  # ①b KRS_C@5：掷 6 → 12 == max，**不**钳制（钳制判定是 <= max 而非 < max）
  def test_krs_c_at_exact_max_does_not_clamp
    r = roll("KRS_C@5", [[6, 6]])
    assert_not_nil(r)
    assert_include(r.text, "(12) ＞ ")
    assert_not_include(r.text, "クランプ", "出目恰为 max 时不应标注钳制")
    assert_equal(item("KRS", 12), body_of(r.text))
  end

  # ② KRS_A@-2：1D3，掷 1 → 1-2 = -1 < min(1) → 钳到 1 → items[0]
  def test_krs_a_clamps_lower_bound_to_items_0
    r = roll("KRS_A@-2", [[1, 3]])
    assert_not_nil(r)
    assert_include(r.text, "(-1→1)（クランプ）")
    assert_equal(item("KRS", 1), body_of(r.text),
                 "钳制后应逐字命中 items[1-1]（ledger min_index=1）")
  end

  # ②b KRS_A@-2：掷 3 → 1 == min，**不**钳制（下界钳制的 off-by-one 防线）
  def test_krs_a_at_exact_min_does_not_clamp
    r = roll("KRS_A@-2", [[3, 3]])
    assert_not_nil(r)
    assert_include(r.text, "(1) ＞ ")
    assert_not_include(r.text, "クランプ", "出目恰为 min 时不应标注钳制")
    assert_equal(item("KRS", 1), body_of(r.text))
  end

  # ③ KRO_D（1D3+3）：三档 4/5/6 对齐 ledger dice_ranges min_sum=4 / max_sum=6
  def test_kro_d_d3_plus_3_bounds
    {
      [[1, 3]] => 4,
      [[2, 3]] => 5,
      [[3, 3]] => 6,
    }.each do |rands, expected|
      r = roll("KRO_D", rands)
      assert_not_nil(r, "KRO_D（骰序 #{rands.inspect}）应响应")
      assert_include(r.text, "(#{expected}) ＞ ")
      assert_equal(item("KRO", expected), body_of(r.text),
                   "KRO_D 出目 #{expected} 应命中 items[#{expected - 1}]")
    end
  end

  # ④ KRZ_D@1（1D3+3）：掷 4 不可行（D 是 3 面），改掷 3 → 3+3+1 = 7 > max(6)
  #    → 钳到 6 → items[5]
  def test_krz_d_clamps_upper_bound
    r = roll("KRZ_D@1", [[3, 3]])
    assert_not_nil(r)
    assert_include(r.text, "(7→6)（クランプ）")
    assert_equal(item("KRZ", 6), body_of(r.text))
  end

  # 索引恒等式：五表 × 四骰型，在**无钳制的全可达域**内逐档验证
  # 「出目 → items[出目 - min_index]」严格成立（min_index=1）。
  #
  # 逐档枚举而非抽样：对每张表的每个骰型，把该骰型的**每一个可达出目**
  # 都走一遍（1D3 → 3 档、2D6 → 11 档 …），既验索引也验 datarange 边界。
  def test_index_identity_across_all_schools
    checked = 0
    KLASS::KARMAROND_DICE_TYPES.each do |school, types|
      types.each do |dice_key, spec|
        # 可达出目 = [times + bonus, times*sides + bonus]
        (spec[:times] + spec[:bonus]).upto(spec[:times] * spec[:sides] + spec[:bonus]) do |sum|
          dice_sum = sum - spec[:bonus]
          # 反推骰序（均匀铺开），保证 Σ骰面 == dice_sum
          base, extra = dice_sum.divmod(spec[:times])
          rolls = Array.new(spec[:times], base)
          rolls.first(extra).each_with_index { |_, idx| rolls[idx] += 1 }

          cmd = "#{school}_#{dice_key}"
          r = roll(cmd, rolls.map { |v| [v, spec[:sides]] })
          assert_not_nil(r, "#{cmd}（骰序 #{rolls.inspect}）应响应")
          assert_include(r.text, "(#{sum}) ＞ ", "#{cmd} 出目应为 #{sum}（骰序 #{rolls.inspect}）")

          range = KLASS::KARMAROND_DATARANGE[school]
          if sum < range[:min] || sum > range[:max]
            # 越界 → 必钳制，且命中端点项
            assert_include(r.text, "（クランプ）", "#{cmd} 出目 #{sum} 越界应钳制")
            endpoint = sum < range[:min] ? range[:min] : range[:max]
            assert_equal(item(school, endpoint), body_of(r.text),
                         "#{cmd} 出目 #{sum} 应钳到 #{endpoint} 项")
          else
            assert_not_include(r.text, "クランプ", "#{cmd} 出目 #{sum} 在范围内不应钳制")
            assert_equal(item(school, sum), body_of(r.text),
                         "#{cmd} 出目 #{sum} 应命中 items[#{sum - 1}]")
          end
          checked += 1
        end
      end
    end
    assert_operator(checked, :>=, 60, "覆盖档数应充足（5 表 × 4 骰型全可达域），实际 #{checked}")
  end

  # 天狗规则：带 @ 補正必须显式 _X（KRS@-1 不响应）；KRS_A@-1 响应
  def test_correction_requires_explicit_shortcut
    assert_nil(roll("KRS@-1", [[1, 3]]),
               "天狗规则「補正値を指定するときにはショートカットを省略できません」→ KRS@-1 不响应")
    r = roll("KRS_A@-1", [[1, 3]])
    assert_not_nil(r, "KRS_A@-1 应响应")
  end

  # 裸 KRS == KRS_A（天狗：ショートカット省略時は A）
  def test_bare_command_equals_a_branch
    a = roll("KRS", [[2, 3]]).text
    b = roll("KRS_A", [[2, 3]]).text
    assert_equal(a, b)
  end

  # 异常系：不响应（非响应时 result 为 nil）
  def test_unknown_forms_do_not_respond
    %w[KRB KRS_E KRS_X KRS_A@abc KRS_A@ KRS_AA KRX_D@1].each do |cmd|
      assert_nil(roll(cmd, [[1, 3]]), "#{cmd} 应不响应")
    end
  end

  # 暗骰 SKRS 前缀应生效（父类 prefixes_pattern 的 S? 分支）
  def test_secret_prefix
    r = roll("SKRS", [[1, 3]])
    assert_not_nil(r)
    assert_true(r.secret?, "SKRS 应为暗骰")
  end
end
