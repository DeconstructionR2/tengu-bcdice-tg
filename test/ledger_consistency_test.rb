# frozen_string_literal: true

# ============================================================================
# ledger ↔ 实现常量 ↔ yml 三方一致性常驻测试（kimi T1.4 评审 P1-2 落地）
#
# 背景：scripts/gen_table_toml.rb 的 cross_validate! 只在生成期跑，不进 CI；
# 规格漂移（ledger 笔误 / 代码常量笔误 / yml 手改）会让测试网静默全绿。
# 本文件把核心断言常驻化，挂入 rake default。
#
# 覆盖：カルマロンダリング 5 表（骰型/補正/datarange/条目数/min_index）、
#       NSRS（骰型/min_index）、SBX/WSX（条目数跨度）。
# 新增表时在此追加对应断言组—— specs 的唯一权威来源是 ledger。
# ============================================================================

require "test/unit"
require "yaml"
require "json"
require "bcdice"
require "bcdice/game_system"
require "bcdice/translate"

I18n.backend.reload! if I18n.backend.respond_to?(:reload!)
I18n.load_path.concat(Dir[File.expand_path("../i18n/**/*.yml", __dir__)] - I18n.load_path)
Dir[File.expand_path("../game_systems/*.rb", __dir__)].sort.each { |f| require f }

class TestLedgerConsistency < Test::Unit::TestCase
  ROOT = File.expand_path("..", __dir__)
  LEDGER = YAML.load_file(File.join(ROOT, "references/extracted/i18n_key_ledger.yml"),
                          aliases: true)["entries"]
  KLASS = BCDice.game_system_class("NinjaSlayer2Ex")

  def entry(key)
    LEDGER.find { |e| e["ascii_key"] == key } or flunk("ledger 未登记 #{key}")
  end

  # ledger dice_ranges → { "A" => {times:, sides:, bonus:} }
  def ledger_specs(key)
    entry(key)["dice_ranges"].to_h do |r|
      m = r["base"].match(/\A(\d+)D(\d+)\z/i) or flunk("无法解析 base #{r['base']}")
      times = m[1].to_i
      [r["key"].upcase, { times: times, sides: m[2].to_i, bonus: r["min_sum"] - times }]
    end
  end

  def assert_specs_equal(school, impl)
    ledger_specs(school).each do |k, ls|
      is = impl[k] or flunk("#{school}_#{k} 在实现常量中缺失")
      assert_equal(ls[:times], is[:times], "#{school}_#{k} times 不一致（ledger #{ls[:times]} vs 实现 #{is[:times]}）")
      assert_equal(ls[:sides], is[:sides], "#{school}_#{k} sides 不一致")
      assert_equal(ls[:bonus], is[:bonus], "#{school}_#{k} bonus 不一致")
    end
    assert_equal(ledger_specs(school).keys.sort, impl.keys.map(&:to_s).sort,
                 "#{school} 骰型键集合不一致")
  end

  def test_karma_specs_match_ledger
    %w[KRS KRZ KRA KRO KRY].each do |school|
      assert_specs_equal(school, KLASS::KARMAROND_DICE_TYPES[school])

      dr = entry(school)["datarange"]
      impl_range = KLASS::KARMAROND_DATARANGE[school]
      assert_equal(dr["min"], impl_range[:min], "#{school} datarange.min 不一致")
      assert_equal(dr["max"], impl_range[:max], "#{school} datarange.max 不一致")

      # yml items 数 == data_index 跨度 == datarange 跨度（失配即规格漂移）
      items = I18n.t("NinjaSlayer2Ex.table.#{school}.items", locale: :ja_jp, raise: true)
      span = entry(school)["max_index"] - entry(school)["min_index"] + 1
      assert_equal(span, items.length, "#{school} yml items 数与 data_index 跨度不符")
      assert_equal(dr["max"] - dr["min"] + 1, span, "#{school} datarange 与 data_index 跨度不符")
      assert_equal(1, entry(school)["min_index"], "#{school} min_index 应为 1")
    end
  end

  def test_nsrs_spec_matches_ledger
    assert_specs_equal("NSRS", KLASS::NSRS_DICE_TYPES)
    assert_equal(entry("NSRS")["min_index"], KLASS::NSRS_TABLE_MIN_INDEX,
                 "NSRS_TABLE_MIN_INDEX 与 ledger min_index 不一致")

    items = I18n.t("NinjaSlayer2Ex.table.NSRS.items", locale: :ja_jp, raise: true)
    span = entry("NSRS")["max_index"] - entry("NSRS")["min_index"] + 1
    assert_equal(span, items.length, "NSRS yml items 数与 data_index 跨度不符")
  end

  def test_simple_tables_yml_span
    %w[SBX WSX].each do |key|
      items = I18n.t("NinjaSlayer2Ex.table.#{key}.items", locale: :ja_jp, raise: true)
      span = entry(key)["max_index"] - entry(key)["min_index"] + 1
      assert_equal(span, items.length, "#{key} yml items 数与 data_index 跨度不符")
    end
  end

  # ==========================================================================
  # T1.5：キャラメイク 6 表 + 定値表示 + 聖戦判定
  #
  # kimi T1.5 评审预警 1「无 datarange/+x 的表绝不钳制」在这里**常驻化**：
  # 一旦有人给这 6 张表加上 datarange 或在代码里引入钳制常量，断言立刻红。
  # ==========================================================================
  CHARAMAKE_KEYS = %w[NJI NJS NJN NJK NJC NJB].freeze

  def test_chara_make_specs_match_ledger
    CHARAMAKE_KEYS.each do |key|
      impl = KLASS::CHARAMAKE_DICE_TYPES[key]
      assert_not_nil(impl, "#{key} 在 CHARAMAKE_DICE_TYPES 中缺失")

      # ① 绝不钳制：ledger 的 datarange 必须恒为 nil
      assert_nil(entry(key)["datarange"],
                 "#{key} ledger datarange 应为 nil（本批无 +x，天狗不钳制）；" \
                 "若确需钳制，说明该表已不是 T1.5 的纯查表语义，请先改实现再改此断言")

      # ② 骰型：ledger base 逐位对齐代码 times/sides
      dr = entry(key)["dice_ranges"].fetch(0)
      m = dr["base"].match(/\A(\d+)D(\d+)\z/i) or flunk("无法解析 ledger base #{dr['base']}")
      assert_equal(m[1].to_i, impl[:times], "#{key} times 与 ledger 不一致")
      assert_equal(m[2].to_i, impl[:sides], "#{key} sides 与 ledger 不一致")

      # ③ min_index
      assert_equal(entry(key)["min_index"], KLASS::CHARAMAKE_TABLE_MIN_INDEX,
                   "#{key} CHARAMAKE_TABLE_MIN_INDEX 与 ledger min_index 不一致")
      assert_equal(1, entry(key)["min_index"], "#{key} min_index 应为 1")
    end
  end

  # d36 实证结论的常驻化（预警 2：1D36 是**单颗 36 面**，不是 D66）。
  #
  # 这条断言锁死 sides == 36 且 times == 1。若日后有人误按 D66 实现
  # （两颗 6 面组合成 11..66 再映射），times 会变成 2 而立刻红。
  def test_d36_is_single_36_sided_die_not_d66
    %w[NJK NJB].each do |key|
      impl = KLASS::CHARAMAKE_DICE_TYPES[key]
      assert_equal(1, impl[:times], "#{key} 应是**单颗**骰（D36 非 D66），times 却是 #{impl[:times]}")
      assert_equal(36, impl[:sides], "#{key} sides 应为 36")
    end

    # 与 ledger 的 dice 字面量对照：必须是 "1d36" 而非 "2d6"
    %w[NJK NJB].each do |key|
      assert_equal("1d36", entry(key)["dice"]["a"].downcase,
                   "#{key} ledger dice.a 应为 1d36")
    end
  end

  # 无钳制 ⇒ 掷骰可达域必须与 items 数**严格相等**。
  # 若不相等，出目就会落到 items 之外（不响应），是规格漂移的信号。
  def test_chara_make_reachable_domain_matches_items
    CHARAMAKE_KEYS.each do |key|
      impl = KLASS::CHARAMAKE_DICE_TYPES[key]
      items = I18n.t("NinjaSlayer2Ex.table.#{key}.items", locale: :ja_jp, raise: true)
      reachable = impl[:times] * impl[:sides]
      assert_equal(items.length, reachable,
                   "#{key} 掷骰可达域（#{reachable}）≠ yml items 数（#{items.length}）；" \
                   "本批无钳制，二者必须恒等")
    end
  end

  # 定値表示 `@n` 的边界：items 长度即 `@n` 的合法上界。
  #
  # 这里断言的是**索引算术的不变量**（索引 = @n − min_index）；
  # 「@0 / @max+1 真的不响应」由 toml 异常系用例端到端钉住，不在此重复。
  def test_chara_make_fixed_index_bounds
    CHARAMAKE_KEYS.each do |key|
      items = I18n.t("NinjaSlayer2Ex.table.#{key}.items", locale: :ja_jp, raise: true)
      min_i = KLASS::CHARAMAKE_TABLE_MIN_INDEX
      max_i = min_i + items.length - 1

      # @min 与 @max 必须都存在（两侧边界都可显示）
      assert_not_nil(items[min_i - 1], "#{key}@#{min_i} 应可显示（items 下边界）")
      assert_not_nil(items[max_i - 1], "#{key}@#{max_i} 应可显示（items 上边界）")

      # @max+1 的索引恰为 items.length → 正下标越界 → nil。
      #
      # ⚠ 下界侧**不能**用 items[min_i - 2]（= items[-1]）来探测"越界"——
      #   Ruby 负下标会绕回数组末尾、返回**最后一项**而非 nil，断言假红
      #   （本任务实测踩中）。故下界侧只断言索引算术，不去索引数组。
      assert_nil(items[items.length], "#{key}@#{max_i + 1} 的索引应越界（items 上界之外）")
      assert_equal(items.length - 1, max_i - min_i,
                   "#{key} @max 的索引 #{items.length - 1} 应等于 max_i − min_index")
      assert_operator(0 - min_i, :<, 0,
                      "#{key}@0 的索引 #{0 - min_i} 为负（越界）；负下标不可用于数组探测")
    end
  end

  # 聖戦判定：骰型 / 判定式 / 文案 三方对齐（JSON ↔ 代码 ↔ yml）。
  def test_seisen_spec_matches_json_and_yml
    json = JSON.parse(File.read(File.join(ROOT, "references/extracted/tengu_tables.json"), encoding: "UTF-8"))
    wasshoi = json.fetch("wasshoi")

    # ① 骰型 2d6
    m = wasshoi.fetch("dice_expression").match(/\A(\d*)d(\d+)\z/i)
    assert_not_nil(m, "JSON wasshoi.dice_expression 无法解析")
    want_times = m[1].empty? ? 1 : m[1].to_i
    assert_equal(want_times, KLASS::SEISEN_DICE_TIMES, "SEISEN 骰数与 JSON 不一致")
    assert_equal(m[2].to_i, KLASS::SEISEN_DICE_SIDES, "SEISEN 面数与 JSON 不一致")

    # ② 判定式为 <=（防止有人改成 < 或 >=）
    assert_include(wasshoi.fetch("comparison"), "<=", "JSON comparison 应含 <=")
    assert_equal(:<=, KLASS::SEISEN_CMP, "代码 SEISEN_CMP 应为 :<=")

    # ③ 文案逐字：yml judge 段 ↔ JSON wasshoi
    #
    # ⚠ I18n.t 取子树时返回的是**符号键** Hash（实测），故用 :judge_name 之类。
    yml_judge = I18n.t("NinjaSlayer2Ex.judge.SEISEN", locale: :ja_jp, raise: true)
    assert_equal(wasshoi.dig("kinds", "SEISEN", "judge_name"), yml_judge[:judge_name],
                 "SEISEN judge_name 与 JSON 不一致")
    assert_equal(wasshoi.fetch("success_word"), yml_judge[:success_word],
                 "SEISEN success_word 与 JSON 不一致")
    assert_equal(wasshoi.dig("kinds", "SEISEN", "success_message"), yml_judge[:success_message],
                 "SEISEN success_message 与 JSON 不一致")
    assert_equal(wasshoi.fetch("failure_word"), yml_judge[:failure_word],
                 "SEISEN failure_word 与 JSON 不一致")
  end
end
