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

# --tables 可选的表全集（T1.4 卡尔马 + T1.5 キャラメイク）。
ALL_TABLES = (DEFAULT_TABLES + CHARAMAKE_TABLES).freeze

# 本批表所属的游戏系统 ID（写入每条用例的 game_system 字段）
GAME_SYSTEM_ID = "NinjaSlayer2Ex"

options = {
  tables: ALL_TABLES,
  check_only: false,
  target: DEFAULT_TARGET
}
OptionParser.new do |o|
  o.banner = "用法: bundle exec ruby scripts/gen_table_toml.rb [选项]"
  o.on("--tables K1,K2", "逗号分隔的表 ASCII 键（默认全集：卡尔马 5 + キャラメイク 6）") { |v| options[:tables] = v.split(",").map(&:strip) }
  o.on("--check", "只做三方交叉校验并预览用例数，不写盘") { options[:check_only] = true }
  o.on("--target-file PATH", "目标 toml（默认 test/data/NinjaSlayer2Ex.toml）") { |v| options[:target] = File.expand_path(v) }
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

  errors
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
TARGET_FILE = options[:target]
abort_with("找不到目标文件 #{TARGET_FILE}") unless File.exist?(TARGET_FILE)

# §4 交叉校验先行——不过就 abort，不写盘
errors = cross_validate!
unless errors.empty?
  warn("[gen_table_toml] 三方交叉校验失败（ledger ↔ 代码 ↔ yml）：")
  errors.each { |e| warn("  - #{e}") }
  abort
end
puts "[gen_table_toml] ✓ 三方交叉校验通过（#{KARMAROND_KEYS.size} 卡尔马 + #{CHARAMAKE_TABLES.size} キャラメイク + SEISEN）"

if options[:check_only]
  puts "[gen_table_toml] --check：仅校验，未写盘（md5 应保持不变）"
  exit 0
end

existing = File.read(TARGET_FILE, encoding: "UTF-8")

# --tables 裁剪：只生成请求的表所在的批（两批各自独立哨兵块）。
#
# 裁剪时**只影响本批块**——例如 `--tables NJI` 不会去动卡尔马块。
# 跨批混选（`--tables KRS,NJI`）允许：两批都会被重生成。
unknown = options[:tables] - ALL_TABLES
abort_with("未知表键 #{unknown.inspect}；可选：#{ALL_TABLES.join(',')}") unless unknown.empty?

want_karma = (options[:tables] & DEFAULT_TABLES)
want_chara = (options[:tables] & CHARAMAKE_TABLES)
# SEISEN 不在 --tables 的表键体系里（它不是表），故跟随キャラメイク批一同生成。

if want_karma.empty? && want_chara.empty?
  abort_with("--tables 未选中任何表")
end

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
# 故跟随默认全量生成：无 --tables 时一定产出；指定 --tables 时也一并产出
# （它与所选表无关，不产出反而会让该语法无任何回归保护）。
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

File.write(TARGET_FILE, updated, encoding: "UTF-8")
parts = []
parts << "T1.4 #{count14} 条" if want_karma.any?
parts << "T1.5 #{t15_total} 条" if want_chara.any?
parts << "T1.6 #{t16_count} 条"
puts "[gen_table_toml] ✓ 已写入 #{TARGET_FILE.sub("#{ROOT}/", '')}（#{parts.join(' + ')}）"