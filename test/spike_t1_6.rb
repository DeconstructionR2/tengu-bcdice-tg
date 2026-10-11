# frozen_string_literal: true

# ============================================================================
# T1.6 spike：倍率 `[>=5*2]` / 记忆符 `[J]` `[L]` 的三方语义实测
#
# 跑法：bundle exec ruby -Itest test/spike_t1_6.rb
# 与 spike_t1_1.rb 同形：一次性把「先测后写」的前置事实全部打出来。
#
# 实测表：
#   §1 BCDice Preprocessor 三关（trim_after_whitespace / replace_parentheses /
#      replace_implicit_d + upcase）对 `[...]` 追加判定语法的实际影响
#   §2 父类 NinjaSlayer2 现有追加判定的输出基线（含 [=6] / [>=5] / [S5] / [C]）
#   §3 父类 RE_JUDGE_DICEROLL 对 T1.6 新形态的匹配情况（为何必须扩正则）
#   §4 天狗侧语义对照（由 spike_t1_6.js 跑真函数后把结果粘贴进 §4 注释块）
# ============================================================================

# 引擎初始化统一走共享 bootstrap（T2.1）
require_relative "../lib/engine_bootstrap"
EngineBootstrap.bootstrap!(reload_backend: true)

require_relative "randomizer_mock"

EX = BCDice::GameSystem::NinjaSlayer2Ex
PA = BCDice::GameSystem::NinjaSlayer2

def hr(title)
  puts "\n#{'=' * 78}\n#{title}\n#{'=' * 78}"
end

$failures = 0

def check(label)
  ok = yield
  $failures += 1 unless ok
  puts format("  [%s] %s", ok ? "OK  " : "NG  ", label)
  ok
end

# kimi 总复核 P4：spike 也要有非零 exit——否则挂在门禁路径上等于装饰。
at_exit do
  if $failures.zero?
    puts "\n✅ spike_t1_6 全部通过"
  else
    puts "\n❌ spike_t1_6 有 #{$failures} 项失败"
    exit(1)
  end
end

# ---------------------------------------------------------------------------
hr("§1 Preprocessor 三关实测（`[...]` 追加判定语法进引擎前的形变）")
# ---------------------------------------------------------------------------
gs = EX.new("2B6>=4[J]")
CASES = [
  "2B6>=4[>=5*2]",
  "2B6>=4[J]",
  "2B6>=4[L]",
  "2B6>=4[=1]",
  "2B6>=4[>=5*2] 备注",
  "2B6 >=4[J]",
  "2B6>=4 [J]",
  "2B6>=4[(3*2)]",
  "2D6>=4[>=5*2]",
  "6[J]",
  "K6[J]",
  "2B6>=4[j]",
]
CASES.each do |c|
  out = BCDice::Preprocessor.process(c.dup, gs)
  printf("  %-24s -> %s\n", c.inspect, out.inspect)
end

puts "\n  三关结论："
check("① trim_after_whitespace：`2B6>=4[>=5*2] 备注` 被截到空白前（追加判定仍在）") do
  BCDice::Preprocessor.process("2B6>=4[>=5*2] 备注".dup, gs) == "2B6>=4[>=5*2]"
end
check("①b trim_after_whitespace：`2B6 >=4[J]` 被截成 `2B6`（骰式后有空格 → 整段追加判定丢失）") do
  BCDice::Preprocessor.process("2B6 >=4[J]".dup, gs) == "2B6"
end
check("①c trim_after_whitespace：`2B6>=4 [J]` 被截成 `2B6>=4`（追加判定前有空格 → 整段丢失）") do
  BCDice::Preprocessor.process("2B6>=4 [J]".dup, gs) == "2B6>=4"
end
check("② replace_parentheses：`[(3*2)]` 被算成 [6]（父类 appendix 不含括号，扩展也需回避）") do
  BCDice::Preprocessor.process("2B6>=4[(3*2)]".dup, gs) == "2B6>=4[6]"
end
check("②b `[>=5*2]` 不含括号 → 原样透传") do
  BCDice::Preprocessor.process("2B6>=4[>=5*2]".dup, gs) == "2B6>=4[>=5*2]"
end
check("③ replace_implicit_d：`2D6>=4[...]` **不触发**（规则要求 D 后是非单词字符，`2D6` 的 D 后是数字）") do
  BCDice::Preprocessor.process("2D6>=4[>=5*2]".dup, gs) == "2D6>=4[>=5*2]"
end
check("③b replace_implicit_d：`2D>=4[>=5*2]` **会触发**（D 后是 `>`）→ 变 2D6") do
  BCDice::Preprocessor.process("2D>=4[>=5*2]".dup, gs) == "2D6>=4[>=5*2]"
end
check("④ upcase：`[j]` 在 dice_command 里被 upcase 成 `[J]`（在 Preprocessor 之后）") do
  # base.rb:247 `command = command.upcase if @enabled_upcase_input` 发生在 dice_command 内，
  # Preprocessor 之后 → 记忆符大小写等价由该行保证
  EX.new("2B6>=4[j]").instance_variable_get(:@enabled_upcase_input) == true
end
check("④b upcase 实际生效：Preprocessor 保留小写，dice_command 之后才是大写") do
  pre = BCDice::Preprocessor.process("K6[j]".dup, gs)
  r = EX.new("K6[j]")
  r.randomizer = RandomizerMock.new([[1, 6], [6, 6], [6, 6], [6, 6], [6, 6], [6, 6]])
  pre == "K6[j]" && r.eval.text.include?("ジツ暴走")
end

# ---------------------------------------------------------------------------
hr("§2 父类追加判定输出基线（T1.6 必须与之共存，不得漂移）")
# ---------------------------------------------------------------------------
def run(klass, command, rands)
  inst = klass.new(command)
  inst.randomizer = RandomizerMock.new(rands.map { |v| [v, 6] })
  res = inst.eval
  res.nil? ? nil : res.text
end

BASE_RANDS = [1, 2, 3, 4, 5, 6]
[
  "K6",
  "K6[>=5]",
  "K6[=6]",
  "K6[=1]",
  "K6[>=5][=6]",
  "K6[S]",
  "K6[C]",
  "K6[>=5+]",
].each do |cmd|
  puts format("  %-16s Ex   -> %s", cmd, run(EX, cmd, BASE_RANDS).inspect)
  pa = run(PA, cmd, BASE_RANDS)
  ex = run(EX, cmd, BASE_RANDS)
  puts format("  %-16s 父类 -> %s   %s", "", pa.inspect, pa == ex ? "[一致]" : "[!! 漂移 !!]")
end

# ---------------------------------------------------------------------------
hr("§3 父类 RE_JUDGE_DICEROLL 对 T1.6 新形态的匹配（= 必须扩正则的证据）")
# ---------------------------------------------------------------------------
RE = PA::RE_JUDGE_DICEROLL
[
  "K6[>=5]",
  "K6[=6]",
  "K6[>=5*2]",
  "K6[J]",
  "K6[L]",
  "K6[J][>=5*2]",
  "2B6>=4[>=5*2]",
].each do |cmd|
  m = RE.match(cmd)
  puts format("  %-18s -> %s", cmd, m ? "匹配 骰部=#{m[1].inspect} 追加=#{m[2].inspect}" : "不匹配")
end

puts "\n  结论：倍率形态 `[>=5*2]` 与记忆符 `[J]`/`[L]` 均**落在父类正则之外**"
puts "       → T1.6 必须自带一条 dice 部同源的宽松正则（不能只改 proc_appendix）。"

# ---------------------------------------------------------------------------
hr("§4 command_pattern 覆盖（toml runner 对每条用例断言 input 命中）")
# ---------------------------------------------------------------------------
[
  "K6[J]", "K6[L]", "K6[>=5*2]", "2B6>=4[>=5*2]", "6[J]", "K6[=6]",
].each do |cmd|
  puts format("  %-18s -> %s", cmd, EX.command_pattern.match?(cmd) ? "命中" : "!! 不命中（toml 会红）")
end

puts "\n== 倍率 / 记忆符的实测输出（天狗语义对照的 BCDice 侧）=="
[
  ["K6[>=5*2]", [5, 6, 1, 1, 1, 1]],
  ["K6[J]",     [1, 2, 3, 4, 5, 6]],
  ["K6[L]",     [1, 2, 3, 4, 5, 6]],
  ["K6[J][L]",  [1, 6, 2, 3, 4, 5]],
].each do |cmd, vals|
  printf("  %-14s -> %s\n", cmd, run(EX, cmd, vals))
end

# ---------------------------------------------------------------------------
hr("§5 天狗侧对照（由 scripts/spike_t1_6.js 采集；此处只留结论）")
# ---------------------------------------------------------------------------
puts <<~TXT
  天狗真函数（references/src/.../classes/dice.js + Appendix.js）的实测结论
  见 docs/t1.6-report.md §2（由 scripts/spike_t1_6.js 跑出后抄录）：
    - 倍率 = appendix 逐命中累加 → 命中数 × 倍率（bairitsu 默认 1）
    - [J] → '=1/ジツ暴走'、[L] → '=6/LAN直結出目6数'（即 [=1] / [=6] 的记忆符）
    - 合计 sum = 成功数 + Σ(各 appendix 命中数 × 倍率)
  BCDice 侧本任务的选择（与父类一致的模型）：appendix 只做「追加カウント」展示，
  不并入 達成値 → 倍率只放大追加カウント 的显示值。偏离在报告 §5 申报。
TXT

# ---------------------------------------------------------------------------
hr("§6 天狗侧异常倍率对照表（scripts/spike_t1_6.js 实测 → BCDice 侧实跑）")
# ---------------------------------------------------------------------------
puts "  形态              BCDice 侧响应情况（天狗侧对照见 scripts/spike_t1_6.js §B）"
puts "  " + "-" * 62
[">=5*2", ">=5*0", ">=5*", ">=5*x", ">=5*2.5", ">=5*101"].each do |ap|
  cmd = "K6[#{ap}]"
  ours = run(EX, cmd, [5, 6, 1, 1, 1, 1])
  printf("  %-15s %s\n", cmd, ours.nil? ? "不响应" : ours[0, 44])
end