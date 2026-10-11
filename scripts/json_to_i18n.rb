#!/usr/bin/env ruby
# frozen_string_literal: true

# ============================================================================
# T1.2 第二棒：references/extracted/tengu_tables.json → i18n/*/ja_jp.yml 草稿
#
# 铁律（计划 §8 T1.2② + kimi 评审翻车预测 #2）：
#   - **yml 一律用 Ruby psych（YAML.dump）从解析后的字符串机器生成**，禁止手工拼
#     YAML。表文本含 \n / 全角半角混排 / 行尾空格，runner 断言逐字比对，
#     手工拼 YAML 必然出错。
#   - 顶层命名空间只允许 NinjaSlayerEx / NinjaSlayer2Ex（test/i18n_guard_test.rb 强制）。
#   - 表结构对齐上游 name / type / items（references/src/BCDice/i18n/NinjaSlayer2/ja_jp.yml）。
#   - 键名用纯 ASCII（计划 §13 第 2 项定案）；日文原表名收进映射台账，不进 yml 键。
#   - 现有 dummy 表（SPIKE_DUMMY）**保留**，新表追加在其后。
#   - 归属存疑的表标「待裁决」进台账，**不猜**（任务书铁律）。
#
# 跑法：
#   bundle exec ruby scripts/json_to_i18n.rb            # 生成 + 自检
#   bundle exec ruby scripts/json_to_i18n.rb --dry-run  # 只报告，不写盘
# ============================================================================

require "json"
require "yaml"
require "optparse"

ROOT = File.expand_path("..", __dir__)
JSON_PATH = File.join(ROOT, "references/extracted/tengu_tables.json")
OUT_NSL2EX = File.join(ROOT, "i18n/NinjaSlayer2Ex/ja_jp.yml")
OUT_NSLEX = File.join(ROOT, "i18n/NinjaSlayerEx/ja_jp.yml")
LEDGER_PATH = File.join(ROOT, "references/extracted/i18n_key_ledger.yml")

options = { dry_run: false }
OptionParser.new { |o| o.on("--dry-run") { options[:dry_run] = true } }.parse!

abort "[json_to_i18n] 找不到 #{JSON_PATH}；先跑 node scripts/extract_tengu_data.mjs" unless File.exist?(JSON_PATH)

data = JSON.parse(File.read(JSON_PATH, encoding: "UTF-8"))

# ---------------------------------------------------------------------------
# 1. 表归属 + ASCII 键名映射
#
#    kind:   :nsl2ex（2版 NinjaSlayer2Ex）/ :nsl1ex（1版 NinjaSlayerEx）
#    status: :planned（已定案）/ :pending_arb（待用户裁决，不写 yml）
#
#    归属依据：
#      · 计划 §5「NSRS発狂表×4骰型 / カルマロンダリング×5派阀 / キャラメイク6表 → NinjaSlayer2Ex」
#      · 计划 §13 第 3 项「1版 9 表全搬 → NinjaSlayerEx」
#      · 计划 §5 表内「1版 9 表」清单逐条对齐（该清单含 wasshoi_1、**不含** サツバツ_1）
# ---------------------------------------------------------------------------
MAPPING = [
  # ===================== 2版 → NinjaSlayer2Ex（12 张）========================
  { ja: "nsrs発狂", kind: :nsl2ex, key: "NSRS", status: :planned,
    note: "NSRS 発狂（ニンジャ PC 側、4 骰型 a=1d3/b=1d6/c=1d6+1/d=1d3+1）。" \
          "计划 §5「BCDice 缺失 NSRS，镜像 NRS 实现」——本表是 2版唯一真正的**新增 NRS 族**表。" },

  { ja: "ソウカイヤカルマロンダリング", kind: :nsl2ex, key: "KRS", status: :planned,
    note: "ソウカイヤ派 a=1d3+x / b=1d6+x / c=1d6+1+x / d=2d6+x，datarange 1..12" },
  { ja: "ザイバツカルマロンダリング", kind: :nsl2ex, key: "KRZ", status: :planned,
    note: "ザイバツ派 a=1d3+x / b=1d3+1+x / c=2d3+x / d=d3+3+x，datarange 1..6" },
  { ja: "アマクダリカルマロンダリング", kind: :nsl2ex, key: "KRA", status: :planned,
    note: "アマクダリ派 a=1d3+x / b=1d3+1+x / c=2d3+x / d=d3+3+x，datarange 1..6" },
  { ja: "オムラカルマロンダリング", kind: :nsl2ex, key: "KRO", status: :planned,
    note: "オムラ派 a=1d3+x / b=1d3+1+x / c=2d3+x / d=d3+3+x，datarange 1..6" },
  { ja: "ヨロシサンカルマロンダリング", kind: :nsl2ex, key: "KRY", status: :planned,
    note: "ヨロシサン派 a=1d3+x / b=1d3+1+x / c=2d3+x / d=d3+3+x，datarange 1..6" },

  { ja: "初期ジツ系統", kind: :nsl2ex, key: "NJI", status: :planned, note: "初期ジツ系統（1d6）" },
  { ja: "初期スキル",   kind: :nsl2ex, key: "NJS", status: :planned, note: "初期スキル（1d6）" },
  { ja: "初期アイテム", kind: :nsl2ex, key: "NJN", status: :planned, note: "初期アイテム（1d6）" },
  { ja: "初期知識スキル", kind: :nsl2ex, key: "NJK", status: :planned, note: "初期知識スキル d36（36 条）" },
  { ja: "初期サイバネ", kind: :nsl2ex, key: "NJC", status: :planned, note: "初期サイバネ（1d6）" },
  { ja: "生い立ち",     kind: :nsl2ex, key: "NJB", status: :planned, note: "ネオサイタマ生い立ち d36（36 条）" },

  # ===================== 1版 → NinjaSlayerEx（9 张，逐条对齐计划 §5 清单）===
  { ja: "wasshoiエントリー_1", kind: :nsl1ex, key: "WS", status: :planned,
    note: "1版 Wasshoi!エントリー（1d6）。上游 NinjaSlayer（1版）只有 NJ/EV/AT/EL + SB 五条命令，" \
          "**无 WS** → 真正的新增表" },
  { ja: "ジツ拡張サイバネ暴走_1", kind: :nsl1ex, key: "JITSB", status: :planned,
    note: "1版 ジツ拡張サイバネ暴走（data 1..7；源码 dice 映射含 10 个骰型别名：1d/1d6/d+1/1d6+1 等）" },
  { ja: "暗黒カラテ衝動_1", kind: :nsl1ex, key: "DKKI", status: :planned,
    note: "1版 暗黒カラテ衝動（1d6，6 条；第 5、6 条同文）" },
  { ja: "カルマロンダリング_1", kind: :nsl1ex, key: "KRM", status: :planned,
    note: "1版 カルマロンダリング（data 1..12；源码 dice 映射含 13 个骰型别名，c=2d6）" },
  { ja: "サイバネ狂気判定_1", kind: :nsl1ex, key: "CYBER", status: :planned,
    note: "1版 サイバネ狂気判定（2d6，data 2..12 共 11 条）" },
  { ja: "バイオサイバネ狂気判定_1", kind: :nsl1ex, key: "BIOCYBER", status: :planned,
    note: "1版 バイオサイバネ狂気判定（1d6，6 条）" },
  { ja: "ソウル鑑定_1", kind: :nsl1ex, key: "SOUL", status: :planned,
    note: "1版 ソウル鑑定（1d6，6 条；1↔2、3↔4、5↔6 成对同文）" },
  { ja: "ソーマトリコール_1", kind: :nsl1ex, key: "SUMMON", status: :planned,
    note: "1版 ソーマトリコール（2d6，data 2..12 共 11 条）" },
  { ja: "生い立ち_1", kind: :nsl1ex, key: "BK", status: :planned,
    note: "1版 ネオサイタマ生い立ち d36（36 条）" },

  # ===================== 待裁决（4 张：上游 BCDice 已有同源表）===============
  # 事实依据（scripts/_crosscheck_tables.mjs 实测，详见 docs/t1.2-coverage-audit.md §2）：
  #   天狗[サツバツ]            vs 上游 NinjaSlayer2.table.SATSUBATSU → 正文同源，天狗多一层「加粗效果摘要标题」+ markdown 化 + 换行重排
  #   天狗[wasshoiエントリー]  vs 上游 NinjaSlayer2.table.WASSHOI     → 同上（且**条目顺序不同**：天狗把「KRAAAAASH」排在第 3 项）
  #   天狗[nrs発狂]             vs 上游 NinjaSlayer2.table.NRS         → 正文同源，天狗多摘要标题
  #   天狗[サツバツ_1]          vs 上游 NinjaSlayer.SATSUBATSU_TABLE   → 归一化后 6/6 **完全同源**，纯重复
  { ja: "サツバツ", kind: nil, key: nil, status: :pending_arb,
    note: "**待裁决**。上游 BCDice NinjaSlayer2.table.SATSUBATSU 已覆盖同表（正文同源），天狗版多一层 " \
          "『**痛烈な一撃**：『痛打+1』、『弾き飛ばし』』式**加粗效果摘要标题** + `「…」`→`**…**：` markdown 化 + 换行重排。" \
          "三种处置待用户选：(A) 不搬——继承上游 SB 即可，丢失天狗的摘要标题；(B) 搬进 NinjaSlayer2Ex 但用**不同 ASCII 键**（如 SBT）" \
          "让 Ex 侧 `/SB` 仍走父类，天狗风格表走新键；(C) 搬进 NinjaSlayerEx 与 1版 SB 同键空间。" },
  { ja: "wasshoiエントリー", kind: nil, key: nil, status: :pending_arb,
    note: "**待裁决**。同 サツ巴ツ：上游 NinjaSlayer2.table.WASSHOI 已覆盖。天狗版除摘要标题外还有" \
          "**条目顺序差异**（天狗第 3 项 =「KRAAAAASH 窓を突き破り出現！」，上游第 5 项才是它），" \
          "不是纯呈现差异 → 顺序语义差异须用户裁决。" },
  { ja: "nrs発狂", kind: nil, key: nil, status: :pending_arb,
    note: "**待裁决**。上游 BCDice NinjaSlayer2.table.NRS 已覆盖（type 1D7，7 条，正文同源），天狗版多摘要标题。" \
          "计划 §5 只把「NSRS発狂」列为 BCDice 缺失项（已按 :nsl2ex/NSRS 搬入），**未提 nrs発狂** → 默认不搬。" },
  { ja: "サツバツ_1", kind: nil, key: nil, status: :pending_arb,
    note: "**待裁决**。与上游 1版 NinjaSlayer 内联 SATSUBATSU_TABLE 归一化后 6/6 **完全同源**（纯 markdown/全角呈现差异），" \
          "而 1版 NinjaSlayer 已有 SB 命令 → 纯重复。计划 §5 的「1版 9 表」清单里也是 wasshoi_1 而**非** サツバツ_1，" \
          "与本实测一致。建议不搬（见 docs/t1.2-naming-proposal.md §A2）。" },
].freeze

# ---------------------------------------------------------------------------
# 2. type（D 表达式）推导 —— 以天狗**默认骰型 dice['a']** 为准
#
#    天狗默认路径：`diceKind = temp[1] ? temp[1] : "a"`（SearchTableDiceroll.checkTable），
#    不给 ,<快捷键> 时走 a。故 yml 的 type 必须 = a 骰型，这样
#    `DiceTable::Table#roll` 在默认路径下索引正确。
#
#    ⚠ 索引偏移规则（**天狗与 BCDice 不同**，T1.3~T1.7 命令层必须对齐）：
#       天狗：NJDiscordReply.addTableOutput → `data[diceroll.sumall]`（**绝对出目**索引）
#       BCDice：DiceTable::Table#choice → `items[value - @times]`（**相对**索引）
#       → 2d6 类表（data 2..12）两者恰好一致（offset 2 == times 2）；
#         但 `1d6+1` 类表（出目 2..7）在天狗是 data[2] = items[0]，
#         BCDice 1D6 则会 items[value-1] → **错位**。
#       故多骰型表（含 +1 的骰型）**不能**直接用 Table.from_i18n，
#       必须由命令层按上表 ledger 的 per-dice 偏移分发。
#
#    type 表达式转换：'1d6' → '1D6'；'1d6+1' 去掉 +1 后的基础型单独登记在 ledger。
# ---------------------------------------------------------------------------

# '1d3+x' / '1d6+1' / '2d6' / 'd3+3' → BCDice 'nDs' 基础型（+N / +x 是命令层偏移，不进 type）
def to_bcdice_type(expr)
  m = expr.to_s.match(/(\d*)[dD](\d+)/)
  raise ArgumentError, "无法解析骰型: #{expr.inspect}" unless m

  "#{m[1].empty? ? 1 : m[1]}D#{m[2]}"
end

# 每骰型的出目偏移（min）与可达范围，供命令层索引分发
def dice_offsets(dice)
  dice.map do |k, expr|
    m = expr.to_s.match(/(\d*)d(\d+)([+-]\d+|x)?/i)
    next unless m

    times = m[1].empty? ? 1 : m[1].to_i
    sides = m[2].to_i
    off = m[3].to_s.sub(/x\z/, "").to_i
    [k, expr, "#{times}d#{sides}", times * 1 + off, times * sides + off]
  end.compact.map { |k, expr, base, lo, hi| { "key" => k, "expr" => expr, "base" => base, "min_sum" => lo, "max_sum" => hi, "items_offset" => lo - times_for(base) } }
end

def times_for(base)
  base[/\A(\d*)[dD]/, 1].to_s.empty? ? 1 : base[/\A(\d*)[dD]/, 1].to_i
end

# ---------------------------------------------------------------------------
# 3. 读取既有 yml（dummy 表保留）
# ---------------------------------------------------------------------------
def load_existing(path)
  return { "table" => {} } unless File.exist?(path)

  doc = YAML.load_file(path, aliases: true)
  (doc.dig("ja_jp") || {}).each_value { |ns| return ns if ns.is_a?(Hash) }
  { "table" => {} }
end

nsl2ex = load_existing(OUT_NSL2EX)
nsl1ex = load_existing(OUT_NSLEX)
nsl2ex["table"] ||= {}
nsl1ex["table"] ||= {}

# ---------------------------------------------------------------------------
# 4. 逐表生成
# ---------------------------------------------------------------------------
ledger = []
stats = { nsl2ex: 0, nsl1ex: 0, pending_arb: 0 }
errors = []
already = []

MAPPING.each do |m|
  src = data["tables"][m[:ja]]
  if src.nil?
    errors << "映射表 #{m[:ja]} 在 JSON 中不存在（源表缺失）"
    next
  end

  idx = src["data_index"].map(&:to_i)
  min_idx = idx.min
  max_idx = idx.max
  anchor = src["anchor"]
  anchor_desc = anchor ? "#{anchor['file']}:#{anchor['start_line']}-#{anchor['end_line']}" : "?"
  dice_desc = src["dice"].map { |k, v| "#{k}=#{v}" }.join(" ")
  dr = src["datarange"]
  multi_dice = src["dice"].keys.length > 1

  if m[:status] == :pending_arb
    stats[:pending_arb] += 1
    ledger << {
      "ja_name" => m[:ja], "ascii_key" => nil, "target_file" => nil, "namespace" => nil,
      "status" => "待裁决",
      "item_count" => src["items"].length, "char_count" => src["total_chars"],
      "dice" => src["dice"], "datarange" => dr,
      "data_index" => src["data_index"], "min_index" => min_idx, "max_index" => max_idx,
      "index_rule" => "天狗原文 data[出目]（绝对索引）；BCDice items[出目-#{min_idx}] → 偏移恒为 #{min_idx}（T1.3~T1.7 命令层须对齐）",
      "json_path" => "$.tables[#{m[:ja].inspect}]", "source_anchor" => anchor_desc,
      "note" => m[:note],
    }
    next
  end

  ns = m[:kind] == :nsl1ex ? nsl1ex : nsl2ex
  key = m[:key]
  type = to_bcdice_type(src["dice"]["a"] || src["dice"].values.first)
  existing = ns["table"][key]
  if existing && existing["items"] != src["items"]
    already << "⚠ 键 #{key} 已存在且内容不同，**未覆盖**（请人工裁决）"
    next
  end

  name = "#{m[:ja]}(#{type}) ＞ "
  ns["table"][key] = { "name" => name, "type" => type, "items" => src["items"].dup }
  stats[m[:kind]] += 1

  ledger << {
    "ja_name" => m[:ja], "ascii_key" => key,
    "target_file" => m[:kind] == :nsl1ex ? "i18n/NinjaSlayerEx/ja_jp.yml" : "i18n/NinjaSlayer2Ex/ja_jp.yml",
    "namespace" => m[:kind] == :nsl1ex ? "NinjaSlayerEx" : "NinjaSlayer2Ex",
    "status" => "已映射",
    "item_count" => src["items"].length, "char_count" => src["total_chars"],
    "dice" => src["dice"], "datarange" => dr,
    "data_index" => src["data_index"], "min_index" => min_idx, "max_index" => max_idx,
    "index_rule" => "天狗 data[出目]（绝对）→ BCDice items[出目-#{min_idx}]；偏移恒为 #{min_idx}",
    "dice_offsets" => dice_offsets(src["dice"]),
    "roll_note" => multi_dice ? "多骰型表：type 只表达默认骰型 a；,b/,c/,d 与 +x 補正由命令层分发（datarange 钳制）" : "单骰型表：type 与 data_index 全域一致，Table.from_i18n 可直接用",
    "yml_type" => type, "yml_name" => name,
    "multi_dice" => multi_dice,
    "json_path" => "$.tables[#{m[:ja].inspect}]", "source_anchor" => anchor_desc,
    "note" => m[:note],
  }
end

# 源里未被 MAPPING 覆盖的表（兜底对账，零信息损失铁律）
uncovered = data["tables"].keys - MAPPING.map { |m| m[:ja] }

# ---------------------------------------------------------------------------
# 5. 写盘（YAML.dump —— 铁律：禁止手工拼 YAML）
# ---------------------------------------------------------------------------
def dump_yaml(namespace, tables, path, ledger_rows)
  doc = { "ja_jp" => { namespace => { "table" => tables } } }
  body = YAML.dump(doc)
  keys = tables.keys.join(", ")
  header = <<~HEADER
    # ============================================================================
    # #{namespace} 日本語 i18n 表 —— T1.2 数据管线**草稿**（待逐表人工复核签收）
    #
    # 本文件由 `bundle exec ruby scripts/json_to_i18n.rb` **机器生成**（Ruby psych YAML.dump），
    # 请勿手工编辑（改数据请改 scripts/extract_tengu_data.mjs / json_to_i18n.rb 后重跑），
    # 手工改动会被逐字回读自检判红。
    #
    # 源数据：references/extracted/tengu_tables.json
    #         ← node scripts/extract_tengu_data.mjs 直接 require 钉版快照
    #           TenguDiceBot@ca3d85a (v4.2.1) 的 nd_datatable.js / nd_datatext.js
    #
    # 生成时间：#{Time.now.strftime('%Y-%m-%d %H:%M:%S')}
    # 本命名空间表键：#{keys}
    # 键名约定：纯 ASCII（计划 §13 第 2 项）；日文原表名见
    #          references/extracted/i18n_key_ledger.yml 与 docs/t1.2-naming-proposal.md
    # 复核状态：见 docs/t1.2-review-checklist.md（逐表 pending）
    # ============================================================================

  HEADER
  File.write(path, header + body, encoding: "UTF-8")
  ledger_rows
end

unless options[:dry_run]
  dump_yaml("NinjaSlayer2Ex", nsl2ex["table"], OUT_NSL2EX, ledger)
  dump_yaml("NinjaSlayerEx", nsl1ex["table"], OUT_NSLEX, ledger)
  File.write(LEDGER_PATH, YAML.dump({
    "generated_at" => Time.now.strftime("%Y-%m-%d %H:%M:%S"),
    "source_json" => "references/extracted/tengu_tables.json",
    "source_commit" => data["_meta"]["source_commit"],
    "counts" => { "已映射" => stats[:nsl2ex] + stats[:nsl1ex], "待裁决" => stats[:pending_arb] },
    "entries" => ledger,
  }, line_width: -1), encoding: "UTF-8")
end

# ---------------------------------------------------------------------------
# 6. 自检：逐字回读校验（铁律——生成后必须逐字比对 JSON 与 yml）
# ---------------------------------------------------------------------------
selfcheck = { checked: 0, mismatched: [] }
unless options[:dry_run]
  { "i18n/NinjaSlayer2Ex/ja_jp.yml" => :nsl2ex, "i18n/NinjaSlayerEx/ja_jp.yml" => :nsl1ex }.each do |rel, kind|
    reread = YAML.load_file(File.join(ROOT, rel), aliases: true)
    ns_doc = (reread["ja_jp"] || {}).values.find { |v| v.is_a?(Hash) } || {}
    tables = ns_doc["table"] || {}
    MAPPING.each do |m|
      next unless m[:kind] == kind && m[:status] == :planned

      src = data["tables"][m[:ja]]
      got = tables[m[:key]]
      selfcheck[:checked] += 1
      if got.nil?
        selfcheck[:mismatched] << "#{m[:ja]} → #{rel}:#{m[:key]} 缺失"
        next
      end
      selfcheck[:mismatched] << "#{m[:ja]} → #{m[:key]} items 逐字不一致" if got["items"] != src["items"]
      idx = src["data_index"].map(&:to_i)
      want_type = to_bcdice_type(src["dice"]["a"] || src["dice"].values.first)
      selfcheck[:mismatched] << "#{m[:ja]} → #{m[:key]} type 应为 #{want_type} 实为 #{got['type']}" if got["type"] != want_type
      selfcheck[:mismatched] << "#{m[:ja]} → #{m[:key]} name 不一致" if got["name"] != "#{m[:ja]}(#{want_type}) ＞ "
    end
  end
end

# ---------------------------------------------------------------------------
# 7. 报告
# ---------------------------------------------------------------------------
puts "[json_to_i18n] 2版 NinjaSlayer2Ex 表：#{stats[:nsl2ex]} 张"
puts "[json_to_i18n] 1版 NinjaSlayerEx  表：#{stats[:nsl1ex]} 张"
puts "[json_to_i18n] 待裁决：#{stats[:pending_arb]} 张（未写 yml，见 docs/t1.2-naming-proposal.md §A）"
puts "[json_to_i18n] 映射未覆盖的源表：#{uncovered.empty? ? '无' : uncovered.inspect}"
already.each { |w| puts "[json_to_i18n] #{w}" }
puts "[json_to_i18n] 台账：#{options[:dry_run] ? '(dry-run，未写盘)' : LEDGER_PATH.sub("#{ROOT}/", '')}"

if errors.any?
  errors.each { |e| puts "[json_to_i18n] ❌ #{e}" }
  exit 1
end
if selfcheck[:mismatched].any?
  puts "[json_to_i18n] ❌ 逐字回读自检失败（#{selfcheck[:checked]} 张表）："
  selfcheck[:mismatched].each { |m| puts "  - #{m}" }
  exit 1
end
unless options[:dry_run]
  puts "[json_to_i18n] ✅ 逐字回读自检通过：#{selfcheck[:checked]} 张表 items/name/type 与 JSON 源逐字一致"
end
