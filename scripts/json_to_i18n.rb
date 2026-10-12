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
require_relative "text_rewrite"

ROOT = File.expand_path("..", __dir__)

# references/src/ 是 gitignore 的上游钉版快照——新克隆里没有它（2026-10-12 三审）
unless File.directory?(File.join(ROOT, "references/src"))
  abort("缺少 references/src/ 上游钉版快照（不入库）。请先按 docs/REFERENCES.md 顶部流程重取快照再运行本脚本。")
end

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
# ---------------------------------------------------------------------------
# 1.5 表文本改写（2026-10-11 用户拍板方案 B + C）
#
# 映射已迁移到共享模块 scripts/text_rewrite.rb（本脚本与 gen_table_toml.rb
# 三方校验共用同一副本，消除重复维护风险）。拍板内容：
#   B：表文本内嵌命令引用 ASCII 化（`/nd NSRS発狂,d`→`NSRS_D` 等 2 处）
#   C：Discord 表情码 `:japanese_goblin:` 删除（Telegram 上只显示为裸文字）
# 纪律：JSON 锚点保持逐字节保真不动；改写只在生成期发生；自检按 transform(JSON) 比对。
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# 1.6 判定文案（SEISEN）—— 非表文本，走 yml 的 `judge` 段（T1.5 新增）
#
#    天狗的聖戦判定文案硬编码在 tengu_dice/wasshoi.js:5-6 / 51-62 的 KIND 常量里，
#    不在 nd_datatable.js 的表数据中，故 json_to_i18n 的逐表映射覆盖不到它。
#    铁律同上：日文文案逐字来自 JSON（extract_tengu_data.mjs 的 $.wasshoi 段），
#    Ruby 侧只搬运不重写，生成物仍可逐字回读自检。
#
#    产出键：NinjaSlayer2Ex.judge.SEISEN.{judge_name,success_message,failure_word}
#            NinjaSlayer2Ex.judge.SEISEN.{dice_expression,comparison}
# ---------------------------------------------------------------------------
def build_judge_section(json_data, namespace)
  w = json_data["wasshoi"]
  abort "[json_to_i18n] JSON 缺 wasshoi 段（先跑 node scripts/extract_tengu_data.mjs）" if w.nil?

  seisen = w.dig("kinds", "SEISEN")
  abort "[json_to_i18n] JSON 的 wasshoi.kinds 缺 SEISEN" if seisen.nil?

  {
    "dice_expression" => w["dice_expression"],
    "comparison" => w["comparison"],
    "SEISEN" => {
      "judge_name" => rewrite_text(seisen["judge_name"]),
      "success_word" => w["success_word"],
      "success_message" => rewrite_text(seisen["success_message"]),
      "failure_word" => w["failure_word"]
    }.freeze,
    # T1.6：追加判定扩展（倍率 / 记忆符）的标签与倍率上界。
    # 逐字来源 = $.shortcut.appendix[] 的 expands_to（"3d6>=4[=1/ジツ暴走]" 形式），
    # 标签取 `/` 之后的注释段；倍率上界是**本扩展自定的安全上界**（天狗无上界），
    # 不是天狗数据，故单独登记在 appendix_bairitsu_max 而不混进逐字搬运段。
    "APPENDIX_EX" => build_appendix_ex_section(json_data)
  }.freeze
end

# ---------------------------------------------------------------------------
# 1.7 追加判定扩展段（T1.6 新增）—— 倍率 + 记忆符
#
#    天狗的 appendix 语义散在两处真函数里：
#      - tengu_dice/NJShortcutTranslator.js:124 appTransration（记忆符 → "=y/标签"）
#      - classes/Appendix.js:19            bairitsu（倍率 → Number(strArray[4])，默认 1）
#    两者都不在 nd_datatable.js 的表数据中，逐表映射覆盖不到，故走独立段，
#    与 1.6 的 judge 段同思路：从 JSON（extract_tengu_data.mjs 的 $.shortcut 段）
#    逐字搬运，Ruby 侧只解析不重写。
#
#    产出键：
#      NinjaSlayer2Ex.judge.APPENDIX_EX.J.label    # "ジツ暴走"     ← =1 的注释段
#      NinjaSlayer2Ex.judge.APPENDIX_EX.L.label    # "LAN直結出目6数" ← =6 的注释段
#      NinjaSlayer2Ex.judge.APPENDIX_EX.op_labels  # { "=" => "=" } … 天狗 option→显示符号
#      NinjaSlayer2Ex.judge.APPENDIX_EX.bairitsu_max # Integer，本扩展自定上界
#
#    注意 `[C]`（コッポ判定 =4）**不在**本段内：计划 §5 拍板不搬
#    （BCDice 上游 `[C]` 已是 クリティカル判定，同名不同义 → 保留上游语义），
#    コッポ改用 `[=4]`。此点由 i18n_guard / 结构守卫共同钉死（见 §5 报告）。
# ---------------------------------------------------------------------------
def build_appendix_ex_section(json_data)
  apps = json_data.dig("shortcut", "appendix")
  abort "[json_to_i18n] JSON 缺 shortcut.appendix 段（先跑 node scripts/extract_tengu_data.mjs）" if apps.nil?

  by_key = apps.to_h { |a| [a["key"], a] }

  # 逐字从 `expands_to` 的 `/` 之后取标签。形如
  # `3d6>=4[=1/ジツ暴走]` / `3d6>=4[>=5/サツバツ！]` / `3d6>=4[=4/コッポ判定]`。
  # 用正则解析而非 split('/')：标签里理论上可含 `/`，split 会截断成数组。
  # 前缀用宽松形态 `\d+d\d+…` 而非写死 `3d6>=4`——后者是天狗**说明书示例**的写法，
  # 而 expands_to 是真函数展开物，改了写法就 abort 太脆。
  def label_of(entry, key)
    # 追加判定段内形如 `[=1/…]`、`[>=5/…]`、`[=6/…]`：`[<>!]` 可缺省（`=`），
    # `=` 可缺省（`>` `<` `!`），两者组合覆盖 = / >= / <= / != / > / < / ==。
    m = /\A\d+d\d+(?:[<>!]=?|=)\d+\[[<>!]?=(\d+)\/(.+)\]\z/.match(entry["expands_to"])
    abort "[json_to_i18n] shortcut.appendix[#{key}] 的 expands_to 形态不在预期内：#{entry['expands_to'].inspect}" if m.nil?

    m[2]
  end

  # 追加判定段的 border（同上形态），用于把「记忆符 → 出目数」钉成数据而非代码常量。
  def border_of(entry, key)
    m = /\A\d+d\d+(?:[<>!]=?|=)\d+\[[<>!]?=(\d+)\/.+\]\z/.match(entry["expands_to"])
    abort "[json_to_i18n] shortcut.appendix[#{key}] 的 expands_to 形态不在预期内：#{entry['expands_to'].inspect}" if m.nil?

    m[1].to_i
  end

  {
    # 天狗 option 的显示符号：=  在 Appendix.js 里被规范成 '=='，输出前 replace(/==/g,'=')
    # → 统一按 '=' 显示；其余原样。
    "op_labels" => {
      "==" => "=",
      ">=" => ">=",
      ">" => ">",
      "<=" => "<=",
      "<" => "<",
      "!=" => "!="
    }.freeze,
    "J" => {
      "border" => border_of(by_key.fetch("j"), "j"),
      "label" => rewrite_text(label_of(by_key.fetch("j"), "j"))
    }.freeze,
    "L" => {
      "border" => border_of(by_key.fetch("l"), "l"),
      "label" => rewrite_text(label_of(by_key.fetch("l"), "l"))
    }.freeze,
    # 天狗 Appendix.js:19 `bairitsu = (strArray[4] != null && !isNaN(strArray[4])) ? Number(strArray[4]) : 1`
    # → 无上界（`[>=5*999999]` 合法）。本扩展把「任意大倍率并入文字输出」当
    # 误输入风险（玩家手滑打长数字会得到一个天文数字的伪计数），
    # 故自定上界：超过即整条命令不响应。**这是有意偏离天狗的**，报告 §5 申报。
    "bairitsu_max" => 100
  }.freeze
end

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

  # ===================== 待裁决 → 已定案（2026-10-11 用户拍板）===============
  # 事实依据（主 agent 复核版，详见 docs/t1.2-coverage-audit.md §2.3 更正留档）：
  #   天狗[サツバツ/wasshoiエントリー/nrs発狂] vs 上游 2版同名表 → 正文同源且**出目同序**，
  #     差异仅天狗多 markdown 加粗摘要标题（初版"顺序冲突"系比对器 bug 误报，已证伪）
  #   天狗[サツバツ_1] vs 上游 1版内联 SATSUBATSU_TABLE → 同序同内容（仅全角数字呈现差）
  # 拍板 D1-A1=B：2版两张以新键 SBX/WSX 搬入（保留天狗摘要标题呈现）；
  # 拍板 D1-A2/A3：nrs発狂 / サツバツ_1 不搬，类似功能合并入既有上游命令（NRS / SB）。
  { ja: "サツバツ", kind: :nsl2ex, key: "SBX", status: :planned,
    note: "2版 サツバツ 天狗呈现版（含加粗摘要标题，与上游 SATSUBATSU 正文同源同序）。" \
          "父类 SB 走上游纯文本版，SBX 走天狗版——并存是拍板结论（D1-A1=B）。" },
  { ja: "wasshoiエントリー", kind: :nsl2ex, key: "WSX", status: :planned,
    note: "2版 wasshoiエントリー 天狗呈现版（含加粗摘要标题，与上游 WASSHOI 正文同源同序）。" \
          "父类 WSE 走上游版，WSX 走天狗版（D1-A1=B）。" },
  { ja: "nrs発狂", kind: nil, key: nil, status: :excluded,
    note: "不搬（拍板 D1-A3）：上游 NinjaSlayer2.table.NRS 已覆盖（正文同源、7/7 同序），" \
          "类似功能合并入既有 NRS 命令。NSRS 侧缺失已由 NSRS 键补齐。" },
  { ja: "サツバツ_1", kind: nil, key: nil, status: :excluded,
    note: "不搬（拍板 D1-A2）：与上游 1版内联 SATSUBATSU_TABLE 同序同内容（仅全角数字呈现差），" \
          "类似功能合并入既有 1版 SB 命令。" },
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

# 每骰型的自然出目范围（参考信息）。
# ⚠ 索引一律用**表级 min_index**（ledger.index_rule），不存在"每骰型偏移"：
#    天狗语义是单一绝对键表 data[sumall]，yml 摊平为 0 基数组后
#    查表恒为 items[clamp(sum) - min_index]。含 +N 的骰型（如 1d6+1）其天然
#    下限 2 高于表下限 1，若按"每骰型偏移"索引必错位（kimi P1 的初版公式
#    与建议修正 per-dice lo 均被数据证伪：data_index 实测含低于骰型下限的键）。
def dice_ranges(dice)
  dice.map do |k, expr|
    m = expr.to_s.match(/(\d*)d(\d+)([+-]\d+|x)?/i)
    next unless m

    times = m[1].empty? ? 1 : m[1].to_i
    sides = m[2].to_i
    off = m[3].to_s.sub(/x\z/, "").to_i
    { "key" => k, "expr" => expr, "base" => "#{times}d#{sides}", "min_sum" => times + off, "max_sum" => times * sides + off }
  end.compact
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
# T1.5：判定文案段（SEISEN）挂在 2版命名空间的 `judge` 下，与 `table` 平级。
# load_existing 返回的是既有命名空间 Hash，重跑时直接覆盖（内容源自 JSON，幂等）。
nsl2ex["judge"] = build_judge_section(data, "NinjaSlayer2Ex")

# ---------------------------------------------------------------------------
# 4. 逐表生成
# ---------------------------------------------------------------------------
ledger = []
stats = { nsl2ex: 0, nsl1ex: 0, pending_arb: 0, excluded: 0, diverged: 0 }
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

  if m[:status] == :pending_arb || m[:status] == :excluded
    stats[m[:status]] += 1
    ledger << {
      "ja_name" => m[:ja], "ascii_key" => nil, "target_file" => nil, "namespace" => nil,
      "status" => (m[:status] == :excluded ? "不搬（合并上游）" : "待裁决"),
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
  # ⚠ 比对对象必须是 **rewrite 后的** items，不是 JSON 原文（T1.5 修正）：
  #   T1.3 引入 TEXT_REWRITE（表文本内嵌命令引用 ASCII 化）后，yml 里存的是
  #   rewrite_items(src["items"])，而本守卫仍拿它与 src["items"]（原文）比——
  #   凡命中改写的表（NSRS 的 `NSRS_D`、NJI 的 `NJI@n`）恒被判「内容不同」，
  #   于是 `next` 跳过写表，**且该表的 ledger 条目被静默丢弃**
  #   （T1.5 实测：重跑生成器后 ledger 从 25 条掉到 23 条，NSRS/NJI 消失）。
  #   对齐 §6 逐字回读自检的写法（那里比的就是 rewrite_items(...)）。
  if existing && (existing["items"] != rewrite_items(src["items"]) ||
                  existing["type"] != type || existing["name"] != "#{m[:ja]}(#{type}) ＞ ")
    already << "⚠ 键 #{key} 已存在且内容不同，**未覆盖**（请人工裁决）"
    # kimi P4：跳过分支也必须登记 ledger（否则合法分歧时台账静默缺行——
    # 与 T1.5 修掉的「rewrite 比对」缺陷同型）；并补 name/type 比对。
    stats[:diverged] += 1
    ledger << {
      "ja_name" => m[:ja], "ascii_key" => key,
      "target_file" => m[:kind] == :nsl1ex ? "i18n/NinjaSlayerEx/ja_jp.yml" : "i18n/NinjaSlayer2Ex/ja_jp.yml",
      "namespace" => m[:kind] == :nsl1ex ? "NinjaSlayerEx" : "NinjaSlayer2Ex",
      "status" => "分歧待人工（yml 未覆盖）",
      "item_count" => src["items"].length, "char_count" => src["total_chars"],
      "dice" => src["dice"], "datarange" => dr,
      "data_index" => src["data_index"], "min_index" => min_idx, "max_index" => max_idx,
      "json_path" => "$.tables[#{m[:ja].inspect}]", "source_anchor" => anchor_desc,
      "note" => m[:note],
    }
    next
  end

  name = "#{m[:ja]}(#{type}) ＞ "
  ns["table"][key] = { "name" => name, "type" => type, "items" => rewrite_items(src["items"]) }
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
    "dice_ranges" => dice_ranges(src["dice"]),
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
def dump_yaml(namespace, tables, path, ledger_rows, extra_sections = {})
  doc = { "ja_jp" => { namespace => { "table" => tables }.merge(extra_sections) } }
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
    #         （产物不含时间戳——全管线逐字节幂等，重跑 md5 不变即未被手工改动）
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
  dump_yaml("NinjaSlayer2Ex", nsl2ex["table"], OUT_NSL2EX, ledger, { "judge" => nsl2ex["judge"] })
  dump_yaml("NinjaSlayerEx", nsl1ex["table"], OUT_NSLEX, ledger)
  File.write(LEDGER_PATH, YAML.dump({
    "source_json" => "references/extracted/tengu_tables.json",
    "source_commit" => data["_meta"]["source_commit"],
    "counts" => { "已映射" => stats[:nsl2ex] + stats[:nsl1ex], "待裁决" => stats[:pending_arb], "不搬" => stats[:excluded] },
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
      selfcheck[:mismatched] << "#{m[:ja]} → #{m[:key]} items 逐字不一致" if got["items"] != rewrite_items(src["items"])
      idx = src["data_index"].map(&:to_i)
      want_type = to_bcdice_type(src["dice"]["a"] || src["dice"].values.first)
      selfcheck[:mismatched] << "#{m[:ja]} → #{m[:key]} type 应为 #{want_type} 实为 #{got['type']}" if got["type"] != want_type
      selfcheck[:mismatched] << "#{m[:ja]} → #{m[:key]} name 不一致" if got["name"] != "#{m[:ja]}(#{want_type}) ＞ "
      # 索引语义不变量（kimi P1 落地）：items 数 == data_index 跨度（连续区间），
      # 否则命令层 items[clamp(sum) - min_index] 会错位
      idxs = src["data_index"].map(&:to_i)
      if got["items"].length != idxs.max - idxs.min + 1
        selfcheck[:mismatched] << "#{m[:ja]} → #{m[:key]} items 数(#{got['items'].length}) 与 data_index 跨度(#{idxs.min}..#{idxs.max}) 不符"
      end
    end
  end

  # T1.5：SEISEN 判定文案逐字回读（表外文案同样受铁律约束）
  reread = YAML.load_file(File.join(ROOT, "i18n/NinjaSlayer2Ex/ja_jp.yml"), aliases: true)
  got_judge = ((reread["ja_jp"] || {}).values.find { |v| v.is_a?(Hash) } || {})["judge"]
  want_judge = build_judge_section(data, "NinjaSlayer2Ex")
  selfcheck[:checked] += 1
  if got_judge.nil?
    selfcheck[:mismatched] << "NinjaSlayer2Ex.judge 段缺失（SEISEN 文案）"
  else
    %w[dice_expression comparison].each do |k|
      selfcheck[:mismatched] << "judge.#{k} 逐字不一致" if got_judge[k] != want_judge[k]
    end
    %w[judge_name success_word success_message failure_word].each do |k|
      selfcheck[:mismatched] << "judge.SEISEN.#{k} 逐字不一致" if got_judge.dig("SEISEN", k) != want_judge.dig("SEISEN", k)
    end
    # T1.6：APPENDIX_EX 段（倍率 / 记忆符标签）逐字回读
    selfcheck[:checked] += 1
    got_ap = got_judge["APPENDIX_EX"]
    want_ap = want_judge["APPENDIX_EX"]
    if got_ap.nil?
      selfcheck[:mismatched] << "judge.APPENDIX_EX 段缺失（T1.6 倍率 / 记忆符）"
    else
      %w[J L].each do |k|
        %w[border label].each do |f|
          selfcheck[:mismatched] << "judge.APPENDIX_EX.#{k}.#{f} 逐字不一致" if got_ap.dig(k, f) != want_ap.dig(k, f)
        end
      end
      selfcheck[:mismatched] << "judge.APPENDIX_EX.op_labels 逐字不一致" if got_ap["op_labels"] != want_ap["op_labels"]
      selfcheck[:mismatched] << "judge.APPENDIX_EX.bairitsu_max 逐字不一致" if got_ap["bairitsu_max"] != want_ap["bairitsu_max"]
    end
  end
end

# ---------------------------------------------------------------------------
# 7. 报告
# ---------------------------------------------------------------------------
puts "[json_to_i18n] 2版 NinjaSlayer2Ex 表：#{stats[:nsl2ex]} 张"
puts "[json_to_i18n] 1版 NinjaSlayerEx  表：#{stats[:nsl1ex]} 张"
puts "[json_to_i18n] 待裁决：#{stats[:pending_arb]} 张（未写 yml，见 docs/t1.2-naming-proposal.md §A）"
puts "[json_to_i18n] 不搬（合并上游）：#{stats[:excluded]} 张"
puts "[json_to_i18n] 分歧未覆盖：#{stats[:diverged]} 张" if stats[:diverged] > 0
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
