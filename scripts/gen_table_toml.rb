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
require "optparse"
require "fileutils"

ROOT = File.expand_path("..", __dir__)
LEDGER_PATH = File.join(ROOT, "references/extracted/i18n_key_ledger.yml")
I18N_DIR = File.join(ROOT, "i18n")
GAME_SYSTEMS_DIR = File.join(ROOT, "game_systems")
DEFAULT_TARGET = File.join(ROOT, "test/data/NinjaSlayer2Ex.toml")

# T1.4 的 5 张カルマロンダリング表（ledger ascii_key）。顺序固定 = yml 顺序。
DEFAULT_TABLES = %w[KRS KRZ KRA KRO KRY].freeze

# 本批表所属的游戏系统 ID（写入每条用例的 game_system 字段）
GAME_SYSTEM_ID = "NinjaSlayer2Ex"

options = {
  tables: DEFAULT_TABLES,
  check_only: false,
  target: DEFAULT_TARGET
}
OptionParser.new do |o|
  o.banner = "用法: bundle exec ruby scripts/gen_table_toml.rb [选项]"
  o.on("--tables K1,K2", "逗号分隔的表 ASCII 键（默认 KRS,KRZ,KRA,KRO,KRY）") { |v| options[:tables] = v.split(",").map(&:strip) }
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

def generate_error_cases
  out = []
  ERROR_CASES.each do |cmd|
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
  [out.join("\n"), ERROR_CASES.size]
end

def generate_block
  out = []
  total = 0

  KARMAROND_KEYS.each do |key|
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
BEGIN_MARK = "# >>> BEGIN GENERATED: T1.4 KARMAROND"
END_MARK = "# <<< END GENERATED: T1.4 KARMAROND"

def splice_block(existing, block)
  b = existing.index(BEGIN_MARK)
  e = existing.index(END_MARK)
  if b && e
    abort_with("哨兵块嵌套/顺序异常（END 在 BEGIN 之前）") if e < b

    head = existing[0...b]
    tail = existing[(e + END_MARK.length)..] || ""
    return "#{head}#{BEGIN_MARK}\n#{block}\n#{END_MARK}#{tail}"
  elsif b || e
    abort_with("哨兵不成对（BEGIN/END 只出现一个）——请手工检查 #{TARGET_FILE}")
  else
    sep = existing.end_with?("\n") || existing.empty? ? "" : "\n"
    "#{existing}#{sep}\n#{BEGIN_MARK}\n#{block}\n#{END_MARK}\n"
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
puts "[gen_table_toml] ✓ 三方交叉校验通过（#{KARMAROND_KEYS.size} 表）"

# 只生成请求的表（--tables 可裁剪）
requested = options[:tables]
unless requested.sort == KARMAROND_KEYS.sort
  abort_with("本生成器目前只覆盖 T1.4 的 #{KARMAROND_KEYS.join(',')}（--tables 给了 #{requested.join(',')}）")
end

block, count = generate_block
puts "[gen_table_toml] 用例 #{count} 条（#{KARMAROND_KEYS.join(',')} × 4 骰型 × 边界矩阵）"

if options[:check_only]
  puts "[gen_table_toml] --check：仅校验，未写盘（md5 应保持不变）"
  exit 0
end

existing = File.read(TARGET_FILE, encoding: "UTF-8")
updated = splice_block(existing, block)
File.write(TARGET_FILE, updated, encoding: "UTF-8")
puts "[gen_table_toml] ✓ 已写入 #{TARGET_FILE.sub("#{ROOT}/", '')}（哨兵块内 #{count} 条用例）"