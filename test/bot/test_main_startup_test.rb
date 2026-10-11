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
      require #{File.join(REPO, "bot/handlers/dice").inspect}
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
      assert_includes out, "[T2.4]", "启动日志前缀应更新为 T2.4"
      assert_includes out, "handlers/dice.rb", "启动日志应列出已挂的 handler"
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
      assert_equal 3, sent.size, "应发 3 条（/roll SB、裸 SB、/system），/help 静默：#{texts.inspect}"
      assert_includes texts[0], "サツバツ", "/roll SB 应出力"
      assert_includes texts[1], "サツバツ", "裸 SB（辅助轨）应出力"
      assert_includes texts[2], "本话题", "/system 话题内应明示作用域"
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
end