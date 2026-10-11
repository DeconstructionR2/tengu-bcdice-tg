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
require_relative "../scripts/text_rewrite"

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
    #   （JSON 侧须先经声明式 TEXT_REWRITE 改写——yml 存的是改写后形态，
    #   拍板 C 删除了 :japanese_goblin: 表情码）
    yml_judge = I18n.t("NinjaSlayer2Ex.judge.SEISEN", locale: :ja_jp, raise: true)
    assert_equal(rewrite_text(wasshoi.dig("kinds", "SEISEN", "judge_name")), yml_judge[:judge_name],
                 "SEISEN judge_name 与 JSON 不一致")
    assert_equal(wasshoi.fetch("success_word"), yml_judge[:success_word],
                 "SEISEN success_word 与 JSON 不一致")
    assert_equal(rewrite_text(wasshoi.dig("kinds", "SEISEN", "success_message")), yml_judge[:success_message],
                 "SEISEN success_message 与 JSON 不一致")
    assert_equal(wasshoi.fetch("failure_word"), yml_judge[:failure_word],
                 "SEISEN failure_word 与 JSON 不一致")
  end

  # ==========================================================================
  # T1.7：1版 9 表 —— 骨架选型 / min_index / 别名收敛 / 骰型（**逐表钉死**）
  #
  # 本组是 T1.7 的常驻守卫，与 scripts/gen_table_toml.rb §4 的 T1.7 段
  # **互为补充**：生成器只在重生成时跑，本文件每次 `rake test` 都跑。
  # ==========================================================================
  KLASS1 = BCDice.game_system_class("NinjaSlayerEx")

  # T1.7 的 9 张 1版表（顺序 = yml / ledger 顺序）。
  EDITION1_KEYS = %w[WS JITSB DKKI KRM CYBER BIOCYBER SOUL SUMMON BK].freeze

  # 逐表登记的期望值（**独立于 ledger 的第二份抄本**）。
  #
  # 为什么要独立抄一份而不是只读 ledger：三方交叉校验（ledger ↔ 代码 ↔ yml）
  # 能证明三者**互相一致**，但不能证明它们**同时错**——若有人把 ledger 的
  # min_index 从 2 改成 1 并同步改了代码，交叉校验仍全绿，
  # 而 CYBER 会静默错位一格。这里把「CYBER/SUMMON 的 min_index 是 2」
  # 作为**独立事实**写进测试常量，与实现逐条对拍。
  #
  # 数据源：references/extracted/i18n_key_ledger.yml 的 min_index 字段
  #         （由 extract_tengu_data.mjs 从天狗 data 的**实际键**推出，
  #          不是人工填的——故它与「天狗 data 键范围」是同一个事实的两个视角）。
  EDITION1_EXPECTED_MIN_INDEX = {
    "WS" => 1, "JITSB" => 1, "DKKI" => 1, "KRM" => 1,
    "CYBER" => 2,          # 2D6 表 → data 键 2..12
    "BIOCYBER" => 1, "SOUL" => 1,
    "SUMMON" => 2,         # 2D6 表 → data 键 2..12
    "BK" => 1
  }.freeze

  # 每张表**全部**骰型后缀 → 骰型（别名收敛后的形态）。
  #
  # 关键语义：`_X` 后缀是**按唯一骰型去重**的结果，不是天狗别名字典的搬运。
  #   JITSB 的天狗字典有 10 个键，但只有 2 个唯一骰型（1d6 / 1d6+1）；
  #   KRM 有 13 个键，但只有 3 个（1d6 / 1d6+1 / 2d6）。
  #   **KRM 不提供 `_D`**：天狗的 `,D` 实为 `1d6`，与 `,A` 同骰，
  #   提供它等于凭空多一个与 `_A` 无差别的可选项。
  EDITION1_EXPECTED_DICE = {
    "WS" => { "A" => "1D6" },
    "JITSB" => { "A" => "1D6", "B" => "1D6+1" },
    "DKKI" => { "A" => "1D6" },
    "KRM" => { "A" => "1D6", "B" => "1D6+1", "C" => "2D6" },
    "CYBER" => { "A" => "2D6" },
    "BIOCYBER" => { "A" => "1D6" },
    "SOUL" => { "A" => "1D6" },
    "SUMMON" => { "A" => "2D6" },
    "BK" => { "A" => "1D36" }
  }.freeze

  def test_edition1_registered_tables_match
    assert_equal(EDITION1_KEYS, KLASS1::EDITION1_TABLES.to_a,
                 "NinjaSlayerEx 登记的表清单与 T1.7 清单不一致")
  end

  # ① **骨架选型 ⟺ ledger 的 datarange 有无**（T1.7 拍板的核心不变量）。
  #    9 表全部 :no_clamp ——一旦有人给某表加 datarange 或加钳制常量，当场红。
  def test_edition1_skeletons_are_all_no_clamp
    EDITION1_KEYS.each do |key|
      assert_equal(:no_clamp, KLASS1::EDITION1_SKELETONS[key],
                   "#{key} 骨架选型应为 :no_clamp（1版 9 表的 dice 字面量均无 \"+x\"，" \
                   "天狗 isTableAdditionValue 不置位 → 恒走 data[出目]，无钳制）")
      assert_nil(entry(key)["datarange"],
                 "#{key} ledger datarange 应为 nil；若确需钳制，说明该表已不是纯查表语义")
    end
  end

  # ② **min_index 逐表正确**（含 CYBER/SUMMON 的 2 —— 2版 的「恒为 1」经验在这里会错位）
  def test_edition1_min_index_per_table
    EDITION1_KEYS.each do |key|
      assert_equal(EDITION1_EXPECTED_MIN_INDEX.fetch(key), KLASS1::EDITION1_MIN_INDEX[key],
                   "#{key} 的 min_index 应为 #{EDITION1_EXPECTED_MIN_INDEX[key]}")
      assert_equal(EDITION1_EXPECTED_MIN_INDEX.fetch(key), entry(key)["min_index"],
                   "#{key} ledger min_index 与独立抄本不一致")
    end
  end

  # ③ **别名收敛后的骰型集 == 天狗别名字典按表达式去重的唯一值集**
  #    （ledger ↔ 代码）：多一个 = 凭空多出无差别选项；少一个 = 漏实现可达出目。
  def test_edition1_dice_types_match_deduplicated_ledger
    EDITION1_KEYS.each do |key|
      impl = KLASS1::EDITION1_DICE_TYPES[key]
      assert_not_nil(impl, "#{key} 在 EDITION1_DICE_TYPES 中缺失")

      # 期望（独立抄本）
      want = EDITION1_EXPECTED_DICE.fetch(key)
      assert_equal(want.keys.sort, impl.keys.map(&:to_s).sort,
                   "#{key} 骰型后缀集不一致：期望 #{want.keys.sort}，实得 #{impl.keys.sort}")
      want.each do |suffix, expr|
        assert_equal(expr, impl[suffix][:expr], "#{key}_#{suffix} 骰型应为 #{expr}")
      end

      # ledger 侧：按表达式去重后的唯一集必须与代码**完全相等**
      ledger_exprs = entry(key)["dice"].values.map { |v| normalize_1_dice_expr(v) }.uniq.sort
      code_exprs = impl.values.map { |s| s[:expr].downcase.strip }.uniq.sort
      assert_equal(ledger_exprs, code_exprs,
                   "#{key} 别名收敛后的骰型集与 ledger 不一致：" \
                   "天狗 #{entry(key)['dice'].size} 个别名去重后应为 #{ledger_exprs.inspect}")
    end
  end

  # ④ **同骰的别名不得被实现成两个后缀**（KRM 的 `,D` 实为 1d6）。
  #    这条是「不提供 `_D`」这一拍板的守卫：若有人把天狗的 13 个别名
  #    逐个搬成后缀，`_A` 与 `_D` 会变成两个完全同骰的选项。
  def test_edition1_no_duplicate_dice_suffixes
    EDITION1_KEYS.each do |key|
      by_expr = KLASS1::EDITION1_DICE_TYPES[key].group_by { |_, s| s[:expr] }
      dups = by_expr.select { |_, v| v.size > 1 }.keys
      assert_empty(dups, "#{key} 存在同骰的重复后缀 #{dups.inspect}（应按唯一骰型去重）")
    end
  end

  # ⑤ **无钳制 ⇒ 每个骰型的可达域必须 ⊆ 表跨度**
  #    （否则那部分出目恒不响应 = 规格漂移的静默信号）。
  def test_edition1_reachable_domain_within_table_span
    EDITION1_KEYS.each do |key|
      min_i = KLASS1::EDITION1_MIN_INDEX.fetch(key)
      items = I18n.t("NinjaSlayerEx.table.#{key}.items", locale: :ja_jp, raise: true)
      max_i = min_i + items.length - 1

      # yml items 数 == ledger item_count == data_index 跨度
      assert_equal(entry(key)["item_count"], items.length, "#{key} yml items 数与 ledger item_count 不符")
      assert_equal(entry(key)["max_index"] - entry(key)["min_index"] + 1, items.length,
                   "#{key} yml items 数与 data_index 跨度不符")

      KLASS1::EDITION1_DICE_TYPES[key].each do |suffix, spec|
        lo = spec[:times] + spec[:bonus]
        hi = spec[:times] * spec[:sides] + spec[:bonus]
        assert_operator(lo, :>=, min_i,
                        "#{key}_#{suffix} 可达域下界 #{lo} < 表下界 #{min_i}（越界即不响应）")
        assert_operator(hi, :<=, max_i,
                        "#{key}_#{suffix} 可达域上界 #{hi} > 表上界 #{max_i}（越界即不响应）")
      end
    end
  end

  # ⑥ BK 是 **单颗 36 面**（T1.5 已实证的 d36 结论在 1版 侧的复钉）。
  #    若有人按 D66 实现，times 会变 2 而当场红。
  def test_edition1_d36_is_single_36_sided_die
    spec = KLASS1::EDITION1_DICE_TYPES.fetch("BK").fetch("A")
    assert_equal(1, spec[:times], "BK 应是**单颗**骰（D36 非 D66）")
    assert_equal(36, spec[:sides], "BK sides 应为 36")
    assert_equal("1d36", entry("BK")["dice"]["a"].downcase, "BK ledger dice.a 应为 1d36")
  end

  # ⑦ **9 个前缀已注册**，且与父类前缀无遮蔽（遮蔽会改变 prefixes_pattern 的命中顺序）
  def test_edition1_prefixes_registered_and_unshadowed
    parent = KLASS1.superclass.prefixes
    added = KLASS1.prefixes - parent
    assert_equal(EDITION1_KEYS, added,
                 "NinjaSlayerEx 相对父类新增的前缀应恰为 T1.7 的 9 个表键")

    added.combination(2) do |a, b|
      assert_not_equal(b[0, a.length], a, "新增前缀 #{a} 遮蔽了 #{b}（必须两两无前缀关系）")
    end
  end

  # ==========================================================================
  # ⑧ HELP_MESSAGE：**常量覆写会吃掉父类全文**（T1.7 自审抓到的真实缺口）
  #
  # HELP_MESSAGE 是普通常量，子类一旦定义就**整个替换**父类的。
  # 初版只写扩展段 → bot 侧 /help 里 1版玩家最常用的 NJ/EV/AT/EL/SB
  # 说明全部消失。故本组断言两条：
  #   ① 父类 HELP 全文逐字包含在 Ex HELP 里；
  #   ② 9 个新表命令**都**在 HELP 里有条目。
  # （注：直接读 superclass::HELP_MESSAGE 而不是照抄一份文字——
  #   父类日后增补说明会自动跟着走，不会出现第二份漂移。）
  # ==========================================================================
  def test_edition1_help_message_keeps_parent_and_lists_all_tables
    parent_help = BCDice::GameSystem::NinjaSlayer::HELP_MESSAGE
    ex_help = KLASS1::HELP_MESSAGE

    assert_not_equal(parent_help, ex_help, "Ex 的 HELP_MESSAGE 未被覆写（本批 9 表必须有自己的说明）")
    assert_include(ex_help, parent_help,
                   "Ex 的 HELP_MESSAGE 必须**逐字包含**父类全文——" \
                   "常量覆写不拼接，漏掉会让 /help 丢失 NJ/EV/AT/EL/SB 的用法")

    EDITION1_KEYS.each do |key|
      assert_include(ex_help, key, "HELP_MESSAGE 未提到表 #{key}（玩家无从得知该命令存在）")
    end

    # 扩展段的语义要点必须在场（避免 HELP 只是一张命令清单而无边界说明）
    ["定値表示", "補正値", "応答しません"].each do |frag|
      assert_include(ex_help, frag, "HELP_MESSAGE 缺少关键语义说明「#{frag}」")
    end
  end

  # ==========================================================================
  # ⑨ **yml 正文逐字保真**（kimi T1.7 评审翻车点 1 —— 测试网的真实盲区）
  #
  # 为什么必须常驻化：toml 的 `output` 是从 **yml** 真实 eval 采集的，
  # ledger 只登记**结构**（条目数 / dice / min_index / datarange）不存正文。
  # → 若 i18n/NinjaSlayerEx/ja_jp.yml 某一条 items 抄错天狗原文一个字，
  #   三方交叉校验全绿、全部 toml 用例全绿、rake full 全绿，
  #   而玩家看到的是**错的规则文本**。这是本批最隐蔽的失败面。
  #
  # 数据源：references/extracted/tengu_tables.json
  #         ← node scripts/extract_tengu_data.mjs 直接 require 钉版天狗 JS 导出
  #   （「让 JS 引擎自己解析」而非正则切 template literal，T1.2 定的两棒管线）。
  # 比对时必须走与生成器**同一个** rewrite_items（声明式改写），
  # 否则命中改写的表会被判「不一致」——这是 T1.5 修过的同型坑。
  # ==========================================================================
  def test_edition1_yml_items_verbatim_match_tengu_source
    json = JSON.parse(File.read(File.join(ROOT, "references/extracted/tengu_tables.json"), encoding: "UTF-8"))
    key_to_ja = {
      "WS" => "wasshoiエントリー_1",
      "JITSB" => "ジツ拡張サイバネ暴走_1",
      "DKKI" => "暗黒カラテ衝動_1",
      "KRM" => "カルマロンダリング_1",
      "CYBER" => "サイバネ狂気判定_1",
      "BIOCYBER" => "バイオサイバネ狂気判定_1",
      "SOUL" => "ソウル鑑定_1",
      "SUMMON" => "ソーマトリコール_1",
      "BK" => "生い立ち_1"
    }

    EDITION1_KEYS.each do |key|
      ja = key_to_ja.fetch(key)
      src = json.fetch("tables").fetch(ja)
      got = I18n.t("NinjaSlayerEx.table.#{key}.items", locale: :ja_jp, raise: true)
      want = src["items"].map { |s| rewrite_text(s) }

      assert_equal(src["items"].size, got.size, "#{key}（#{ja}）条目数与天狗源不符")
      want.each_with_index do |w, i|
        next if got[i] == w

        flunk("#{key}（#{ja}）第 #{i + 1} 项正文与天狗源**不一致**——" \
              "这是抄写/改写漂移，不是显示差异（源 #{w[0, 40].inspect} vs yml #{got[i].to_s[0, 40].inspect}）")
      end

      # name 也逐字核对（表名 + 骰型标记）
      assert_equal("#{ja}(#{src['dice']['a'] || src['dice'].values.first}) ＞ ".sub(/(\d+d\d+)/i) { |m| m.upcase },
                   I18n.t("NinjaSlayerEx.table.#{key}.name", locale: :ja_jp, raise: true),
                   "#{key} 的 yml name 与天狗原表名/骰型标记不一致")
    end
  end

  # 天狗骰型字面量 → 归一化的 "<times>d<sides>[+<bonus>]"（与 gen_table_toml 同解）。
  def normalize_1_dice_expr(raw)
    s = raw.to_s.downcase.gsub("+x", "").strip
    s = "1#{s}" if s.start_with?("d")
    s
  end
end
