# frozen_string_literal: true

# ============================================================================
# test/bot/test_main_startup_test.rb — main.rb 接线冒烟（T2.4）
#
# 为什么要有这个：main.rb 是**入口脚本**（加载即启动长轮询，不可被 require），
# 单测只能验它的组装逻辑。本文件用**子进程 + 假 api 注入**跑真实的启动路径：
#   - 验 DiceHandler 被注册进 Router 的四个键（roll/nd/system/aux）
#   - 验 DB_PATH 生效（真建库文件、验 schema 已落地）
#   - 验启动日志里没有 token 值
#
# 做法：子进程 require 真 main.rb（它会 exit），但先把假 TelegramApi 顶进
# 常量表——即 preload 一个 shim 文件，先 require telegram-bot-ruby 与 bot 侧
# 文件、再替换 TelegramBot::TelegramApi 常量为假实现，然后 load main.rb。
# 全程零联网：假 api 不发任何 HTTP，get_me/set_my_commands 只记录。
# ============================================================================

require "minitest/autorun"
require "tmpdir"
require "json"

# 本文件不定义任何假 API 类：假 api 在下面的 shim 源码里（子进程内）就地定义，
# 因为它必须顶替 TelegramBot::TelegramApi **常量**——父进程里定义假类没有意义。
# ============================================================================
# 子进程冒烟：跑真实的 bot/main.rb 启动路径，零联网、零真 token
#
# 为什么要有这个：main.rb 是**入口脚本**（加载即启动长轮询，不可被 require），
# 测试无法直接 require 它。故用「子进程 + 常量顶替」跑真实启动路径：
#   - 验 DiceHandler 被注册进 Router 的四个键（roll/nd/system/aux 真能响应）
#   - 验 DB_PATH 生效（真建库文件、schema 落地、/system 真写库）
#   - 验启动日志不回显 token 值
# ============================================================================

class TestMainStartup < Minitest::Test
  REPO = File.expand_path("../..", __dir__)

  # shim：prepend 一个假 api 模块到**真** TelegramApi 上，再 load main.rb。
  #
  # 为什么用 prepend 而不是「换掉常量」：main.rb 会调
  # `TelegramBot::TelegramApi.commands_payload`（类方法）。换掉常量就等于
  # 把整个类（含 commands_payload/MainMenu 之外的类方法）抽走，测的是
  # 替身不是真代码。prepend 只覆盖三个点（初始化/长轮询/gem 后端），
  # 其余代码路径（MainMenu、Chunker、Router、handlers、DB）全是真的。
  def shim_source(db_path)
    <<~RUBY
      $LOAD_PATH.unshift(#{File.join(REPO, "lib").inspect})
      require "telegram/bot"
      require "logger"
      require #{File.join(REPO, "bot/config").inspect}
      require #{File.join(REPO, "bot/telegram_api").inspect}
      require #{File.join(REPO, "bot/router").inspect}
      require #{File.join(REPO, "bot/admin").inspect}
      require #{File.join(REPO, "bot/handlers/dice").inspect}
      require #{File.join(REPO, "bot/handlers/settings").inspect}
      require #{File.join(REPO, "bot/handlers/bank").inspect}
      require #{File.join(REPO, "bot/handlers/custom_table").inspect}
      require #{File.join(REPO, "lib/engine_bootstrap").inspect}

      $SENT = []
      $SLEPT = []
      $UPDATES = []
      $SET_COMMANDS = nil
      $SENT_OUT = #{File.join(File.dirname(db_path), "sent.json").inspect}

      # 假 gem 后端：只记录，不联网
      module FakeGemBackend
        def self.get_me; Struct.new(:username).new("example_dice_bot"); end
        def self.send_message(**params); $SENT << params; :ok; end
        def self.set_my_commands(**params); $SET_COMMANDS = params; true; end
        # T2.6：Admin#admin? 走 gem 的 get_chat_member（假身，零联网）。
        # 固定回 administrator —— 只验「接线通 + 权限判定用上了」，
        # 各 status 的分支由 test/bot/test_admin_test.rb 逐条覆盖。
        def self.get_chat_member(chat_id:, user_id:)
          Struct.new(:status).new("administrator")
        end
      end
      class FakeClient; def api; FakeGemBackend; end; end

      # 只覆盖「会联网」的三处：建客户端、长轮询、配速
      module FakeApiTransport
        def initialize(token:, **kw)
          kw = kw.merge(api_client: FakeClient.new,
                        sleeper: ->(s) { $SLEPT << s },
                        clock: -> { $SLEPT.sum })
          super(token: token, **kw)
        end

        def start(dispatch:)
          $UPDATES.each { |u| dispatch.call(u) }
        end
      end
      TelegramBot::TelegramApi.prepend(FakeApiTransport)

      # 假 token（形状合法以便过 Config 校验；**绝非真 token**，值不出现在任何日志）
      ENV["TELEGRAM_ENV_FILE"] = "/nonexistent-t2.4.env"
      ENV["TELEGRAM_BOT_TOKEN"] = "1234567890:FakeTokenForUnitTests0000"
      ENV["DB_PATH"] = #{db_path.inspect}

      load #{File.join(REPO, "bot/main.rb").inspect}

      File.write($SENT_OUT, JSON.dump("sent" => $SENT, "set_commands" => !!$SET_COMMANDS))
    RUBY
  end

  def run_shim(shim, dir)
    out = IO.popen(
      { "BUNDLE_GEMFILE" => File.join(REPO, "Gemfile") },
      ["bundle", "exec", "ruby", shim],
      err: %i[child out],
      chdir: REPO
    ) { |io| io.read }

    sent_file = File.join(dir, "sent.json")
    payload = File.exist?(sent_file) ? JSON.parse(File.read(sent_file)) : nil
    [out, payload]
  end

  def run_startup(db_path)
    shim = File.join(File.dirname(db_path), "shim_#{File.basename(db_path)}.rb")
    File.write(shim, shim_source(db_path))
    run_shim(shim, File.dirname(db_path))
  end

  def test_startup_registers_dice_handlers_and_uses_db_path
    Dir.mktmpdir("tengu-t2.4-main") do |dir|
      db_path = File.join(dir, "tengu.db")
      out, payload = run_startup(db_path)

      assert File.exist?(db_path), "启动应按 DB_PATH 建库文件（实际输出：#{out[0, 400]}）"
      assert_includes out, "[T2.6]", "启动日志前缀应更新为 T2.6"
      assert_includes out, "bot/handlers/dice.rb", "启动日志应列出已挂的 handler"
      assert_includes out, "handlers/settings.rb", "启动日志应确认 /settings handler 已挂（T2.6）"
      assert_includes out, "admin.rb", "启动日志应确认管理员助手已挂（T2.6）"
      assert_includes out, "migration.rb", "启动日志应确认群升级 re-key 已挂（T2.5）"
      refute_includes out, "FakeTokenForUnitTests",
                      "启动日志绝不能回显 token 值（token 纪律）"

      refute_nil payload, "子进程应写出发送记录（实际输出：#{out[0, 400]}）"
      assert payload["set_commands"], "启动应注册主轨菜单"
      assert_equal [], payload["sent"], "启动本身不该发消息（没有 update 进来）"

      # schema 落地证明 DB 层真被用上
      require "sqlite3"
      conn = SQLite3::Database.new(db_path)
      tables = conn.execute("SELECT name FROM sqlite_master WHERE type='table'").flatten
      assert_includes tables, "chat_settings"
      conn.close
    end
  end

  def test_startup_with_updates_dispatches_dice_and_system
    Dir.mktmpdir("tengu-t2.4-main") do |dir|
      db_path = File.join(dir, "tengu.db")
      # 预置三条 update：/roll SB、裸 SB、/system NinjaSlayerEx（话题内）
      shim = File.join(dir, "shim_updates.rb")
      File.write(shim, shim_source(db_path).sub(
        "$UPDATES = []",
        <<~RUBY
          $UPDATES = [
            Telegram::Bot::Types::Update.new(update_id: 1, message: Telegram::Bot::Types::Message.new(
              message_id: 1, date: 1_700_000_000,
              chat: { id: -1_000_000_000_123_456_789, type: "supergroup" },
              from: { id: 1, is_bot: false, first_name: "T" },
              message_thread_id: 88, text: "/roll SB")),
            Telegram::Bot::Types::Update.new(update_id: 2, message: Telegram::Bot::Types::Message.new(
              message_id: 2, date: 1_700_000_000,
              chat: { id: -1_000_000_000_123_456_789, type: "supergroup" },
              from: { id: 1, is_bot: false, first_name: "T" },
              message_thread_id: 88, text: "SB")),
            Telegram::Bot::Types::Update.new(update_id: 3, message: Telegram::Bot::Types::Message.new(
              message_id: 3, date: 1_700_000_000,
              chat: { id: -1_000_000_000_123_456_789, type: "supergroup" },
              from: { id: 1, is_bot: false, first_name: "T" },
              message_thread_id: 88, text: "/system NinjaSlayerEx")),
            Telegram::Bot::Types::Update.new(update_id: 4, message: Telegram::Bot::Types::Message.new(
              message_id: 4, date: 1_700_000_000,
              chat: { id: -1_000_000_000_123_456_789, type: "supergroup" },
              from: { id: 1, is_bot: false, first_name: "T" },
              message_thread_id: 88, text: "/help"))
          ]
        RUBY
      ))

      sent_file = File.join(dir, "sent.json")
      out = IO.popen(
        { "BUNDLE_GEMFILE" => File.join(REPO, "Gemfile") },
        ["bundle", "exec", "ruby", shim],
        err: %i[child out],
        chdir: REPO
      ) { |io| io.read }

      assert File.exist?(sent_file), "子进程应写出发送记录（实际输出：#{out[0, 600]}）"
      sent = JSON.parse(File.read(sent_file)).fetch("sent")

      texts = sent.map { |m| m["text"] }
      assert_equal 4, sent.size, "应发 4 条（/roll SB、裸 SB、/system、/help——菜单命令必须有应答）：#{texts.inspect}"
      assert_includes texts[0], "サツバツ", "/roll SB 应出力"
      assert_includes texts[1], "サツバツ", "裸 SB（辅助轨）应出力"
      assert_includes texts[2], "本话题", "/system 话题内应明示作用域"
      assert_includes texts[3], "命令一览", "/help 应有应答（菜单命令不许静默）"
      assert_equal 88, sent.first["message_thread_id"], "thread 应逐条透传"
      refute_includes out, "FakeTokenForUnitTests", "日志不得回显 token 值"

      # /system 的写入应落到真实 DB 的 (chat_id, 88) 行
      require "sqlite3"
      conn = SQLite3::Database.new(db_path)
      row = conn.execute(
        "SELECT game_system FROM chat_settings WHERE chat_id = ? AND thread_id = ?",
        [-1_000_000_000_123_456_789, 88]
      )
      conn.close
      assert_equal [["NinjaSlayerEx"]], row, "话题级设置应落库"
    end
  end

  # T2.6 的主验收闭环：**经 bot/main.rb 的真实接线**跑一遍
  #   /settings aux off → 裸打 SB（静默） → /roll SB（照常） → /settings aux on → 裸打 SB（恢复）
  # 并验开关真的落在**群级行**上（thread_id=0），且规则系统设置没被带偏。
  def test_startup_persists_aux_switch_and_aux_track_goes_silent
    Dir.mktmpdir("tengu-t2.6-main") do |dir|
      db_path = File.join(dir, "tengu.db")
      chat_id = -1_000_000_000_123_456_789

      # 注意：update 列表要写成**子进程里的源码文本**，不能在父进程构造
      # Telegram::Bot::Types::* 对象——父进程从不 require gem（那会真联网
      # 或至少引入副作用），单测里没有常量可构造。
      def update_src(n, text, chat_id)
        <<~RUBY.strip
          Telegram::Bot::Types::Update.new(update_id: #{n}, message: Telegram::Bot::Types::Message.new(
            message_id: #{n}, date: 1_700_000_000,
            chat: { id: #{chat_id}, type: "supergroup" },
            from: { id: 1, is_bot: false, first_name: "T" }, text: "#{text}"))
        RUBY
      end

      updates = [
        update_src(1, "/roll SB", chat_id),
        update_src(2, "SB", chat_id),
        update_src(3, "/system NinjaSlayerEx", chat_id),
        update_src(4, "/settings", chat_id),
        update_src(5, "/settings aux off", chat_id),
        update_src(6, "SB", chat_id),
        update_src(7, "/roll SB", chat_id),
        update_src(8, "/settings aux on", chat_id),
        update_src(9, "SB", chat_id)
      ].join(",\n")

      shim = File.join(dir, "shim_aux.rb")
      File.write(shim, shim_source(db_path).sub("$UPDATES = []", "$UPDATES = [\n#{updates}\n]"))

      sent_file = File.join(dir, "sent.json")
      out = IO.popen(
        { "BUNDLE_GEMFILE" => File.join(REPO, "Gemfile") },
        ["bundle", "exec", "ruby", shim],
        err: %i[child out],
        chdir: REPO
      ) { |io| io.read }

      assert File.exist?(sent_file), "子进程应写出记录（实际输出：#{out[0, 600]}）"
      texts = JSON.parse(File.read(sent_file)).fetch("sent").map { |m| m["text"] }

      # 9 条 in → 8 条 out：唯一被静默的是第 6 条（关掉后的裸 SB）。
      # 逐条对照：1 /roll SB ✓、2 裸 SB ✓、3 /system ✓、4 /settings ✓、
      #           5 aux off 确认 ✓、**6 裸 SB 静默**、7 /roll SB ✓、
      #           8 aux on 确认 ✓、9 裸 SB ✓
      assert_equal 8, texts.size,
                   "关掉后那一次裸 SB 必须静默（9 条 in / 8 条 out）：#{texts.inspect}"
      assert_includes texts[3], "当前规则系统", "/settings 无参应回总览"
      assert_includes texts[3], "辅助轨：开", "关掉之前总览应显示辅助轨是开的"
      assert_includes texts[4], "已关闭", "/settings aux off 应确认"
      assert_includes texts[5], "サツバツ", "关掉辅助轨不影响 slash 主轨"
      assert_includes texts[6], "已开启", "/settings aux on 应确认"
      assert_includes texts[7], "サツバツ", "重新打开后裸打应恢复"
      refute_includes out, "FakeTokenForUnitTests", "日志不得回显 token 值"

      require "sqlite3"
      conn = SQLite3::Database.new(db_path)
      aux = conn.execute(
        "SELECT thread_id, aux_enabled FROM chat_settings WHERE chat_id = ? AND thread_id = 0",
        [chat_id]
      )
      game = conn.execute(
        "SELECT game_system FROM chat_settings WHERE chat_id = ? AND thread_id = 0",
        [chat_id]
      )
      conn.close

      # 第 9 条把开关又打开了（流程结尾），所以库里应是 1
      assert_equal [[0, 1]], aux, "aux_enabled 应落在群级行(thread_id=0)"
      assert_equal [["NinjaSlayerEx"]], game,
                   "改辅助轨不得影响该群的规则系统设置"
    end
  end
  # T3.2 的接线闭环：**经 bot/main.rb 的真实接线**跑一遍天狗银行全流程。
  # 验的是「菜单上架的 /bank 真的有 handler 且真的会落库」（T2.6 真机教训：
  # 菜单里有的命令没 handler = 用户视角 bot 死了），而不是 handler 的语义
  # （那由 test/bot/test_bank_handler_test.rb 负责）。
  def test_startup_wires_bank_handler_end_to_end
    Dir.mktmpdir("tengu-t3.2-main") do |dir|
      db_path = File.join(dir, "tengu.db")
      chat_id = -1_000_000_000_123_456_789

      def update_src(n, text, chat_id, thread_id: nil)
        head = <<~RUBY.strip
          Telegram::Bot::Types::Update.new(update_id: #{n}, message: Telegram::Bot::Types::Message.new(
            message_id: #{n}, date: 1_700_000_000,
            chat: { id: #{chat_id}, type: "supergroup" },
            from: { id: 1, is_bot: false, first_name: "T" }, text: "#{text}"#{thread_id ? ", message_thread_id: #{thread_id}" : ""}))
        RUBY
        head
      end

      updates = [
        update_src(1, "/bank deposit 893", chat_id, thread_id: 88),
        update_src(2, "/bank item add 茶", chat_id, thread_id: 88),
        update_src(3, "/bank balance", chat_id, thread_id: 88),
        update_src(4, "/bank balance", chat_id, thread_id: 99),
        update_src(5, "/bank reset", chat_id, thread_id: 88)
      ].join(",\n")

      shim = File.join(dir, "shim_bank.rb")
      File.write(shim, shim_source(db_path).sub("$UPDATES = []", "$UPDATES = [\n#{updates}\n]"))

      sent_file = File.join(dir, "sent.json")
      out = IO.popen(
        { "BUNDLE_GEMFILE" => File.join(REPO, "Gemfile") },
        ["bundle", "exec", "ruby", shim],
        err: %i[child out],
        chdir: REPO
      ) { |io| io.read }

      assert File.exist?(sent_file), "子进程应写出记录（实际输出：#{out[0, 600]}）"
      sent = JSON.parse(File.read(sent_file)).fetch("sent")
      texts = sent.map { |m| m["text"] }

      assert_equal 5, texts.size,
                   "/bank 五条都应有应答，菜单上架命令不许静默：#{texts.inspect}"
      assert_includes texts[0], "893", "存钱应答应含金额"
      assert_includes texts[0], "👺", "893 彩蛋应经真实接线生效"
      assert_includes texts[1], "茶", "存道具应答应含道具名"
      assert_includes texts[2], "当前状况", "话题内查账有账"
      assert_includes texts[2], "893", "余额正确"
      assert_includes texts[3], "没有找到银行的记录",
                      "话题 99 从没存过，应答「查无此账」（话题级隔离）"
      assert_includes texts[4], "已重置", "清零应答"
      assert_equal 88, sent[2]["message_thread_id"], "thread 应逐条透传"
      refute_includes out, "FakeTokenForUnitTests", "日志不得回显 token 值"

      # 落库：话题 88 的账被清空后应只剩「无流水/无道具」的行或干脆无行
      require "sqlite3"
      conn = SQLite3::Database.new(db_path)
      rows = conn.execute(
        "SELECT chat_id, thread_id, sum_money FROM bank_record ORDER BY thread_id"
      )
      conn.close
      assert_empty rows, "结算后清零应真的删掉话题 88 那一行：#{rows.inspect}"
    end
  end

  # T3.4 的接线闭环：**经 bot/main.rb 的真实接线**跑一遍自定义表全流程
  # （菜单上架的 /ct 真有 handler 且真会落库；语义由 test_custom_table_* 负责）。
  def test_startup_wires_custom_table_handler_end_to_end
    Dir.mktmpdir("tengu-t3.4-main") do |dir|
      db_path = File.join(dir, "tengu.db")
      chat_id = -1_000_000_000_123_456_789

      def update_src(n, text, chat_id, thread_id: nil)
        <<~RUBY.strip
          Telegram::Bot::Types::Update.new(update_id: #{n}, message: Telegram::Bot::Types::Message.new(
            message_id: #{n}, date: 1_700_000_000,
            chat: { id: #{chat_id}, type: "supergroup" },
            from: { id: 1, is_bot: false, first_name: "T" }, text: "#{text}"#{thread_id ? ", message_thread_id: #{thread_id}" : ""}))
        RUBY
      end

      updates = [
        update_src(1, "/ct create 接线表", chat_id, thread_id: 88),
        update_src(2, "/ct dice set 接线表 b 2d6", chat_id, thread_id: 88),
        update_src(3, "/ct data set 接线表 7 七点", chat_id, thread_id: 88),
        update_src(4, "/ct show 接线表", chat_id, thread_id: 88),
        update_src(5, "/ct roll 接线表 b", chat_id, thread_id: 88),
        update_src(6, "/ct list", chat_id)
      ].join(",\n")

      shim = File.join(dir, "shim_ct.rb")
      File.write(shim, shim_source(db_path).sub("$UPDATES = []", "$UPDATES = [\n#{updates}\n]"))

      sent_file = File.join(dir, "sent.json")
      out = IO.popen(
        { "BUNDLE_GEMFILE" => File.join(REPO, "Gemfile") },
        ["bundle", "exec", "ruby", shim],
        err: %i[child out],
        chdir: REPO
      ) { |io| io.read }

      assert File.exist?(sent_file), "子进程应写出记录（实际输出：#{out[0, 600]}）"
      sent = JSON.parse(File.read(sent_file)).fetch("sent")
      texts = sent.map { |m| m["text"] }

      assert_equal 6, texts.size, "/ct 六条都应有应答（菜单上架命令不许静默）：#{texts.inspect}"
      assert_includes texts[0], "已在本群建表", "建表应答"
      assert_includes texts[1], "2d6", "设骰型应答含新骰式"
      assert_includes texts[2], "出目 7 结果已录入"
      assert_includes texts[3], "快捷骰：a : 1d6 , b : 2d6", "show 明细"
      assert_includes texts[4], "本群表「接线表」(b)：2d6 ＞ ",
                      "roll 真引擎接线（随机结果不做断言，仅断言确定前缀）"
      assert_includes texts[5], "接线表", "list 一览"
      assert_equal 88, sent[1]["message_thread_id"], "thread 应逐条透传"
      refute_includes out, "FakeTokenForUnitTests", "日志不得回显 token 值"

      # 落库：custom_tables 真被写进 DB_PATH 指向的库
      require "sqlite3"
      conn = SQLite3::Database.new(db_path)
      rows = conn.execute(
        "SELECT name, json_extract(spec, '$.dice.b') FROM custom_tables WHERE scope='private'"
      )
      conn.close
      assert_equal [["接线表", "2d6"]], rows, "自定义表应落库（含改后的骰型）"
    end
  end
end
