#!/usr/bin/env ruby
# frozen_string_literal: true

# ============================================================================
# 通用 toml 确定性用例生成器（T1.4 入库）
#
# 目的：
#   test/data/*.toml 里的 `output` 是**逐字断言**（runner 不做归一化），
#   手工抄录表文本必红。T1.3 头注已承诺本任务把它入库。
#   本脚本读 ledger（references/extracted/i18n_key_ledger.yml）+ i18n yml，
#   对指定表按「骰型 ×（min / min+1 / 典型 / max / max+1 钳制 / 负 x）」
#   组合机械生成用例，**output 从真实 eval 采集**——生成即事实，不手抄。
#
# 设计（幂等是硬指标）：
#   1. **删旧块再写新块**：每张表的自有用例放在 `# >>> BEGIN GENERATED: <键>`
#      / `# <<< END GENERATED: <键>` 哨兵之间；重跑时整块替换，
#      人手写的用例（哨兵外）逐字保留 → 连跑两次 md5 必同（幂等）。
#   2. **output 真实采集**：用 test/randomizer_mock.rb 的固定骰序驱动
#      真实 BCDice eval，取 result.text 逐字写入——不是拼字符串。
#   3. **ledger ↔ 代码 ↔ yml 三方交叉校验**（§4）：任何一处不一致
#      直接 abort，绝不生成「看着绿其实语义漂移」的用例。
#   4. **哨兵外的用例不受影响**：本脚本只管自己的哨兵块。
#
# 跑法：
#   bundle exec ruby scripts/gen_table_toml.rb                 # 生成 T1.4 全量
#   bundle exec ruby scripts/gen_table_toml.rb --tables KRS,KRO # 只生成指定表
#   bundle exec ruby scripts/gen_table_toml.rb --check         # 只校验不写盘
#   bundle exec ruby scripts/gen_table_toml.rb --target-file test/data/NinjaSlayer2Ex.toml
#
# 幂等自证（验收项）：
#   bundle exec ruby scripts/gen_table_toml.rb && md5sum test/data/NinjaSlayer2Ex.toml
#   bundle exec ruby scripts/gen_table_toml.rb && md5sum test/data/NinjaSlayer2Ex.toml
#   两次 md5 必须相同。
# ============================================================================

require "yaml"
require "json"
require "optparse"
require "fileutils"
require_relative "text_rewrite" # 声明式文本改写（拍板 B/C 映射的唯一副本）

ROOT = File.expand_path("..", __dir__)
LEDGER_PATH = File.join(ROOT, "references/extracted/i18n_key_ledger.yml")
I18N_DIR = File.join(ROOT, "i18n")
GAME_SYSTEMS_DIR = File.join(ROOT, "game_systems")
DEFAULT_TARGET = File.join(ROOT, "test/data/NinjaSlayer2Ex.toml")

# T1.4 的 5 张カルマロンダリング表（ledger ascii_key）。顺序固定 = yml 顺序。
DEFAULT_TABLES = %w[KRS KRZ KRA KRO KRY].freeze

# T1.5 的 6 张キャラメイク表（ledger ascii_key，顺序 = yml 顺序）。
CHARAMAKE_TABLES = %w[NJI NJS NJN NJK NJC NJB].freeze

# T1.7 的 9 张**1版**天狗表（ledger ascii_key，顺序 = yml 顺序）。
#
# ⚠ 本批与前两批是**不同游戏系统**（NinjaSlayerEx ≠ NinjaSlayer2Ex），
#   故 --tables 选中 1版 表时会自动把输出目标切到 test/data/NinjaSlayerEx.toml
#   （否则会把 1版 用例写进 2版 的 toml，runner 会因 game_system 不唯一直接 exit 1）。
EDITION1_TABLES = %w[WS JITSB DKKI KRM CYBER BIOCYBER SOUL SUMMON BK].freeze

# --tables 可选的表全集（T1.4 卡尔马 + T1.5 キャラメイク + T1.7 1版 9 表）。
ALL_TABLES = (DEFAULT_TABLES + CHARAMAKE_TABLES + EDITION1_TABLES).freeze

# 本批表所属的游戏系统 ID（写入每条用例的 game_system 字段）
GAME_SYSTEM_ID = "NinjaSlayer2Ex"

# 1版（T1.7）表的游戏系统 ID 与默认输出文件。
EDITION1_GAME_SYSTEM_ID = "NinjaSlayerEx"
EDITION1_DEFAULT_TARGET = File.join(ROOT, "test/data/NinjaSlayerEx.toml")

options = {
  tables: ALL_TABLES,
  check_only: false,
  target: nil # 留 nil → 主流程按「选中了哪批表」自动决定（见 §7）
}
OptionParser.new do |o|
  o.banner = "用法: bundle exec ruby scripts/gen_table_toml.rb [选项]"
  o.on("--tables K1,K2", "逗号分隔的表 ASCII 键（默认全集：卡尔马 5 + キャラメイク 6 + 1版 9）") { |v| options[:tables] = v.split(",").map(&:strip) }
  o.on("--check", "只做三方交叉校验并预览用例数，不写盘") { options[:check_only] = true }
  o.on("--target-file PATH", "显式指定目标 toml（默认按选中的表自动判定）") { |v| options[:target] = File.expand_path(v) }
end.parse!

# ============================================================================
# 1. 加载 i18n / 扩展类（与 runner test/test_ext_game_system_commands.rb 同一序列）
# ============================================================================
$LOAD_PATH.unshift(File.join(ROOT, "test"))
require "bcdice"
require "bcdice/game_system"
require "bcdice/translate"

I18n.backend.reload! if I18n.backend.respond_to?(:reload!)
I18n.load_path.concat(Dir[File.join(I18N_DIR, "**/*.yml")] - I18n.load_path)
Dir[File.join(GAME_SYSTEMS_DIR, "*.rb")].sort.each { |f| require f }
require "randomizer_mock"

abort "[gen_table_toml] 找不到 #{LEDGER_PATH}" unless File.exist?(LEDGER_PATH)
LEDGER = YAML.load_file(LEDGER_PATH)
KARMAROND_KEYS = DEFAULT_TABLES

def abort_with(msg)
  abort("[gen_table_toml] #{msg}")
end

# ============================================================================
# 2. 语义模型：从扩展类读「代码侧」规格，从 ledger 读「台账侧」规格
#
#    刻意**不**在本脚本里重新抄一份骰型表——两份常量必然漂移。
#    代码侧 = NinjaSlayer2Ex 类的公开常量（引擎行为的唯一真相）；
#    台账侧 = i18n_key_ledger.yml（数据转换层的登记）；
#    §4 做三方交叉校验，任何漂移当场 abort。
# ============================================================================
KLASS = BCDice.game_system_class(GAME_SYSTEM_ID)
abort_with("扩展类 #{GAME_SYSTEM_ID} 未注册") if KLASS.nil?
abort_with("#{KLASS} 缺 KARMAROND_DICE_TYPES") unless KLASS.const_defined?(:KARMAROND_DICE_TYPES)
abort_with("#{KLASS} 缺 KARMAROND_DATARANGE") unless KLASS.const_defined?(:KARMAROND_DATARANGE)
abort_with("#{KLASS} 缺 KARMAROND_TABLE_MIN_INDEX") unless KLASS.const_defined?(:KARMAROND_TABLE_MIN_INDEX)

CODE_DICE = KLASS::KARMAROND_DICE_TYPES
CODE_RANGE = KLASS::KARMAROND_DATARANGE
CODE_MIN_INDEX = KLASS::KARMAROND_TABLE_MIN_INDEX

LEDGER_BY_KEY = LEDGER["entries"].each_with_object({}) { |e, h| h[e["ascii_key"]] = e }
MIN_INDEX = KARMAROND_KEYS.map { |k| LEDGER_BY_KEY.fetch(k)["min_index"] }.uniq
abort_with("五表 min_index 不唯一（应恒为 1）：#{MIN_INDEX.inspect}") unless MIN_INDEX == [1]
abort_with("代码侧 min_index 与 ledger 不一致：#{CODE_MIN_INDEX}") unless CODE_MIN_INDEX == 1

# ---------------------------------------------------------------------------
# 2b. T1.5：キャラメイク 6 表 + 定値表示 + 聖戦判定
#
#     与 §2 的卡尔马同样「代码侧读常量、台账侧读 ledger」，不另抄一份。
# ---------------------------------------------------------------------------
abort_with("#{KLASS} 缺 CHARAMAKE_DICE_TYPES") unless KLASS.const_defined?(:CHARAMAKE_DICE_TYPES)
abort_with("#{KLASS} 缺 CHARAMAKE_TABLE_MIN_INDEX") unless KLASS.const_defined?(:CHARAMAKE_TABLE_MIN_INDEX)
abort_with("#{KLASS} 缺 SEISEN_DICE_TIMES/SIDES") unless KLASS.const_defined?(:SEISEN_DICE_TIMES)

CODE_CHARAMAKE = KLASS::CHARAMAKE_DICE_TYPES
CODE_CHARAMAKE_MIN_INDEX = KLASS::CHARAMAKE_TABLE_MIN_INDEX
CODE_SEISEN_TIMES = KLASS::SEISEN_DICE_TIMES
CODE_SEISEN_SIDES = KLASS::SEISEN_DICE_SIDES

abort_with("六表 min_index 不唯一（应恒为 1）：#{CHARAMAKE_TABLES.map { |k| LEDGER_BY_KEY[k]['min_index'] }.uniq.inspect}") \
  unless CHARAMAKE_TABLES.map { |k| LEDGER_BY_KEY[k]["min_index"] }.uniq == [1]
abort_with("代码侧 CHARAMAKE_TABLE_MIN_INDEX 与 ledger 不一致：#{CODE_CHARAMAKE_MIN_INDEX}") unless CODE_CHARAMAKE_MIN_INDEX == 1

# 聖戦判定的骰型与判定式——从 JSON 的 wasshoi 段实读，不写死。
SEISEN_JSON = JSON.parse(File.read(File.join(ROOT, "references/extracted/tengu_tables.json"), encoding: "UTF-8"))["wasshoi"]

# ---------------------------------------------------------------------------
# 2c. T1.7：1版 9 表（**另一个游戏系统** NinjaSlayerEx）
#
#     与 §2/§2b 同样「代码侧读常量、台账侧读 ledger」，不另抄一份。
#     三个常量都刻意做成**逐表 Hash 而非单一标量**：
#       - EDITION1_MIN_INDEX  : CYBER/SUMMON 是 2d6 表，min_index = 2（其余为 1）
#       - EDITION1_SKELETONS  : 骨架选型登记成数据，让测试能断言「与 ledger 的
#                              datarange 登记一致」
#       - EDITION1_DICE_TYPES : 别名收敛后的骰型（按唯一骰型去重，不按天狗别名字典）
# ---------------------------------------------------------------------------
KLASS1 = BCDice.game_system_class(EDITION1_GAME_SYSTEM_ID)
abort_with("扩展类 #{EDITION1_GAME_SYSTEM_ID} 未注册") if KLASS1.nil?
abort_with("#{KLASS1} 缺 EDITION1_DICE_TYPES") unless KLASS1.const_defined?(:EDITION1_DICE_TYPES)
abort_with("#{KLASS1} 缺 EDITION1_MIN_INDEX") unless KLASS1.const_defined?(:EDITION1_MIN_INDEX)
abort_with("#{KLASS1} 缺 EDITION1_SKELETONS") unless KLASS1.const_defined?(:EDITION1_SKELETONS)

CODE1_DICE = KLASS1::EDITION1_DICE_TYPES
CODE1_MIN_INDEX = KLASS1::EDITION1_MIN_INDEX
CODE1_SKELETONS = KLASS1::EDITION1_SKELETONS
CODE1_TABLES = KLASS1::EDITION1_TABLES

# 代码侧登记的表集合必须与本脚本的 EDITION1_TABLES 逐条一致（防漏注册）
abort_with("代码 EDITION1_TABLES 与生成器不一致：code=#{CODE1_TABLES.inspect} gen=#{EDITION1_TABLES.inspect}") \
  unless CODE1_TABLES.to_a == EDITION1_TABLES

# ============================================================================
# 3. 用例矩阵设计
#
#    每张表、每个骰型，按下列**出目目标**组合生成一条用例：
#      - min        : 恰好命中 datarange.min      （索引下边界）
#      - min+1      : min 侧第二格                （防 off-by-one）
#      - 典型        : 骰型可达范围内的一个代表值   （语义锚点）
#      - max        : 恰好命中 datarange.max      （索引上边界）
#      - max+1 钳制 : 越上界 → 必须钳到 max 项
#      - 负 x 钳制   : 越下界 → 必须钳到 min 项
#
#    每条用例的**骰序**由「目标出目反推」：
#      sum = Σ骰面 + 骰型常量 bonus + 用户補正 x
#    → 骰面和 = 目标 sum − bonus − x。反推优先用**均匀分布**铺满
#      [1, sides]（避免 2D6 恒出同点这种无意义序列），且必须落在
#      [times, times*sides] 内；落在范围外的目标值跳过该骰型的该档位。
# ============================================================================

# 反推骰序：把目标骰面和均匀地摊到 times 颗骰上。
#
# 目标骰面和 dice_sum 落在 [times, times*sides] 之外 → 返回 nil（该档位不可达，
# 需换補正值才能到达）。均匀化而非「全同点」是为了让 2D6 这类多骰的
# 固定骰序有实际信息量（[3,3] 而非 [1,5]）。
def rolls_for(dice_sum, times, sides)
  return nil if dice_sum < times || dice_sum > times * sides

  base, extra = dice_sum.divmod(times)
  rolls = Array.new(times, base)
  rolls.first(extra).each_with_index { |_, idx| rolls[idx] += 1 }
  rolls
end

# 为一个骰型生成用例矩阵。
#
# 目标出目（绝对值）→ {補正 x, 骰序, 是否预期钳制}。分两路：
#   ① 无補正（x=nil）：可达域端点与代表值
#   ② 带補正：为了真正打到 datarange 的**两端**（含钳制），从可达域边界
#      反推需要的 x——这样 1D3+3 这种「可达域 4..6 远高于 datarange.min=1」
#      的骰型也能钉住下界钳制（否则只会生成 1 条用例）。
def build_case_variants(spec, range)
  times = spec[:times]
  sides = spec[:sides]
  bonus = spec[:bonus]
  min = range[:min]
  max = range[:max]

  # 该骰型在 x=0 时的实际可达出目区间
  reachable_min = times + bonus
  reachable_max = times * sides + bonus

  variants = []

  # ① 无補正：datarange 两端、边界内侧一格、可达域代表值
  probes = [
    [min, "出目 #{min}"],
    [min + 1, "出目 #{min + 1}"],
    [max, "出目 #{max}"],
    [max + 1, "出目 #{max + 1}（上界钳制）"],
  ]
  # 可达域中点作为「典型值」，落在 datarange 内时优先取它
  mid = (reachable_min + reachable_max) / 2
  probes << [mid, "典型出目 #{mid}"] if mid >= min && mid <= max

  probes.each do |target, label|
    dice_sum = target - bonus
    r = rolls_for(dice_sum, times, sides)
    next if r.nil?

    variants << {
      label: label,
      input_x: nil,
      expect_clamp: target > max,
      rolls: r.map { |v| [v, sides] }
    }
  end

  # ② 带補正：
  #    (a) 下界钳制——x 取「让出目刚好低于 min」的最小整数；不可达时用最小骰序 + 更负的 x
  #    (b) 上界钳制——x 取「让出目刚好高于 max」的最小正整数
  #    (c) 普通補正（不钳制）——证明補正链路本身通
  correction_probes = [
    [:lower, "補正 #{min - 1 - reachable_min} → 出目 #{min - 1}（下界钳制）"],
    [:upper, "補正 #{max + 1 - reachable_max} → 出目 #{max + 1}（上界钳制）"],
    [:plain, "補正 +1"],
  ]

  correction_probes.each do |kind, label|
    x = case kind
        when :lower then min - 1 - reachable_min          # 必使 sum = min - 1
        when :upper then max + 1 - reachable_max          # 必使 sum = max + 1
        else 1
        end
    # plain 档用「落在范围内」的代表性起点（最小骰序 + x）
    dice_sum = kind == :plain ? times : (min - 1 - bonus - x)
    r = rolls_for(dice_sum, times, sides)
    next if r.nil?

    sum = dice_sum + bonus + x
    variants << {
      label: label,
      input_x: x,
      expect_clamp: sum < min || sum > max,
      rolls: r.map { |v| [v, sides] }
    }
  end

  variants
end

# ============================================================================
# 4. 三方交叉校验（ledger ↔ 代码 ↔ yml）
#
#    ledger 是数据层的登记、代码是行为层、yml 是文本层——三者任一漂移
#    都会让「测试全绿但语义错」。故在**生成前**逐条比对：
#      ① ledger.dice 表达式 ↔ 代码 spec（expr 的骰数/面数/常量）
#      ② ledger.dice_ranges min_sum/max_sum ↔ 代码 bonus 推出的实际可达域
#      ③ ledger.datarange ↔ 代码 KARMAROND_DATARANGE
#      ④ ledger.item_count ↔ yml items 长度
#      ⑤ ledger.data_index ↔ yml items 长度（跨度一致）
# ============================================================================
# 天狗骰型字面量 → 归一化的 "<times>d<sides>[+<bonus>]"
#
# 源格式举例（nd_datatable.js 的 dice 字段原样）：
#   "1d3+x" → "1d3"
#   "1d6+1+x" → "1d6+1"
#   "2d6+x" → "2d6"
#   "d3+3+x" → "1d3+3"   ← 隐式 1（dice.js 会补），末位空段丢弃
def normalize_dice_expr(raw)
  s = raw.to_s.downcase.gsub("+x", "").strip
  # 隐式 1：dN 开头补 1dN
  s = "1#{s}" if s.start_with?("d")
  s
end

def cross_validate!
  errors = []

  KARMAROND_KEYS.each do |key|
    entry = LEDGER_BY_KEY[key]
    next errors << "#{key}: ledger 无该表条目" if entry.nil?

    # ③ datarange
    ld_range = entry["datarange"]
    cd_range = CODE_RANGE[key]
    errors << "#{key}: datarange 不一致 ledger=#{ld_range.inspect} code=#{cd_range.inspect}" if ld_range != { "max" => cd_range[:max], "min" => cd_range[:min] }

    # ④⑤ item_count / data_index 跨度
    items = I18n.t("#{entry['namespace']}.table.#{key}.items", locale: :ja_jp, raise: true)
    errors << "#{key}: item_count 不一致 ledger=#{entry['item_count']} yml=#{items.size}" if entry["item_count"] != items.size
    span = entry["max_index"] - entry["min_index"] + 1
    errors << "#{key}: items 长度 #{items.size} ≠ data_index 跨度 #{span}" if items.size != span

    # ①② dice / dice_ranges
    entry["dice_ranges"].each do |dr|
      key_dice = dr["key"].upcase
      spec = CODE_DICE[key][key_dice]
      if spec.nil?
        errors << "#{key}_#{key_dice}: 代码缺该骰型"
        next
      end

      # 表达式一致性。
      #
      # ⚠ 归一化说明（2026-06-11 Node 实测钉版）：
      #   ledger 登记的是天狗**源字面量**（含隐式 1 的 "d3+3"），
      #   代码里用 {times, sides, bonus} 结构化表达（"1D3+3"）。
      #   两者**语义相同**：天狗 classes/dice.js 遇不以数字开头的串会补 "1"
      #   （`if (/[dD]/.test(string.slice(0,1))) string = '1' + string;`），
      #   且 diceroll.js 按 '+' 拆分后纯数字段走 NUMBER_ONLY 分支计入 sum
      #   ——Node 实测 `new Dice("d3")` → trancedString "1d3"，
      #   故 "d3+3" = 1 颗 3 面 + 常量 3，与代码 times=1/sides=3/bonus=3 等价。
      #   故此处比对**归一化后**的 "<times>d<sides>[+bonus]"。
      ld_expr = normalize_dice_expr(entry["dice"][dr["key"]])
      cd_expr = spec[:expr].downcase.strip
      errors << "#{key}_#{key_dice}: 表达式不一致 ledger=#{ld_expr.inspect}(归一化后) code=#{cd_expr.inspect}" if ld_expr != cd_expr

      # 可达域一致性：代码 bonus + 骰面域 应等于 ledger min_sum..max_sum
      cd_min = spec[:times] + spec[:bonus]
      cd_max = spec[:times] * spec[:sides] + spec[:bonus]
      errors << "#{key}_#{key_dice}: 可达域不一致 ledger=#{dr['min_sum']}..#{dr['max_sum']} code=#{cd_min}..#{cd_max}" if cd_min != dr["min_sum"] || cd_max != dr["max_sum"]
    end
  end

  # T1.5：キャラメイク 6 表（无 datarange、无補正、无钳制）
  CHARAMAKE_TABLES.each do |key|
    entry = LEDGER_BY_KEY[key]
    if entry.nil?
      errors << "#{key}: ledger 无该表条目"
      next
    end

    # ① **无 datarange 铁律**（kimi T1.5 预警 1）。
    #    天狗的钳制分支挂在 isTableAdditionValue 之下，只有 dice 字面量含 "+x"
    #    才会置位；本批 6 表 dice 全是 "1d6"/"1d36" → 必须恒为 null。
    errors << "#{key}: datarange 应为 nil（本批绝不钳制），实为 #{entry['datarange'].inspect}" unless entry["datarange"].nil?

    spec = CODE_CHARAMAKE[key]
    if spec.nil?
      errors << "#{key}: 代码缺该表骰型规格"
      next
    end

    # ② 骰型一致性（ledger base ↔ 代码 times/sides）
    dr = entry["dice_ranges"].fetch(0)
    m = dr["base"].match(/\A(\d+)D(\d+)\z/i)
    errors << "#{key}: ledger base 无法解析：#{dr['base']}" if m.nil?
    if m
      errors << "#{key}: times 不一致 ledger=#{m[1]} code=#{spec[:times]}" if m[1].to_i != spec[:times]
      errors << "#{key}: sides 不一致 ledger=#{m[2]} code=#{spec[:sides]}" if m[2].to_i != spec[:sides]
    end

    # ③ 条目数跨度
    items = I18n.t("NinjaSlayer2Ex.table.#{key}.items", locale: :ja_jp, raise: true)
    span = entry["max_index"] - entry["min_index"] + 1
    errors << "#{key}: items 长度 #{items.size} ≠ data_index 跨度 #{span}" if items.size != span

    # ④ **可达域 == 表跨度**：本批无钳制，出目越界即"不响应"，
    #    故掷骰可达域必须与 items 长度严格相等（1D6→6 条、1D36→36 条）。
    reachable = spec[:times] * spec[:sides]
    errors << "#{key}: 掷骰可达域 #{reachable} ≠ items 数 #{items.size}（无钳制时二者须恒等）" if reachable != items.size
  end

  # T1.5：聖戦判定
  # ① 骰型：JSON 的 wasshoi.dice_expression（"2d6"）↔ 代码常量
  seisen_expr = SEISEN_JSON["dice_expression"].to_s.match(/\A(\d*)d(\d+)\z/i)
  if seisen_expr.nil?
    errors << "SEISEN: JSON dice_expression 无法解析：#{SEISEN_JSON['dice_expression']}"
  else
    want_times = seisen_expr[1].empty? ? 1 : seisen_expr[1].to_i
    errors << "SEISEN: times 不一致 json=#{want_times} code=#{CODE_SEISEN_TIMES}" if want_times != CODE_SEISEN_TIMES
    errors << "SEISEN: sides 不一致 json=#{seisen_expr[2]} code=#{CODE_SEISEN_SIDES}" if seisen_expr[2].to_i != CODE_SEISEN_SIDES
  end

  # ② 判定式：JSON 的 comparison 必须就是 "dice.sum <= Number(dkk)"（kimi P5：精确等值，
  # 不用 include? 模糊匹配——防止语义漂移在子串层面漏检）
  errors << "SEISEN: JSON comparison 漂移：#{SEISEN_JSON['comparison'].inspect}" unless SEISEN_JSON["comparison"] == "dice.sum <= Number(dkk)"
  errors << "SEISEN: 代码 SEISEN_CMP 应为 :<=，实为 #{KLASS::SEISEN_CMP.inspect}" unless KLASS::SEISEN_CMP == :<=

  # ③ 文案：yml 的 judge 段 ↔ JSON 的 wasshoi（经声明式 TEXT_REWRITE 改写后逐字一致）
  %w[judge_name success_word success_message failure_word].each do |k|
    want = k == "judge_name" || k == "success_message" ? SEISEN_JSON.dig("kinds", "SEISEN", k) : SEISEN_JSON[k]
    want = rewrite_text(want) if want.is_a?(String)
    got = I18n.t("NinjaSlayer2Ex.judge.SEISEN.#{k}", locale: :ja_jp, raise: true)
    errors << "SEISEN 文案 #{k} 不一致 json=#{want.inspect} yml=#{got.inspect}" if want != got
  end

  # -----------------------------------------------------------------------
  # T1.7：1版 9 表（骨架选型 + min_index + 别名收敛 + 骰型）
  # -----------------------------------------------------------------------
  EDITION1_TABLES.each do |key|
    entry = LEDGER_BY_KEY[key]
    if entry.nil?
      errors << "#{key}: ledger 无该表条目"
      next
    end

    # ① **骨架选型 ⟺ datarange 有无**（T1.7 拍板的核心交叉校验）。
    #    选 :no_clamp 的前提是 ledger 登记 datarange = nil；
    #    选 :clamp 的前提是 ledger 登记了 {min,max}。
    #    任一侧单方面漂移（有人给表加了 datarange、或偷偷加了钳制常量）当场红。
    has_range = !entry["datarange"].nil?
    skeleton = CODE1_SKELETONS[key]
    if skeleton.nil?
      errors << "#{key}: 代码未登记骨架选型"
    elsif skeleton == :no_clamp && has_range
      errors << "#{key}: 骨架为 :no_clamp 但 ledger 登记了 datarange=#{entry['datarange'].inspect}；" \
                "要么改骨架为 :clamp（并实现钳制），要么确认 ledger 是否该清空"
    elsif skeleton == :clamp && !has_range
      errors << "#{key}: 骨架为 :clamp 但 ledger 的 datarange 为 nil（无可钳的边界）"
    end

    # ② min_index 逐表一致（**不是恒为 1**：CYBER/SUMMON 是 2d6 表 → 2）
    code_min = CODE1_MIN_INDEX[key]
    errors << "#{key}: 代码 EDITION1_MIN_INDEX 与 ledger min_index 不一致 code=#{code_min.inspect} ledger=#{entry['min_index'].inspect}" \
      unless code_min == entry["min_index"]

    # ③ yml items 数 == ledger item_count == data_index 跨度
    items = I18n.t("NinjaSlayerEx.table.#{key}.items", locale: :ja_jp, raise: true)
    errors << "#{key}: item_count 不一致 ledger=#{entry['item_count']} yml=#{items.size}" if entry["item_count"] != items.size
    span = entry["max_index"] - entry["min_index"] + 1
    errors << "#{key}: items 长度 #{items.size} ≠ data_index 跨度 #{span}" if items.size != span

    # ④ **别名收敛后的骰型集 ⟺ 天狗别名字典按表达式去重的唯一值集**。
    #    这是本批的核心断言：ledger.dice 有 10 / 13 个别名字典键，
    #    但它们只对应 2 / 3 个**唯一骰型**；代码侧登记的必须恰好是这个集合。
    #    （多一个 = 凭空多出无差别的可选项，如 KRM_D 与 KRM_A 同为 1d6；
    #      少一个 = 漏实现一个可达出目，如 KRM_C 的 2d6）
    ledger_exprs = entry["dice"].values.map { |v| normalize_dice_expr(v) }.uniq.sort
    code_exprs = CODE1_DICE[key].values.map { |s| s[:expr].downcase.strip }.uniq.sort
    errors << "#{key}: 别名收敛后的骰型集不一致 ledger=#{ledger_exprs.inspect} code=#{code_exprs.inspect}" \
      unless ledger_exprs == code_exprs

    # ⑤ 每个 `_X` 后缀 ↔ ledger 的某个唯一骰型：times/sides/bonus/可达域
    #    必须逐位对齐（与 §4 的卡尔马校验同形，只是表级 min_index 不同）
    CODE1_DICE[key].each do |suffix, spec|
      m = spec[:expr].downcase.strip.match(/\A(\d+)d(\d+)(?:\+(\d+))?\z/)
      errors << "#{key}_#{suffix}: 代码 expr 无法解析：#{spec[:expr].inspect}" if m.nil?
      next if m.nil?

      errors << "#{key}_#{suffix}: times 不一致 expr=#{spec[:expr]} code=#{spec[:times]}" if m[1].to_i != spec[:times]
      errors << "#{key}_#{suffix}: sides 不一致 expr=#{spec[:expr]} code=#{spec[:sides]}" if m[2].to_i != spec[:sides]
      errors << "#{key}_#{suffix}: bonus 不一致 expr=#{spec[:expr]} code=#{spec[:bonus]}" if m[3].to_i != spec[:bonus]

      # 可达域必须与 ledger 里该骰型的登记逐位一致
      dr = entry["dice_ranges"].find { |r| normalize_dice_expr(r["expr"]) == spec[:expr].downcase.strip }
      if dr.nil?
        errors << "#{key}_#{suffix}: ledger dice_ranges 无表达式 #{spec[:expr]} 的条目"
        next
      end
      want_min = spec[:times] + spec[:bonus]
      want_max = spec[:times] * spec[:sides] + spec[:bonus]
      errors << "#{key}_#{suffix}: 可达域不一致 ledger=#{dr['min_sum']}..#{dr['max_sum']} code=#{want_min}..#{want_max}" \
        if dr["min_sum"] != want_min || dr["max_sum"] != want_max
    end

    # ⑥ **无钳制 ⇒ 每个骰型的可达域必须 ⊆ 表跨度**。
    #    越界即不响应，所以「可达域落在表外」意味着那部分出目永远取不到表项
    #    （要么是 ledger 笔误，要么是代码骰型写大了）。这是 EDITION1_REACHABLE
    #    不变量的守卫，也是「绝不钳制」这一选择可行的前提。
    lo = entry["min_index"]
    hi = entry["max_index"]
    CODE1_DICE[key].each do |suffix, spec|
      want_min = spec[:times] + spec[:bonus]
      want_max = spec[:times] * spec[:sides] + spec[:bonus]
      next if want_min >= lo && want_max <= hi

      errors << "#{key}_#{suffix}: 可达域 #{want_min}..#{want_max} 超出表跨度 #{lo}..#{hi}" \
               "（无钳制时该段出目恒不响应，是规格漂移的信号）"
    end
  end

  errors
end

# ============================================================================
# 4c. T1.7 用例生成：1版 9 表（掷骰 + `@出目` 定値 + 别名后缀 + 异常系）
# ============================================================================
#
# 矩阵设计（与前两批的**根本差异**，逐条对应评审预警）：
#
#   本批 9 表**无 datarange、无 `+x` 補正**，故：
#     - **没有钳制档位**（掷骰可达域 ⊆ 表跨度，§4⑥ 已常驻断言），
#       输出里也不可能出现 `(raw→clamped)（クランプ）`；
#     - **没有 `@±n` 補正分支**（`@` 在本批只 = 定値表示，与 2版 KRS 族的
#       `@±n` = 補正值是**同字符两语义**，按表/系统区分）。
#
#   掷骰档位设计（每表 × 每骰型）：
#     - 每个骰型取【可达域下界】【可达域上界】两端 + 中点，
#       逐档由「目标绝对出目」反推骰序（复用 §3 的 rolls_for）。
#     - `1D6+1` 骰型（JITSB_B / KRM_B）：可达域 2..7，
#       出目 7 是**表跨度上边界**（KRM 是 7/12，JITSB 是 7/7）——
#       专门钉住「表级 min_index 索引在含 bonus 的骰型上不错位」。
#     - `2D6` 骰型（KRM_C）：可达域 2..12，而 KRM 表跨度恰为 1..12，
#       故出目 2 是**表第 1 项**（下边界）、出目 12 是第 12 项（上边界）。
#
#   `@出目` 定値档位：出目 min_index、出目 min_index+1、出目中点、出目 max。
#     与掷骰档形成「同一条目两条路」的对照，生成器额外断言两条路径正文**逐字相同**。
#
#   **别名后缀档**：对多骰型表（JITSB / KRM）额外生成「裸命令 == `_A`」的
#     逐字对照用例（天狗：ショートカット省略時 = A）。单骰型表的 `_A`
#     与裸命令同义，故只在多骰型表上生成（避免成百上千条重复用例）。
#
#   **大小写档**：`ws` / `jitSB` / `bioCYBER` 等——引擎 `@enabled_upcase_input`
#     在 Preprocessor 之后执行，故大小写天然等价，逐表取 1 条钉住即可。
#
#   异常系：未知骰型后缀（`WS_C` / `KRM_D` / `JITSB_C`）、定値越界/前导零/
#     非数字、**表名畸形**（`WSQ` / `JITSBX` / `BIOCYBERR`）、暗骰下的畸形。

# 1版表的标签（与实现的 edition1_table_label 同解：yml name 按 '(' 截断）
def label_key1(key)
  I18n.t("NinjaSlayerEx.table.#{key}.name", locale: :ja_jp, raise: true)[/\A[^(]*/]
end

# 渲染一条 1版表用例。
#
# @param input [String] 命令
# @param rolls [Array<Array(Integer,Integer)>] 骰序（定値档为空数组）
# @param output [String] 真实 eval 采集的文本
# @param secret [Boolean] 是否暗骰
# @return [String] toml 片段
def render_edition1_case(input, rolls, output, secret = false)
  lines = []
  lines << "[[ test ]]"
  lines << "game_system = \"#{EDITION1_GAME_SYSTEM_ID}\""
  lines << "input = \"#{toml_escape(input)}\""
  lines << "output = \"#{toml_escape(output)}\""
  lines << "secret = true" if secret
  # 定値表示档的 rolls 为空数组——实现在定値路径上**不掷骰**，
  # 故不会触发 RandomizerMock 的 @rands is empty!。runner 的
  # `data[:rands].map` 对空数组安全，无需特判（与 T1.5 同处理）。
  lines << "rands = ["
  rolls.each { |(value, sides)| lines << "  { sides = #{sides}, value = #{value} }," }
  lines << "]"
  lines.join("\n")
end

# @return [Array(String, Integer)] toml 文本 + 条数
def generate_edition1_block
  out = []
  total = 0

  EDITION1_TABLES.each do |key|
    spec_by_suffix = CODE1_DICE[key]
    min_index = CODE1_MIN_INDEX.fetch(key)
    items = I18n.t("NinjaSlayerEx.table.#{key}.items", locale: :ja_jp, raise: true)
    max_index = min_index + items.size - 1

    # ---- ① 掷骰档：每个 `_X` 骰型 × [可达域下界 / 中点 / 可达域上界] ----
    spec_by_suffix.each do |suffix, spec|
      times = spec[:times]
      sides = spec[:sides]
      bonus = spec[:bonus]
      lo = times + bonus
      hi = times * sides + bonus
      mid = (lo + hi) / 2

      targets = [[lo, "出目 #{lo}（可达域下界）"], [mid, "出目 #{mid}（中点）"], [hi, "出目 #{hi}（可达域上界）"]]
      targets.uniq! { |t, _| t }

      targets.each do |target, label|
        dice_sum = target - bonus
        r = rolls_for(dice_sum, times, sides)
        abort_with("#{key}_#{suffix}: 目标出目 #{target} 的骰序反推失败") if r.nil?

        input = suffix == "A" ? key : "#{key}_#{suffix}"
        output, result = eval_case1(input, r.map { |v| [v, sides] })
        abort_with("#{input}（#{label}）未响应——生成器与实现不同步") if output.nil?

        # 绝不钳制：输出里一旦出现钳制标注即 abort（本批无 datarange）
        abort_with("#{input}: 本批绝不钳制，输出却含钳制标注\n  output=#{output[0, 120]}") \
          if output.include?("（クランプ）")

        # 自检：输出必须含 `(目标出目)` 且表名标签正确
        abort_with("#{input}: 输出未含目标出目 (#{target})\n  output=#{output[0, 120]}") unless output.include?("(#{target}) ＞ ")
        abort_with("#{input}: 输出未以表名标签开头\n  output=#{output[0, 120]}") unless output.start_with?("#{label_key1(key)}(")

        # 自检：正文必须逐字等于 yml 的对应项（三方对齐：掷骰 ↔ yml ↔ 定値）
        want_body = items[target - min_index]
        roll_body = output.split(" ＞ ", 2)[1]
        abort_with("#{input}: 掷骰正文与 yml items[#{target - min_index}] 不一致") unless roll_body == want_body

        out << "# #{input} #{spec[:expr]} 掷骰｜#{label}"
        out << render_edition1_case(input, r.map { |v| [v, sides] }, output)
        out << ""
        total += 1
      end
    end

    # ---- ② `@出目` 定VALUE档：min_index / min_index+1 / 中点 / max_index ----
    [[min_index, "下边界"], [min_index + 1, "下边界 +1"],
     [(min_index + max_index) / 2, "中点"], [max_index, "上边界"]].uniq { |t, _| t }.each do |target, label|
      fixed_output, = eval_case1("#{key}@#{target}", [])
      abort_with("#{key}@#{target} 未响应——定値表示路径可能已坏") if fixed_output.nil?
      abort_with("#{key}@#{target}: 定値输出未以标签开头\n  output=#{fixed_output[0, 120]}") \
        unless fixed_output.start_with?("#{label_key1(key)}(#{target}) ＞ ")

      # 自检：定値正文 == yml 该出目的原文（与掷骰档的正文断言同一条基准）
      want_body = items[target - min_index]
      abort_with("#{key}@#{target}: 定値正文与 yml items[#{target - min_index}] 不一致") \
        unless fixed_output.split(" ＞ ", 2)[1] == want_body

      out << "# #{key}@#{target} 定値表示｜出目 #{target}（#{label}，不掷骰，天狗 /fnd 等价）"
      out << render_edition1_case("#{key}@#{target}", [], fixed_output)
      out << ""
      total += 1
    end

    # ---- ③ 别名后缀档（仅多骰型表）：裸命令 == `_A`，逐字对照 ----
    if spec_by_suffix.size > 1
      a_spec = spec_by_suffix.fetch("A")
      # 在可达域内取一个**非边界**值（lo+1），避开与掷骰档的重复档位；
      # 可达域若只有单个值（如不存在这种骰型）则退回 lo。
      target = [a_spec[:times] + a_spec[:bonus] + 1, a_spec[:times] * a_spec[:sides] + a_spec[:bonus]].min
      rolls = rolls_for(target - a_spec[:bonus], a_spec[:times], a_spec[:sides])
        .map { |v| [v, a_spec[:sides]] }

      bare, = eval_case1(key, rolls)
      explicit, = eval_case1("#{key}_A", rolls)
      abort_with("#{key} 未响应") if bare.nil?
      abort_with("#{key}_A 未响应") if explicit.nil?
      # 核心断言：天狗「ショートカット省略時 = A」→ 两条路径必须逐字相同
      abort_with("#{key} 与 #{key}_A 输出不一致（裸命令应恒等于 _A）\n" \
                  "  bare=#{bare[0, 80]}\n  _A  =#{explicit[0, 80]}") unless bare == explicit

      out << "# #{key} vs #{key}_A：裸命令恒等于 _A（天狗 tablehelp.js「ショートカット省略時はA」）"
      out << render_edition1_case(key, rolls, bare)
      out << ""
      out << "# #{key}_A：与裸命令逐字同源（上条的对拍孪生）"
      out << render_edition1_case("#{key}_A", rolls, explicit)
      out << ""
      total += 2
    end

    # ---- ④ 大小写档：引擎 upcase 在 Preprocessor 之后 → 大小写天然等价 ----
    #
    # 混合大小写形态 = 首字母小写 + 中间字母大写 + 末字母原样
    # （WS→wS / JITSB→jiTSB / BIOCYBER→biocYBER …）。
    # 骰序由该表**默认骰型 A** 的 times/sides 推出（不能用固定的 [3,6]——
    # BK 是 1D36、KRM_C 路径是 2D6，面数/颗数不匹配会抛
    # RandomizerMock 的 "unexpected sides"）。
    a_spec = spec_by_suffix.fetch("A")
    case_rolls = rolls_for(a_spec[:times] + a_spec[:bonus] + 1 - a_spec[:bonus],
                          a_spec[:times], a_spec[:sides])
                 .map { |v| [v, a_spec[:sides]] }
    mixed = key[0].downcase + key[1..-2].to_s.upcase + key[-1]

    mixed_output, = eval_case1(mixed, case_rolls)
    plain_output, = eval_case1(key, case_rolls)
    if mixed_output.nil? || plain_output.nil?
      abort_with("#{mixed} 或 #{key} 未响应（大小写等价档）")
    end
    abort_with("#{mixed} 与 #{key} 输出不一致（大小写应等价）") unless mixed_output == plain_output

    out << "# #{mixed}：大小写与 #{key} 等价（引擎 @enabled_upcase_input 在 Preprocessor 之后执行）"
    out << render_edition1_case(mixed, case_rolls, mixed_output)
    out << ""
    total += 1
  end

  # ---- ⑤ 暗骰档：S 前缀形态（T1.7 prefixes_pattern 覆写的直接受益者）----
  # 1版 14 个前缀两两无遮蔽，故暗骰形态本就可用；本档是**回归钉**，
  # 保证日后有人改 prefixes_pattern 覆写时不会静默回归掉。
  secret_cases = [
    ["SSOUL", [[3, 6]], "SSOUL：双 S 暗骰（SOUL 表）"],
    ["SBK",   [[3, 36]], "SBK：暗骰 BK 表（合法 SB 暗骰前缀 + BK）"],
    ["SBIOCYBER", [[3, 6]], "SBIOCYBER：暗骰 BIOCYBER 表（SBIOCYBER 易被误判成 SOUL 之类）"],
    ["SWS",   [[3, 6]], "SWS：暗骰 WS 表"],
  ]
  secret_cases.each do |input, rolls, comment|
    output, result = eval_case1(input, rolls)
    abort_with("#{input}（#{comment}）未响应") if output.nil?
    abort_with("#{input}: secret 标志应为 true，实为 #{result.secret?}（#{comment}）") unless result.secret?

    out << "# #{comment}"
    out << render_edition1_case(input, rolls, output, true)
    out << ""
    total += 1
  end

  [out.join("\n"), total]
end

# T1.7 的异常系（1版 9 表）。
#
# 与 T1.4 卡尔马 / T1.5 キャラメイク异常系**分开登记**：三者都断言「不响应」，
# 但触发原因各不相同（卡尔马=显式骰型/非数字補正；キャラメイク=越界/前导零；
# 本批=**表级 min_index 越界** + 未知骰型后缀 + 表名畸形），混在一张表里
# 日后增删会互相干扰。
T17_ERROR_CASES = [
  # ① 未知骰型后缀（该表只有 A，或该后缀对应的天狗别名与 A 同骰 → 不提供）
  "WS_B", "WS_C", "JITSB_C", "JITSB_D", "DKKI_B", "KRM_D", "CYBER_B", "CYBER_C",
  "BIOCYBER_B", "SOUL_B", "SOUL_C", "SUMMON_B", "BK_B", "BK_C",
  # ② 定値越界（表级 min_index 前后）与超上界
  "WS@0", "WS@7", "WS@99", "JITSB@0", "JITSB@8", "DKKI@0", "DKKI@7",
  "KRM@0", "KRM@13", "CYBER@1", "CYBER@0", "CYBER@13",
  "BIOCYBER@0", "BIOCYBER@7", "SOUL@0", "SOUL@7",
  "SUMMON@1", "SUMMON@0", "SUMMON@13", "BK@0", "BK@37", "BK@99",
  # ③ 前导零（天狗 /fnd 是字符串键直查，"03" 查不到 → 不响应）
  "WS@03", "JITSB@02", "CYBER@02", "BK@012",
  # ④ 定値的畸形输入
  "WS@", "WS@abc", "WS@-1", "WS@+3", "CYBER@", "BK@1.5",
  # ⑤ 表名畸形（不得被已注册前缀误吞，也不得被父类命令吞掉）
  "WSQ", "WSXX", "JITSBX", "JITSB_", "DKKIX", "KRMX", "CYBERX", "BIOCYBERR",
  "SOULX", "SUMMONX", "BKX", "BKK", "WS_", "KRM_",
  # ⑥ 骰型后缀 + 定値 的合法组合之外的形态
  "WS_A@3x", "KRM_C@2x", "BK_A@36.5",
  # ⑦ 暗骰形态下的畸形（S 前缀不得把非法命令救活）
  "SWSQ", "SBKX", "SSOULX", "SBK@",
].freeze

# @return [Array(String, Integer)] toml 文本 + 条数
def generate_edition1_error_block(cases = T17_ERROR_CASES)
  out = []
  cases.each do |cmd|
    # 异常系名单必须是**裸命令**：纯 ASCII、无空白、无引号。
    # （T1.5 真实事故：注释混进 %w 数组会静默产出语法非法的 toml）
    unless cmd.match?(/\A[A-Za-z0-9_@.!+-]+\z/)
      abort_with("T1.7 异常系条目含非法字符（只允许裸 ASCII 命令，勿把注释写进数组）：#{cmd.inspect}")
    end

    # 断言「真的不响应」——生成器自检：若某条开始响应了立即 abort，
    # 防止异常系名单与实现漂移后仍写入一条假用例。
    # 骰源给足 2 颗 6 面：若实现某条**本应拒答却真的响应了**，它会去掷骰；
    # 此处抛的是 RandomizerMock 的 "@rands is empty!"，同样让生成失败
    # （不会静默产出坏用例）。
    gs = BCDice.game_system_class(EDITION1_GAME_SYSTEM_ID).new(cmd)
    gs.randomizer = RandomizerMock.new([[6, 6], [6, 6]])
    abort_with("#{cmd} 本应不响应，但真实 eval 有了输出——异常系名单已过时") unless gs.eval.nil?

    out << "# 异常系：#{cmd} 不响应"
    out << "[[ test ]]"
    out << "game_system = \"#{EDITION1_GAME_SYSTEM_ID}\""
    out << "input = \"#{cmd}\""
    out << "output = \"\""
    out << "rands = ["
    out << "  { sides = 6, value = 1 },"
    out << "]"
    out << ""
  end
  [out.join("\n"), cases.size]
end

# ============================================================================
# 5. 真实 eval 采集 output + 生成 toml 文本
# ============================================================================
def eval_case(input, rolls)
  gs = KLASS.new(input)
  gs.randomizer = RandomizerMock.new(rolls.map(&:dup))
  result = gs.eval
  [result&.text, result]
end

# T1.7：1版 9 表的真实 eval（**另一个游戏系统** KLASS1）。
#
# 刻意不与 eval_case 合流：eval_case 硬绑 KLASS（2版），而本批表属于
# NinjaSlayerEx。合成一个带 klass 参数的助手当然也行，但两个批次的
# `gs` 来源不同会让「哪一批用哪个类」这件事在调用点不可见——
# 分成两个函数，误用（给 1版 命令传 2版 类）在编译期就看得出来。
#
# @param input [String]
# @param rolls [Array<Array(Integer,Integer)>] 骰序（定値档为空数组）
# @return [Array(String, Result, nil)] 输出文本 + Result + nil
def eval_case1(input, rolls)
  gs = KLASS1.new(input)
  gs.randomizer = RandomizerMock.new(rolls.map(&:dup))
  result = gs.eval
  [result&.text, result]
end

# TOML 基本字符串转义（本项目 runner 用 tomlrb → 标准 TOML 解析）
def toml_escape(str)
  str.gsub("\\", "\\\\\\\\").gsub("\"", "\\\"").gsub("\n", "\\n").gsub("\t", "\\t").gsub("\r", "\\r")
end

def render_case(key, dice_key, input, rolls, output)
  lines = []
  lines << "[[ test ]]"
  lines << "game_system = \"#{GAME_SYSTEM_ID}\""
  lines << "input = \"#{toml_escape(input)}\""
  lines << "output = \"#{toml_escape(output)}\""
  # T1.5：定値表示用例的 rolls 为空数组——runner 会把 rands 映射成空数组，
  # 而实现在定値路径上**不掷骰**，故不会触发 RandomizerMock 的 @rands is empty!。
  # runner 的 `data[:rands].map` 对空数组安全，无需特判。
  lines << "rands = ["
  rolls.each { |(value, sides)| lines << "  { sides = #{sides}, value = #{value} }," }
  lines << "]"
  lines.join("\n")
end

# 异常系（不响应）用例矩阵。
#
# 全部为「output 为空串」的 toml 条目——runner 见到 eval 返回 nil 时
# 断言 output 必须是 nil（TOML 用空串代 nil，见 runner 的 `test_case[:output] = nil
# if test_case[:output].empty?`）。
#
# 覆盖四类：
#   ① 天狗规则：带 @ 補正必须显式 _X → KRS@-1 / KRZ_D@ 形式不响应
#   ② 非数字補正 → 不响应（比天狗严格，见 proc_karmarond 注释）
#   ③ 未知派阀 / 未知骰型
#   ④ 空 @ / 畸形输入
ERROR_CASES = %w[
  KRS@-1
  KRZ@-2
  KRA@-1
  KRO@-1
  KRY@-1
  KRS_C@
  KRS_A@abc
  KRS_D@
  KRZ_A@x
  KRA_C@1.5x
  KRB
  KRX
  KRS_E
  KRS_X
  KRZ_F
  KRS_AA
  KRS_A@
].freeze

# T1.5 的异常系（キャラメイク 6 表 + 定値表示 + 聖戦）。
#
# 与 T1.4 的卡尔马异常系**分开登记**：两者都断言"不响应"，但触发原因不同
# （卡尔马是"天狗要求显式骰型/非数字補正"，本批是"越界/前导零/数字缺失"），
# 混在一张表里日后增删会互相干扰。
T15_ERROR_CASES = [
  # 定値表示越界（上下界外）
  "NJI@0", "NJI@7", "NJI@99", "NJS@7", "NJN@0", "NJC@7", "NJK@37", "NJB@37",
  # 前导零（天狗 /fnd 是字符串键直查，"03" 查不到 → 不响应）
  "NJI@03", "NJK@025", "NJB@0036",
  # 定値表示的畸形输入
  "NJI@", "NJI@abc", "NJK@-1", "NJB@+3",
  # 未知の扩展表（不得被 NJ 前缀误吞）
  "NJX", "NJQ@3", "NJA@3", "NJO@3",
  # 聖戦：数字缺失 / 非数字 / 负数 / 全角叹号（T1.5 实测均不响应）
  "SEISEN", "SEISEN!", "SEISEN!9", "SEISEN！9",
  "SEISEN-1", "SEISEN+9", "SEISEN9a", "SEISENabc",
  # `SEISEN 9` 会被引擎的 trim_after_whitespace 截成 `SEISEN` → 不响应。
  # （天狗侧是 DiceRoll 先剥空白再匹配、故响应；差异已在 HELP 与报告记录。）
  "SEISEN 9",
  "SSEISEN"
].freeze

# @param cases [Array<String>] 期望"不响应"的命令清单
# @return [Array(String, Integer)] toml 文本 + 条数
def generate_error_cases(cases = ERROR_CASES)
  out = []
  cases.each do |cmd|
    # 异常系名单必须是**裸命令**：纯 ASCII、无空白、无引号。
    #
    # ⚠ 这条守卫是被真实事故逼出来的（T1.5）：异常系最初写成 `%w[...]` 并在
    #   元素之间插了 `# 注释` 行，而 `%w` 按空白切分、不认 `#`，
    #   于是「前导零（…"03"…）」整行变成了一个字面命令，
    #   生成器把它写进 `input = "..."` → **产出的 toml 语法非法、整个套件炸**。
    #   而"每条都真的不响应"的自检**照样通过**（垃圾串当然不响应），
    #   即静默产出坏文件。故在生成前显式拦。
    #
    #   字符集允许两项**有意**的非裸字符输入：
    #     ① 全角叹号 `！` —— 天狗 WASSHOI 分支收 `！` 而 SEISEN 分支不收，
    #        故 `SEISEN！9` 必须不响应；
    #     ② 内部空白 —— `SEISEN 9` 会被引擎的 trim_after_whitespace 截成
    #        `SEISEN`（不响应），与天狗「先剥空白再匹配（响应）」的行为差异
    #        需要被用例钉住，见 docs/t1.5-report.md §4。
    #   除这两项外仍只允许裸 ASCII，防止注释/垃圾串混入。
    unless cmd.match?(/\A[A-Za-z0-9_@.!＋+\-！]+( +[A-Za-z0-9_@.!＋+\-！]+)*\z/)
      abort_with("异常系条目含非法字符（只允许裸 ASCII 命令 + 全角叹号 + 内部空白，勿把注释写进 %w/数组）：#{cmd.inspect}")
    end

    # 断言「真的不响应」——生成器自检：若某条开始响应了立即 abort，
    # 防止异常系名单与实现漂移后仍写入一条假用例。
    gs = KLASS.new(cmd)
    gs.randomizer = RandomizerMock.new([[1, 3]])
    if !gs.eval.nil?
      abort_with("#{cmd} 本应不响应，但真实 eval 有了输出——异常系名单已过时")
    end

    out << "# 异常系：#{cmd} 不响应"
    out << "[[ test ]]"
    out << "game_system = \"#{GAME_SYSTEM_ID}\""
    out << "input = \"#{cmd}\""
    out << "output = \"\""
    out << "rands = ["
    out << "  { sides = 3, value = 1 },"
    out << "]"
    out << ""
  end
  [out.join("\n"), cases.size]
end

# ============================================================================
# 4b. T1.5 用例生成：キャラメイク 6 表（掷骰 + @n 定値）+ 聖戦判定
# ============================================================================
#
# 矩阵设计（与 T1.4 卡尔马的**根本差异**，逐条对应评审预警 1）：
#
#   本批 6 表**无 datarange、无 +x 補正**，故没有"钳制"这一档：
#     掷骰档位 = 出目 1（min 边界）、出目 2（防 off-by-one）、
#                出目中点（语义锚点）、出目 sides（max 边界）。
#     因可达域 1..sides 与 items 数严格相等（§4 交叉校验④），
#     掷骰路径**不存在**越界，故不生成钳制档。
#
#   `@n` 定値档位 = 出目 1、出目 2、出目 中点、出目 max。
#     边界外（前导零 / 超上界）由 ERROR_CASES 覆盖。
#     特别地 `@1` 与 `@max` 是两侧边界，与掷骰档位形成"同一条目两条路"的对照。
#
#   `@n` 与掷骰的一致性自检：同一条目应能被两条路径取到，
#     故生成器额外断言 `NJI@k` 的正文 == `NJI`（出目 k） 的正文后半段。
#     这是任务书要求的"@n 定值与表文本改写后的一致性"的机械保障。
#
#   SEISEN 档位 = 成功（sum <= dkk）、失败（sum > dkk）、
#                边界相等（sum == dkk，成功侧）、DKK 极端（0 恒失败 / 99 恒成功）。

# 渲染色brick用的 toml 片段（复用 §5 的 render_case / toml_escape）。
def generate_chara_make_block
  out = []
  total = 0

  CHARAMAKE_TABLES.each do |key|
    spec = CODE_CHARAMAKE[key]
    times = spec[:times]
    sides = spec[:sides]

    # 4 档出目：min / min+1 / 中点 / max。times 恒为 1，故直接用出目值即可。
    mid = ((1 + sides) / 2.0).ceil
    probes = [[1, "出目 1（下边界）"], [2, "出目 2（下边界 +1）"], [mid, "出目 #{mid}（中点）"], [sides, "出目 #{sides}（上边界）"]]

    # 1D6 表（items ≤ 6）改为**全量覆盖**。
    #
    # 动机是实证性的：NJI 的第 6 项正文写着「「NJI@n」（nは1～5）を入力すると…」，
    # 这段表文本里的命令引用必须**真的都能用**。若只取 4 档探针（1/2/4/6），
    # @3 与 @5 就只剩"理论上合法"而无用例钉住，头注里"真实可用"的说法会落空。
    # 6 张表里 4 张是 1D6，全量生成也只多 8 条用例，成本可忽略。
    if sides <= 6
      probes = (1..sides).map { |v| [v, "出目 #{v}"] }
    end
    probes.uniq! { |target, _| target }

    probes.each do |target, label|
      rolls = [[target, sides]]

      # ① 掷骰档
      output, = eval_case(key, rolls)
      abort_with("#{key}（出目 #{target}）未响应——生成器与实现不同步") if output.nil?
      expect_contains = "(#{target})"
      abort_with("#{key} 出目 #{target}: 输出未含 #{expect_contains}\n  output=#{output[0, 120]}") unless output.include?(expect_contains)

      out << "# #{key} #{spec[:expr]} 掷骰｜#{label}"
      out << render_case(key, "A", key, rolls, output)
      out << ""
      total += 1

      # ② 同出目的 `@n` 定値档（不掷骰，rands 为空数组）
      fixed_output, = eval_case("#{key}@#{target}", [])
      abort_with("#{key}@#{target} 未响应——定値表示路径可能已坏") if fixed_output.nil?
      abort_with("#{key}@#{target}: 定値输出未含表名标签\n  output=#{fixed_output[0, 120]}") unless fixed_output.start_with?("#{label_key(key)}(#{target}) ＞ ")

      out << "# #{key}@#{target} 定値表示｜#{label}（不掷骰，天狗 /fnd 等价）"
      out << render_case(key, "A", "#{key}@#{target}", [], fixed_output)
      out << ""
      total += 1

      # ③ 一致性自检：定値正文 == 掷骰正文 == yml 该出目的原文。
      #
      #    比对基准用 **yml items[target-1]**（唯一真相），而不是互相剥离前缀——
      #    两条路径的前缀形态本就不同（掷骰是 `(1) ＞ `、定値没有出目段），
      #    互相比对需要脆弱的多层正则。这里三方对齐，任何一侧被手改都会红。
      want_body = I18n.t("NinjaSlayer2Ex.table.#{key}.items", locale: :ja_jp, raise: true)[target - CODE_CHARAMAKE_MIN_INDEX]
      roll_body = output.split(" ＞ ", 3)[2]
      fixed_body = fixed_output.split(" ＞ ", 2)[1]
      abort_with("#{key} 出目 #{target}: 掷骰正文与 yml 不一致") unless roll_body == want_body
      abort_with("#{key}@#{target}: 定値正文与 yml 不一致") unless fixed_body == want_body
    end

    # 表文本内嵌的命令引用必须**真的可执行**（任务书验收项）。
    #
    # NJI[6] 的正文写着「「NJI@n 」（nは1～5）を入力すると…」。
    # 这不是装饰文字——它是一份**给玩家的用法说明**，若 `NJI@3` 之类的命令
    # 实际不响应，说明文本在骗人。故逐个实跑 n=1..5 确认全部有输出。
    #
    # 泛化思路：扫描本批各表的 items，凡匹配 `/\b(NJ[A-Z])@n\b/` 的，
    # 就按文案给出的范围逐个实跑。这里对 NJI 写死 1..5 是因为**范围就写在正文里**，
    # 去解析日文数字范围属于过度设计；一旦文案改成别的范围，
    # 这条断言会因实跑失败而红——那正是我们要的信号。
    next unless key == "NJI"

    (1..5).each do |n|
      body, = eval_case("NJI@#{n}", [])
      abort_with("NJI[#{n + 1}] 正文引用了 `NJI@n`（n=#{n}），但该命令未响应——" \
                  "表文本里的用法说明与实际行为不符") if body.nil?
    end
  end

  [out.join("\n"), total]
end

# 定値输出的表名前缀（与 chara_make_table_label 同解：yml name 按 '(' 截断）
def label_key(key)
  I18n.t("NinjaSlayer2Ex.table.#{key}.name", locale: :ja_jp, raise: true)[/\A[^(]*/]
end

# 聖戦判定的用例。
#
# 每条都钉住「输出文本 + success/failure 标志」两者——天狗只输出纯字符串，
# 本扩展额外提供成败标志，故 toml 里 success/failure 字段也要断言。
#
# @param dkk [Integer]
# @param rolls [Array<Array(Integer,Integer)>] 两颗 6 面骰
def generate_seisen_case(dkk, rolls, label)
  input = "SEISEN#{dkk}"
  gs = KLASS.new(input)
  gs.randomizer = RandomizerMock.new(rolls.map(&:dup))
  result = gs.eval
  abort_with("#{input}（#{label}）未响应——聖戦路径可能已坏") if result.nil?

  total = rolls.sum { |(v, _)| v }
  expect_success = total <= dkk
  abort_with("#{input}: success 标志应为 #{expect_success}，实为 #{result.success?}（#{label}）") unless result.success? == expect_success
  abort_with("#{input}: failure 标志应为 #{!expect_success}，实为 #{result.failure?}（#{label}）") unless result.failure? == !expect_success

  lines = []
  lines << "# 聖戦判定 #{label}｜合計 #{total}<=#{dkk}"
  lines << "[[ test ]]"
  lines << "game_system = \"#{GAME_SYSTEM_ID}\""
  lines << "input = \"#{toml_escape(input)}\""
  lines << "output = \"#{toml_escape(result.text)}\""
  lines << "success = #{expect_success}"
  lines << "failure = #{!expect_success}"
  lines << "rands = ["
  rolls.each { |(value, sides)| lines << "  { sides = #{sides}, value = #{value} }," }
  lines << "]"
  [lines.join("\n"), 1]
end

def generate_seisen_block
  out = []
  total = 0

  # 2D6 的合计域 2..12。逐档覆盖：
  #   成功侧（远低于 dkk）、边界相等、失败侧（高于 dkk），以及 DKK 极端值。
  probes = [
    [9, [[2, 6], [4, 6]], "成功：合計 6 < 9"],
    [9, [[3, 6], [6, 6]], "成功：合計 9 = 9（边界相等，含成功文案）"],
    [9, [[4, 6], [6, 6]], "失败：合計 10 > 9"],
    [2, [[1, 6], [2, 6]], "失败：合計 3 > 2（dkk 极小）"],
    [0, [[1, 6], [1, 6]], "失败：DKK=0 恒失败（天狗 seisen0 合法）"],
    [99, [[6, 6], [6, 6]], "成功：DKK=99 恒成功（天狗允许无上界）"],
    [12, [[6, 6], [6, 6]], "成功：合計 12 = 12（2D6 上界恰等于 dkk）"],
    [11, [[6, 6], [6, 6]], "失败：合計 12 > 11（2D6 上界差 1 即失败）"],
  ]

  probes.each do |dkk, rolls, label|
    block, n = generate_seisen_case(dkk, rolls, label)
    out << block
    out << ""
    total += n
  end

  [out.join("\n"), total]
end

# ---------------------------------------------------------------------------
# T1.6：追加判定扩展（倍率 / 记忆符）的用例生成
# ---------------------------------------------------------------------------
#
# 用例分五类，逐类钉住任务书「toml 用例覆盖正常系+异常系+组合系+三关交互」：
#   ① 正常系：倍率各值、记忆符 J/L、父类对照（证明零漂移）
#   ② 异常系：畸形倍率、越界倍率、[C] 冲突、逗号分隔
#   ③ 组合系：多段追加判定、逗号连掷、倍率×记忆符
#   ④ 三关交互：空白截断 / 大小写 upcase 的实际行为
#   ⑤ 暗骰（S 前缀泛化的直接受益者）
#
# 全部 output 由真实 eval 采集（render_case 只做转义），生成器自检：
#   - 标注「不响应」的必须真的 nil，否则 abort（防名单过时）
#   - 标注「预期值」的必须出现在 output 里，否则 abort（防实现与用例脱节）
# rolls 写法：每个用例都要给出**恰好** dice 数颗骰（`K6` = 6 颗、`K6,N6` = 12 颗）。
# 这里用 rolls6/rolls12 两个小助手展开，避免手写一长串 `[x, 6]` 时数错个数——
# 数错会让 RandomizerMock 抛 "@rands is empty!"（生成期即失败，不会静默产出坏用例）。
def rolls6(*vals)
  vals.map { |v| [v, 6] }
end

def rolls12(*vals)
  vals.map { |v| [v, 6] }
end

T16_NORMAL_CASES = [
  # [input, rolls, 期望出现在 output 里的片段, 说明]
  ["K6[J]",    rolls6(5, 6, 6, 6, 6, 6), "ジツ暴走[=1]:0", "[J] 出目1计数·零命中"],
  ["K6[J]",    rolls6(1, 2, 3, 4, 5, 6), "ジツ暴走[=1]:1[1]", "[J] 出目1计数·命中1"],
  ["K6[L]",    rolls6(1, 2, 3, 4, 5, 6), "LAN直結出目6数[=6]:1[6]", "[L] 出目6计数·命中1"],
  ["K6[L]",    rolls6(1, 2, 3, 4, 5, 1), "LAN直結出目6数[=6]:0", "[L] 出目6计数·零命中"],
  ["K6[j]",    rolls6(1, 2, 3, 4, 5, 6), "ジツ暴走[=1]:1[1]", "小写 [j] 与 [J] 等价（upcase 在 Preprocessor 之后）"],
  ["K6[l]",    rolls6(6, 6, 1, 1, 1, 1), "LAN直結出目6数[=6]:2[6,6]", "小写 [l] 与 [L] 等价"],
  ["K6[>=5*2]", rolls6(5, 6, 1, 1, 1, 1), "追加判定[>=5]:4[6,5]", "倍率×2：命中2 → 4（天狗语义）"],
  ["K6[>=5*2]", rolls6(4, 3, 1, 1, 1, 1), "追加判定[>=5]:0", "倍率×2·零命中 → 0"],
  ["K6[>=5*3]", rolls6(5, 6, 1, 1, 1, 1), "追加判定[>=5]:6[6,5]", "倍率×3：命中2 → 6"],
  ["K6[>=5*1]", rolls6(5, 6, 1, 1, 1, 1), "追加判定[>=5]:2[6,5]", "倍率×1 = 素形态"],
  ["K6[=6*2]",  rolls6(6, 6, 1, 1, 1, 1), "追加判定[=6]:4[6,6]", "等值判定 ×2：命中2 → 4"],
  ["K6[>4*3]",  rolls6(5, 6, 1, 1, 1, 1), "追加判定[>4]:6[6,5]", "严格大于判定 ×3（无 = 的形态）"],
  ["K6[<=3*2]", rolls6(1, 3, 5, 5, 5, 5), "追加判定[<=3]:4[3,1]", "小于等于判定 ×2"],
  ["K6[<2*4]",  rolls6(1, 3, 5, 5, 5, 5), "追加判定[<2]:4[1]", "小于判定 ×4"],
  ["K6[!=2*2]", rolls6(1, 2, 5, 5, 5, 5), "追加判定[!=2]:10[5,5,5,5,1]", "不等判定 ×2：命中5 → 10"],
  # 天狗实测：小数倍率合法且不取整（2.5 命中 2 → 5）
  ["K6[>=5*2.5]", rolls6(5, 6, 1, 1, 1, 1), "追加判定[>=5]:5[6,5]", "小数倍率 2.5 命中2 → 5（天狗 Number() 语义）"],
  ["K6[>=5*0.5]", rolls6(5, 6, 1, 1, 1, 1), "追加判定[>=5]:1[6,5]", "小数倍率 0.5 命中2 → 1"],
  # 天狗实测：裸 * 与 *0 都给出倍率 0
  ["K6[>=5*]",  rolls6(5, 6, 1, 1, 1, 1), "追加判定[>=5]:0[6,5]", "裸 * → Number('')=0（天狗默认分支）"],
  ["K6[>=5*0]", rolls6(5, 6, 1, 1, 1, 1), "追加判定[>=5]:0[6,5]", "*0 → 倍率 0（天狗合法）"],
  # 倍率上界：恰在上界响应，超一档不响应（后者在异常系）
  ["K6[>=5*100]", rolls6(5, 6, 1, 1, 1, 1), "追加判定[>=5]:200[6,5]", "倍率 100（bairitsu_max 上界）仍响应"],
  # 父类对照：素形态倍率 1 与父类追加判定逐字同源
  ["K6[>=5]", rolls6(5, 6, 1, 1, 1, 1), "追加判定[>=5]:2[6,5]", "素形态（倍率 1）"],
  ["K6[=6]",  rolls6(6, 6, 1, 1, 1, 1), "追加判定[=6]:2[6,6]", "父类形态 [=6] 零漂移"],
  ["K6[C]",   rolls6(6, 6, 1, 1, 1, 1), "クリティカル判定[C]:2[6,6]", "[C] 保上游 クリティカル语义（计划 §5 拍板）"],
  ["K6[=4]",  rolls6(4, 4, 1, 1, 1, 1), "追加判定[=4]:2[4,4]", "コッポ判定改用 [=4]（文档指定的替代写法）"],
  ["K6[S5]",  rolls6(5, 6, 1, 1, 1, 1), "サツバツ判定[S5]:2[6,5]", "父类形态 [S5] 零漂移"],
  # 难度字母变体（dice 部与父类同源）
  ["N6[J]",   rolls6(1, 2, 3, 4, 5, 6), "ジツ暴走[=1]:1[1]", "N（Normal 難度）+ [J]"],
  ["UH6[L]",  rolls6(6, 6, 1, 1, 1, 1), "LAN直結出目6数[=6]:2[6,6]", "UH（Ultra-Hard 難度）+ [L]"],
  ["E6[J]",   rolls6(1, 2, 3, 4, 5, 6), "ジツ暴走[=1]:1[1]", "E（Easy 難度）+ [J]"],
].freeze

T16_COMBO_CASES = [
  ["K6[J][L]",      rolls6(1, 6, 2, 3, 4, 5), ["ジツ暴走[=1]:1[1]", "LAN直結出目6数[=6]:1[6]"], "多段：记忆符 ×2"],
  ["K6[J][>=5*2]", rolls6(1, 5, 2, 3, 4, 5), ["ジツ暴走[=1]:1[1]", "追加判定[>=5]:4[5,5]"], "多段：记忆符 + 倍率"],
  ["K6[>=5*2][J]", rolls6(1, 5, 2, 3, 4, 1), ["追加判定[>=5]:2[5]", "ジツ暴走[=1]:2[1,1]"], "多段顺序互换（顺序应反映在输出顺序上）"],
  ["K6[L][J][>=5*2]", rolls6(6, 1, 5, 1, 2, 3),
   ["LAN直結出目6数[=6]:1[6]", "ジツ暴走[=1]:2[1,1]", "追加判定[>=5]:4[6,5]"], "三段共存"],
  ["K6,N6[J]",     rolls12(1, 2, 3, 4, 5, 6, 1, 2, 3, 4, 5, 6),
   ["ジツ暴走[=1]:1[1]"], "逗号连掷 × 追加判定（两次掷骰各带一段）"],
  ["K6[>=5*2][=1*3]", rolls6(5, 1, 2, 3, 4, 1), ["追加判定[>=5]:2[5]", "追加判定[=1]:6[1,1]"], "倍率段 ×2（两段倍率各自独立）"],
  ["SSBX", rolls6(3), ["サツバツ"], "暗骰 SSBX（S 前缀保护泛化的回归钉——T1.5 形态经 SB 前缀截断已可用，泛化是预防性收益（kimi 二审口径更正））"],
].freeze

T16_ERROR_CASES = [
  "K6[>=5*x]",       # 非数字倍率 → 天狗降级为 1，本扩展收紧为不响应
  "K6[>=5*-1]",      # 负倍率
  "K6[>=5*101]",     # 超上界（bairitsu_max = 100）
  "K6[J,L]",         # 逗号分隔（天狗合法，本扩展只用 ][）
  "K6[J*2]",         # 记忆符不带倍率
  "K6[L1]",          # 记忆符后带数字
  "K6[JX]",          # 未知记忆符
  "K6[>=665+*2]",    # 集合判定 + 倍率（天狗不支持）
  "K6[>=7*2]",       # y 超出 1-6
  "K6[>=5**2]",      # 双星号
  "K6[]",            # 空追加判定
  "K6[>=5*2",        # 未闭合
].freeze

# 三关交互用例：引擎 Preprocessor 对输入的实际形变（实测结论，报告 §1）
T16_GATE_CASES = [
  # trim_after_whitespace：`K6[J] 備考` 被截到空白前 → 追加判定仍在
  ["K6[J] 備考", rolls6(1, 2, 3, 4, 5, 6), ["ジツ暴走[=1]:1[1]"],
   "trim_after_whitespace：`[J] 備考` → 取空白前（追加判定保留）"],
  # 骰式与追加判定之间有空格 → 被截成 `K6`，追加判定**整段丢失**（退化为裸判定）
  ["K6 [J]", rolls6(6, 5, 4, 3, 2, 1), ["成功数:5"],
   "trim_after_whitespace：`K6 [J]` → 截成 `K6`（追加判定丢失，与天狗抛异常方向一致）"],
].freeze

# @return [Array(String, Integer)] toml 文本 + 条数
def generate_appendix_ex_block
  out = []
  total = 0

  render = lambda do |input, rolls, output, result, expect_frags, comment|
          lines = ["# #{comment}"]
          lines.concat(render_case(nil, nil, input, rolls, output).split("\n"))
          # 成功判定命令必须带上成功/失败标志——runner 对这四个字段逐条断言
          # （render_case 是给表命令用的，不写标志；本批是**判定**命令）。
          # 标志取自**真实 eval 的 Result**，不是手写常量，避免实现改了成败口径
          # 而 toml 还写着旧值（runner 会当场红，但生成期就该拦下来）。
          lines.insert(4, "success = #{result.success?}")
          lines.insert(5, "failure = #{result.failure?}")
          # 暗骰标志同样从真实 Result 取。SSBX 这类用例必须带 secret = true，
          # 否则 runner 的 `assert_equal(data[:secret], result.secret?)` 会红
          # （S 前缀保护泛化的预防性收益；T1.5 形态下 SSBX 经 SB 前缀截断已可用——kimi 二审口径更正）。
          lines.insert(6, "secret = #{result.secret?}") if result.secret?
          expect_frags.each do |frag|
            next if output.include?(frag)

            abort_with("#{input}: 输出未含预期片段 #{frag.inspect}\n  output=#{output[0, 160]}")
          end
          [lines.join("\n"), 1]
        end

  T16_NORMAL_CASES.each do |input, rolls, frag, comment|
    output, result = eval_case(input, rolls)
    abort_with("#{input}（#{comment}）未响应——追加判定扩展路径可能已坏") if output.nil?

    block, n = render.call(input, rolls, output, result, [frag], comment)
    out << block << ""
    total += n
  end

  T16_COMBO_CASES.each do |input, rolls, frags, comment|
    output, result = eval_case(input, rolls)
    abort_with("#{input}（#{comment}）未响应——组合形态可能已坏") if output.nil?

    block, n = render.call(input, rolls, output, result, frags, comment)
    out << block << ""
    total += n
  end

  T16_GATE_CASES.each do |input, rolls, frags, comment|
    output, result = eval_case(input, rolls)
    abort_with("#{input}（#{comment}）未响应——三关交互路径可能已坏") if output.nil?

    block, n = render.call(input, rolls, output, result, frags, comment)
    out << block << ""
    total += n
  end

  # 异常系：必须真的不响应
  T16_ERROR_CASES.each do |cmd|
    gs = KLASS.new(cmd)
    # 给足 12 颗骰（K6=6 / 逗号连掷最多 12）。若实现某条**本应拒答却真的响应了**，
    # 它会真的去掷骰并把随机源吃穿；此处抛的是 RandomizerMock 的
    # "@rands is empty!"，同样让生成失败（不会静默产出坏用例）。
    gs.randomizer = RandomizerMock.new(Array.new(12) { [6, 6] })
    result = gs.eval
    abort_with("#{cmd} 本应不响应，但真实 eval 有了输出——异常系名单已过时") unless result.nil?

    out << "# 异常系：#{cmd} 不响应"
    out << "[[ test ]]"
    out << "game_system = \"#{GAME_SYSTEM_ID}\""
    out << "input = \"#{toml_escape(cmd)}\""
    out << "output = \"\""
    out << "rands = ["
    out << "  { sides = 6, value = 1 },"
    out << "]"
    out << ""
    total += 1
  end

  [out.join("\n"), total]
end

# @param keys [Array<String>] 要生成的卡尔马派阀键
# @return [Array(String, Integer)] toml 文本 + 条数
def generate_block(keys = KARMAROND_KEYS)
  out = []
  total = 0

  keys.each do |key|
    range = CODE_RANGE[key]
    CODE_DICE[key].each do |dice_key, spec|
      variants = build_case_variants(spec, range)
      next if variants.empty?

      variants.each do |v|
        base = "#{key}#{dice_key == 'A' ? '' : "_#{dice_key}"}"
        input = v[:input_x].nil? ? base : "#{key}_#{dice_key}@#{v[:input_x]}"
        # 注：带 @ 補正时**必须显式 _X**（天狗「補正値を指定するときには
        # ショートカットを省略できません」）。故此处不能用裸 `key` 形态，
        # 即使骰型是 A 也要写 KRS_A@-n。
        output, result = eval_case(input, v[:rolls])

        if output.nil?
          abort_with("#{input}（骰序 #{v[:rolls].inspect}）未响应——生成器与实现不同步")
        end

        # 钳制预期自检：出目越界必须出现钳制标注，且不得静默 nil
        clamped = output.include?("（クランプ）")
        if clamped != v[:expect_clamp]
          abort_with("#{input}: 钳制预期不符（预期 #{v[:expect_clamp]}，实际 #{clamped}）\n  output=#{output[0, 120]}")
        end

        out << "# #{key} #{dice_key}型 #{spec[:expr]}｜#{v[:label]}"
        out << render_case(key, dice_key, input, v[:rolls], output)
        out << ""
        total += 1
      end
    end
  end

  err_block, err_count = generate_error_cases
  total += err_count

  [out.join("\n") + "\n" + err_block, total]
end

# ============================================================================
# 6. 哨兵块替换（幂等的核心）
# ============================================================================
#
# T1.5 起本脚本管**两个**独立哨兵块（各自 BEGIN/END 一对，互不嵌套）：
#   - T1.4 KARMAROND  ：5 派阀 × 4 骰型 × 边界矩阵 + 卡尔马异常系
#   - T1.5 CHARAMAKE ：6 キャラメイク表 ×（掷骰 + @n 定値）+ SEISEN + T1.5 异常系
#
# 分块而非合成一个大块的理由：两个任务的用例来源不同（卡尔马有钳制/補正矩阵，
# キャラメイク没有），合成一块会让任一侧重生成时无谓地 churn 另一段的排版。
#
# 块序固定 = 文件内先后序（append 型 splice 把新块追加到文末）。
#
# ⚠ T1.7 的块**独立于前三个且落在另一个 toml 文件**
#   （test/data/NinjaSlayerEx.toml vs NinjaSlayer2Ex.toml）：
#   runner 对每个文件断言「文件内 game_system 唯一」，把 1版 用例写进
#   2版 的 toml 会让 runner 直接 exit 1。故 TARGET_FILE 必须在
#   「选中了哪批表」之后再决定（见 §7），--target-file 可显式覆盖。

BEGIN_MARK = "# >>> BEGIN GENERATED: T1.4 KARMAROND"
END_MARK = "# <<< END GENERATED: T1.4 KARMAROND"

BEGIN_MARK_T15 = "# >>> BEGIN GENERATED: T1.5 CHARAMAKE"
END_MARK_T15 = "# <<< END GENERATED: T1.5 CHARAMAKE"

# T1.6 起第三个独立哨兵块（追加判定扩展：倍率 / 记忆符）。
#
# 独立成块而非并入 T1.5：本批的命令面是**父类的 dice 部**（`K6[...]`），
# 与キャラメイク/聖戦（自有前缀表）无交集，共用一块会让任一侧重生成时
# 无谓 churn 另一段的排版。
BEGIN_MARK_T16 = "# >>> BEGIN GENERATED: T1.6 APPENDIX_EX"
END_MARK_T16 = "# <<< END GENERATED: T1.6 APPENDIX_EX"

# T1.7 第四个独立哨兵块（1版 9 表）。落 **NinjaSlayerEx.toml**。
#
# 与 T1.5 同为「纯查表 + 定値表示」，但必须独立成块**且换文件**：
#   - 换文件是硬性要求（runner 的单文件单 game_system 断言）；
#   - 独立成块则是为了让 `--tables WS` 只重生成本批，
#     不动 NinjaSlayer2Ex.toml 里的 1版无关内容。
BEGIN_MARK_T17 = "# >>> BEGIN GENERATED: T1.7 EDITION1"
END_MARK_T17 = "# <<< END GENERATED: T1.7 EDITION1"

# 把 block 塞进 (begin, end) 哨兵；不存在则追加到文件末尾。
#
# @param existing [String] 当前文件全文
# @param block [String] 哨兵内的块正文
# @param begin_mark [String]
# @param end_mark [String]
# @return [String]
def splice_block(existing, block, begin_mark = BEGIN_MARK, end_mark = END_MARK)
  b = existing.index(begin_mark)
  e = existing.index(end_mark)
  if b && e
    abort_with("哨兵块嵌套/顺序异常（END 在 BEGIN 之前）") if e < b

    # kimi P2：批内子集替换会造成用例静默减少（如 --tables KRS,KRO 把 108→36）。
    # 替换前比对用例数，下降即 abort（要整批替换就去掉 --tables，或显式 --allow-shrink）。
    old_count = existing[b..e].scan(/\[\[\s*test\s*\]\]/).length
    new_count = block.scan(/\[\[\s*test\s*\]\]/).length
    if new_count < old_count
      abort_with("哨兵块替换会使用例数从 #{old_count} 降到 #{new_count}（--tables 批内子集导致）。\n" \
                 "  整批重生成请去掉 --tables；确认要缩容请人工编辑。")
    end

    head = existing[0...b]
    tail = existing[(e + end_mark.length)..] || ""
    return "#{head}#{begin_mark}\n#{block}\n#{end_mark}#{tail}"
  elsif b || e
    abort_with("哨兵不成对（BEGIN/END 只出现一个）——请手工检查 #{TARGET_FILE}")
  else
    sep = existing.end_with?("\n") || existing.empty? ? "" : "\n"
    "#{existing}#{sep}\n#{begin_mark}\n#{block}\n#{end_mark}\n"
  end
end

# ============================================================================
# 7. 主流程
# ============================================================================
# --tables 裁剪：只生成请求的表所在的批（各批各自独立哨兵块）。
#
# 裁剪时**只影响本批块**——例如 `--tables NJI` 不会去动卡尔马块。
# 跨批混选（`--tables KRS,NJI`）允许：多批都会被重生成。
unknown = options[:tables] - ALL_TABLES
abort_with("未知表键 #{unknown.inspect}；可选：#{ALL_TABLES.join(',')}") unless unknown.empty?

want_karma = (options[:tables] & DEFAULT_TABLES)
want_chara = (options[:tables] & CHARAMAKE_TABLES)
want_ed1 = (options[:tables] & EDITION1_TABLES)
# SEISEN 不在 --tables 的表键体系里（它不是表），故跟随キャラメイク批一同生成。
# T1.6 同理：命令面是父类 dice 部、无表键，跟随 2版 批一并生成。

abort_with("--tables 未选中任何表") if want_karma.empty? && want_chara.empty? && want_ed1.empty?

# ⚠ **目标文件必须在表批选定之后才决定**（T1.7 引入）。
#   1版表（NinjaSlayerEx）与 2版表（NinjaSlayer2Ex）是**两个游戏系统**，
#   而 runner 对每个 toml 文件断言「文件内 game_system 唯一」
#   （test_ext_game_system_commands.rb:86-90，不唯一即 exit 1）。故：
#     - 只选 1版表         → NinjaSlayerEx.toml
#     - 选到任何 2版表     → NinjaSlayer2Ex.toml（T1.4/T1.5/T1.6 块都在那）
#     - 跨系统混选（罕见） → abort，要求分两次跑（--target-file 是逃生舱）
only_ed1 = want_karma.empty? && want_chara.empty? && !want_ed1.empty?
if !want_ed1.empty? && options[:target].nil? && (!want_karma.empty? || !want_chara.empty?)
  abort_with("--tables 跨游戏系统混选（1版 #{want_ed1.join(',')} + 2版 #{(want_karma + want_chara).join(',')}）。" \
             "\n  两批分属不同 toml（runner 要求单文件单 game_system），请分两次跑：" \
             "\n    --tables #{want_ed1.join(',')}" \
             "\n    --tables #{(want_karma + want_chara).join(',')}")
end

TARGET_FILE = options[:target] || (only_ed1 ? EDITION1_DEFAULT_TARGET : DEFAULT_TARGET)
abort_with("找不到目标文件 #{TARGET_FILE}") unless File.exist?(TARGET_FILE)

# §4 交叉校验先行——不过就 abort，不写盘
errors = cross_validate!
unless errors.empty?
  warn("[gen_table_toml] 三方交叉校验失败（ledger ↔ 代码 ↔ yml）：")
  errors.each { |e| warn("  - #{e}") }
  abort
end
puts "[gen_table_toml] ✓ 三方交叉校验通过（#{KARMAROND_KEYS.size} 卡尔马 + #{CHARAMAKE_TABLES.size} キャラメイク + SEISEN + #{EDITION1_TABLES.size} 1版表）"

if options[:check_only]
  puts "[gen_table_toml] --check：仅校验，未写盘（md5 应保持不变）"
  exit 0
end

existing = File.read(TARGET_FILE, encoding: "UTF-8")

# --- 块 1：T1.4 卡尔马 ---
unless want_karma.empty?
  block14, count14 = generate_block(want_karma)
  puts "[gen_table_toml] T1.4 卡尔马用例 #{count14} 条（#{want_karma.join(',')} × 4 骰型 × 边界矩阵）"
  updated = splice_block(existing, block14, BEGIN_MARK, END_MARK)
else
  updated = existing
  puts "[gen_table_toml] 未选中卡尔马表，跳过 T1.4 块"
end

# --- 块 2：T1.5 キャラメイク + SEISEN ---
unless want_chara.empty?
  chara_block, chara_count = generate_chara_make_block
  seisen_block, seisen_count = generate_seisen_block
  err15_block, err15_count = generate_error_cases(T15_ERROR_CASES)
  t15_total = chara_count + seisen_count + err15_count
  puts "[gen_table_toml] T1.5 キャラメイク #{chara_count} 条 + 聖戦 #{seisen_count} 条 + 异常系 #{err15_count} 条 = #{t15_total} 条"

t15_block = <<~HEADER
  # ---------------------------------------------------------------------------
  # T1.5 キャラメイク 6 表 + 聖戦判定
  #
  # 语义要点（逐条对应 kimi-code T1.5 评审预警）：
  #   - **绝不钳制**：6 表 datarange 恒为 null（天狗 dice 字面量无 "+x"，
  #     isTableAdditionValue 不置位 → 直接 data[出目]）。故掷骰路径越界不可达，
  #     无钳制档位；越界只在 `@n` 定値路径可达，且按天狗语义**不响应**。
  #   - **d36 = 单颗 36 面**（钉版快照 Node 实测：resArray 恒长 1，5000 次
  #     掷骰 sum ∈ [1,36]，且 6 表均无 d66Option），**非** D66 组合表。
  #   - **`@n` = 定値显示**（天狗 /fnd 的 ASCII 等价）：不掷骰，rands 为空数组。
  #     与卡尔马的 `@±n`（補正值）是**同字符两语义**，按表区分。
  #     前导零 / 超上界一律不响应（天狗 data 是字符串键直查，"03" 查不到）。
  #   - 每个出目都同时生成「掷骰」与「@n 定値」两条用例，且生成器断言
  #     **两者正文逐字相同**——这同时钉住"表文本改写后的一致性"。
  #     NJI[6] 的正文引用了 `NJI@n`，该命令在本文件下方作为真实用例存在，
  #     文本里的命令引用因此是可执行的（不是死引用）。
  #   - **SEISEN**：2D6、合計 <= DKK 成功。输出骨架逐字对齐天狗
  #     wasshoi.js:42-44；成功文案来自 yml judge 段（源自 JSON）。
  #     天狗 KIND.SEISEN 正则无 `!`（对比 WASSHOI 分支有），故 `SEISEN!9` 不响应。
  # ---------------------------------------------------------------------------

  #{chara_block}

  # --- 聖戦判定（SEISEN）---
  #{seisen_block}

  #{err15_block}
HEADER

  updated = splice_block(updated, t15_block, BEGIN_MARK_T15, END_MARK_T15)
else
  puts "[gen_table_toml] 未选中キャラメイク表，跳过 T1.5 块"
end

# --- 块 3：T1.6 追加判定扩展（倍率 / 记忆符）---
#
# 本批**没有表键**可归 --tables（命令面是父类的 `K{x}[...]`，不是 Ex 自有表），
# 故跟随默认全量生成：无 --tables 时一定产出；指定 2版 表时也一并产出
# （它与所选表无关，不产出反而会让该语法无任何回归保护）。
#
# ⚠ **但只选 1版 表时必须跳过**（T1.7）：T1.6 的命令面是 NinjaSlayer2Ex 父类的
#   `K{x}[...]`——`[KENHU]` 字符类、`RE_JUDGE_DICEROLL` 都是 2版 形态；
#   1版 父类 NinjaSlayer 压根没有这些命令，写进 NinjaSlayerEx.toml 会产出
#   恒不响应的假用例。而本批要写的是 NinjaSlayerEx.toml（只选 1版 表时），
#   留在那里只会污染。故：`want_karma/want_chara` 全空（即 only_ed1）则跳过。
if want_karma.empty? && want_chara.empty?
  puts "[gen_table_toml] 只选中 1版 表，跳过 T1.6 块（其命令面属 NinjaSlayer2Ex 父类）"
  t16_count = 0
else
  t16_body, t16_count = generate_appendix_ex_block
  puts "[gen_table_toml] T1.6 追加判定扩展（倍率 / 记忆符）#{t16_count} 条"

  t16_block = <<~HEADER
    # ---------------------------------------------------------------------------
    # T1.6 追加判定扩展：倍率 `[>=y*N]` + 记忆符 `[J]` / `[L]`
    #
    # 语义要点（全部来自天狗真函数实测，见 docs/t1.6-report.md §2）：
    #   - **倍率 = 命中数 × N**（Appendix.js:19 + dice.js:158-162 逐个命中累加）。
    #     小数倍率合法且**不取整**（`2.5` 命中 2 → 5）；裸 `*` 与 `*0` 都给出倍率 0
    #     （天狗 `Number('')` === 0）；`*非数字` 天狗降级为 1，本扩展**收紧为不响应**。
    #   - **记忆符 = 标签化的 [=y]**（NJShortcutTranslator.js:124 appTransration 实测）：
    #     `[J]` → `[=1]` + 标签「ジツ暴走」、`[L]` → `[=6]` + 标签「LAN直結出目6数」。
    #     计数逻辑与 `[=y]` **逐字相同**，实现走等价改写（无第二套计数代码）。
    #   - **合计値不并入成功数**（有意偏离天狗，见报告 §5）：沿用父类模型，
    #     倍率只放大追加カウント的显示值，不改变判定成败。
    #   - **`[C]` 不搬**（计划 §5 拍板）：保上游 クリティカル判定语义，
    #     コッポ判定改用 `[=4]`（父类原生支持，本块有用例钉住）。
    #   - **三关交互**：空白截断与 upcase 的实测行为各有专门用例
    #     （`K6[J] 備考` 保留追加判定；`K6 [J]` 整段丢失）。
    #   - **S 前缀保护泛化**的受益者：`SSBX` 暗骰用例在本块内（此前不可用）。
    #
    # 父类追加判定（`[=6]` / `[S5]` / `[C]` / `[>=665+]` 等）**零改动**，
    # 由本块的父类对照用例 + NinjaSlayer2.toml 孪生对拍共同钉死。
    # ---------------------------------------------------------------------------

    #{t16_body}
  HEADER

  updated = splice_block(updated, t16_block, BEGIN_MARK_T16, END_MARK_T16)
end

# --- 块 4：T1.7 1版 9 表（**另一个游戏系统**，落 NinjaSlayerEx.toml）---
#
# 与前三个块的关键差异（逐条见下面生成块的头注）：
#   ① game_system = "NinjaSlayerEx"（前三个都是 NinjaSlayer2Ex）；
#   ② **绝不钳制**、**无 `@±x` 補正**——本批 `@n` 只是定値表示；
#   ③ 索引用**表级 min_index**（CYBER / SUMMON 是 2D6 表 → min_index = **2**，
#      其余为 1），不是 2版 的恒 1；
#   ④ JITSB / KRM 的天狗别名字典（10 / 13 个键）按**唯一骰型**收敛成
#      `_A` / `_B` / `_C`；同骰的别名（KRM 的 `,D` 实为 1d6，与 `,A` 同骰）
#      **不提供**后缀，避免凭空多出无差别的可选项。
unless want_ed1.empty?
  ed1_body, ed1_count = generate_edition1_block
  err17_body, err17_count = generate_edition1_error_block
  t17_total = ed1_count + err17_count
  puts "[gen_table_toml] T1.7 1版 9 表 #{ed1_count} 条 + 异常系 #{err17_count} 条 = #{t17_total} 条"

  t17_block = <<~HEADER
  # ---------------------------------------------------------------------------
  # T1.7 天狗 1版 9 表（WS / JITSB / DKKI / KRM / CYBER / BIOCYBER / SOUL / SUMMON / BK）
  #
  # 语义要点（逐条对应 T1.7 评审预警）：
  #   - **骨架选型：9 表全部「无钳制」**。天狗的钳制分支挂在
  #     `isTableAdditionValue` 之下（NJDiscordReply.js:91-97），而该标志仅当
  #     dice 字面量含 "+x" 时置位（SearchTableDiceroll.js:56-77）。
  #     1版 9 表的 dice 实测只有 1d6 / 1d6+1 / 2d6 / 1d36 —— **无一张含 +x**
  #     → 恒走 else 分支 `data[出目]` → ledger 的 datarange 9 条全为 null。
  #     故本块**没有钳制档位**，输出里也不可能出现「（クランプ）」标注。
  #   - **索引 = 表级 min_index，逐表不同**：CYBER / SUMMON 是 2D6 表、
  #     data 键 2..12 → min_index = **2**；其余 7 表为 1。
  #     写成恒 1 会让这 2 张表整体错位一格（出目 2 取到第 2 号表项）。
  #     KRM_C（2D6，出目 2..12）与 JITSB_B（1D6+1，出目 2..7）的下界档
  #     专门钉住这一点。
  #   - **`@出目` = 定値表示**（天狗 /fnd 的 ASCII 等价，不掷骰）。
  #     与 2版 KRS 族的 `@±n`（補正值）是**同字符两语义**，按系统/表区分。
  #     前导零 / 越界（`WS@0` / `WS@7` / `CYBER@1` / `BK@37`）一律不响应
  #     （天狗 data 是字符串键直查，"03" 查不到 → 不响应）。
  #   - **别名收敛**：JITSB 的 10 个天狗别名 → 2 个唯一骰型（A=1D6 / B=1D6+1）；
  #     KRM 的 13 个 → 3 个（A=1D6 / B=1D6+1 / C=2D6）。
  #     同骰的别名（KRM 的 `,D` 实为 1d6）**不提供**后缀（给了与 `_A` 无差别）。
  #     越界后缀（`WS_C` / `KRM_D` / `JITSB_C`）不响应。
  #   - **1版 1D6 出目顺序与 2版不同**（1版 3=天井破壊 / 5=KRAAAAASH 窓），
  #     属天狗 1版原文，**忠实照搬不做对齐**。
  #   - **d36 = 单颗 36 面**（T1.5 已实证，非 D66 组合表）。
  #   - **暗骰（S 前缀）可用**：1版 14 个前缀两两无遮蔽，`SOUL` / `SUMMON` 不受
  #     `(S)?` 回溯影响。本块含 `SSOUL` / `SBK` / `SBIOCYBER` / `SWS` 四条
  #     暗骰用例，作为 prefixes_pattern 覆写的回归钉。
  #   - 親类命令（NJ / EV / AT / EL / SB）**零改动**，
  #     由本文件上方的父类孪生用例钉死。
  # ---------------------------------------------------------------------------

  #{ed1_body}

  #{err17_body}
HEADER

  updated = splice_block(updated, t17_block, BEGIN_MARK_T17, END_MARK_T17)
else
  puts "[gen_table_toml] 未选中 1版 表，跳过 T1.7 块"
  t17_total = 0
end

File.write(TARGET_FILE, updated, encoding: "UTF-8")
parts = []
parts << "T1.4 #{count14} 条" if want_karma.any?
parts << "T1.5 #{t15_total} 条" if want_chara.any?
parts << "T1.6 #{t16_count} 条" if t16_count.positive?
parts << "T1.7 #{t17_total} 条" if want_ed1.any?
puts "[gen_table_toml] ✓ 已写入 #{TARGET_FILE.sub("#{ROOT}/", '')}（#{parts.join(' + ')}）"

