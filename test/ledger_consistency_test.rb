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
end
