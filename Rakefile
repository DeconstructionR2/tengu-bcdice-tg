# frozen_string_literal: true

# ============================================================================
# Rakefile — T1.1 spike 实证 + 引擎层 toml 测试入口
#
# 任务：
#   - test:default  跑 test/test_ext_game_system_commands.rb（T1.1④ 自研 runner）
#   - spike         跑 test/spike_t1_1.rb（四项机制一次性验证）
#   - test          上面两个连跑
#   - 单文件筛选走环境变量：TEST_TARGET=NinjaSlayer2 rake test
#
# 设计要点：
#   - 全用 bundle exec，避免误用系统 ruby；
#   - runner 自身已能加载 game_systems/ + i18n/，不需要在 Rakefile 里再 require；
#   - rake test 期望一切 pass，否则 non-zero exit，符合 Docker multi-stage 「测试失败=构建失败」
#     纪律（计划 §13 R9）。
# ============================================================================

require "rake/testtask"

# toml runner（T1.1④ + 引擎层 toml 测试入口）
Rake::TestTask.new(:default) do |t|
  t.libs << "test"
  t.libs << "."
  t.test_files = FileList[
    "test/test_ext_game_system_commands.rb",
    "test/i18n_guard_test.rb",
    "test/karmarond_semantics_test.rb",
    "test/ledger_consistency_test.rb",
    "test/engine_structure_test.rb",
  ]
  t.warning = false
  t.verbose = false
end

# 把 rake test 默认指向 :default
task test: :default

# spike 单独跑
desc "跑 T1.1 四项机制一次性 spike（test/spike_t1_1.rb）"
task :spike do
  ruby "-Itest", "test/spike_t1_1.rb"
end

desc "跑 T1.6 追加判定扩展 spike（Preprocessor 三关 + 天狗语义对照）"
task :spike_t16 do
  ruby "-Itest", "test/spike_t1_6.rb"
end

# T1.6 天狗侧真函数探针（Node 跑钉版快照，只读 references/src）。
# 与 Ruby 侧 spike 分开：它验的是**天狗**的行为（纯参考），
# 而 ruby spike 验的是 **BCDice 引擎**的形变（本仓库的实际约束）。
# 两者都挂进 full，避免「只跑了一边就下结论」。
desc "跑 T1.6 天狗侧真函数探针（node scripts/spike_t1_6.js）"
task :spike_t16_js do
  sh "node scripts/spike_t1_6.js"
end

# rake test 时默认连跑 spike + 引擎层测试，回归一气呵成
desc "全量：spike（4 项机制）+ 引擎层 toml 测试（默认全量）"
task full: %i[spike default]

# T1.6 全量：两边的探针 + 两边的测试
desc "T1.6 全量：天狗侧探针（node）+ 引擎侧探针（ruby）+ 全部测试"
task full_t16: %i[spike_t16_js spike_t16 spike default]

# 别名
task :"test:default" => :default
task :"test:spike" => :spike
task :"test:full" => :full
