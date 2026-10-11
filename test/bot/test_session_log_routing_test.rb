# frozen_string_literal: true

# ============================================================================
# test/bot/test_session_log_routing_test.rb — 录制挂钩端到端（T3.5）
#
# 这是本任务的核心验收面：**真身 handler + 真 SessionLogRecorder + 真 Router
# + 真 SQLite（:memory:）**，走完整 dispatch 路径验证计划 §13 第 6 项定案：
#
#   - recording 中**全部文本消息**（含此前被静默丢弃的闲聊）落 log_entries
#   - bot 自己的掷骰结果（run_handler 代发的 handler 返回值）落 is_bot=1
#   - 非文本消息记占位符（msg_kind + 中文占位）；服务消息不录
#   - 暂停/继续真的拦/放；end 后不再录
#   - **暗骰不落盘（负向钉）**：/secret 命令消息与 ephemeral 结果都不进 log；
#     S 前缀裸骰的秘密结果也不进
#   - 话题级隔离：两话题各录各的；General(=1) 归群级（E4）
#   - 回调/迁移/编辑消息不进录制（extract_message 与分流顺序的实证）
#   - LOGGING_ENABLED=0（recorder enabled: false）→ 一次 DB 都不碰
#   - 录制故障（store 炸）不影响消息处理（回复照发、warn 留痕）
#   - end 导出两个 document 发回原作用域（txt 逐行序 = seq 升序）
#
# 全程 mock，零联网、零真 token、零 bot 进程、零引擎 bootstrap（假 resolver）。
# ============================================================================

require "minitest/autorun"
require "logger"
require_relative "test_helper"
require_relative "../../bot/router"
require_relative "../../bot/handlers/dice"
require_relative "../../bot/handlers/help"
require_relative "../../bot/handlers/secret_dice"
require_relative "../../bot/handlers/session_log"
require_relative "../../bot/session_log_recorder"
require_relative "../../db/connection"
require_relative "../../db/settings"
require_relative "../../db/secrets"
require_relative "../../db/session_logs"

class TestSessionLogRouting < Minitest::Test
  include BotTestHelper

  CHAT_ID = -1_000_000_000_123_456_789
  OTHER_CHAT_ID = -1_000_000_000_987_654_321
  TOPIC = 88
  OTHER_TOPIC = 99
  GENERAL_TOPIC = 1
  BOT_NAME = "example_dice_bot"

  # 假引擎结果（DiceHandler / SecretDiceHandler 的注入面）：text + secret?
  FakeResult = Struct.new(:text, :secret_flag) do
    def secret?
      !!secret_flag
    end
  end

  # 假规则类：SB → サツバツ！；2d6>=4 → 判定成功！；S2d6 → 秘密结果（secret?=true）
  class FakeSystem
    def self.eval(text)
      case text.to_s
      when "S2d6" then FakeResult.new("秘密のサツバツ结果", true)
      when "SB" then FakeResult.new("サツバツ！")
      when "2d6>=4" then FakeResult.new("判定成功！")
      end
    end
  end

  # 记录文档内容的假 api（content 在调用那一刻读，见 handler 测试同款注释）
  class RecordingDocApi
    DocCall = Struct.new(:chat_id, :thread_id, :caption, :filename, :path, :content,
                         keyword_init: true)

    attr_reader :documents

    def initialize
      @documents = []
    end

    def send_document(chat_id, file, thread_id: nil, caption: nil, filename: nil)
      @documents << DocCall.new(chat_id: chat_id, thread_id: thread_id, caption: caption,
                                filename: filename, path: file.to_s,
                                content: File.read(file))
      :fake_document
    end
  end

  # 谁碰谁炸的假 store（enabled: false 的短路钉）
  class BoomStore
    def method_missing(name, *args, **kwargs, &blk) # rubocop:disable Style/MissingRespondToMissing
      raise "should not be called: #{name}"
    end

    def respond_to_missing?(_name, _include_private = false)
      true
    end
  end

  def setup
    @conn = TenguDB::Connection.open(path: ":memory:")
    @store = TenguDB::SessionLogs.new(@conn, logger: Logger.new(IO::NULL))
    @settings = TenguDB::Settings.new(@conn)
    @secrets = TenguDB::Secrets.new(@conn)

    @api, @fake, = build_api
    @doc_api = RecordingDocApi.new

    @recorder = TelegramBot::SessionLogRecorder.new(
      session_logs: @store, bot_name: BOT_NAME, logger: Logger.new(IO::NULL)
    )
    @log_handler = TelegramBot::Handlers::SessionLogHandler.new(
      session_logs: @store, logger: Logger.new(IO::NULL)
    )
    @dice = TelegramBot::Handlers::DiceHandler.new(
      settings: @settings, resolver: ->(_id) { FakeSystem }, logger: Logger.new(IO::NULL)
    )
    @secret = TelegramBot::Handlers::SecretDiceHandler.new(
      settings: @settings, secrets: @secrets,
      resolver: ->(_id) { FakeSystem }, logger: Logger.new(IO::NULL)
    )

    @router = build_router
  end

  def teardown
    @conn.close
  end

  def build_router(recorder: @recorder, doc_api: @doc_api)
    handlers = { log: @log_handler, help: TelegramBot::Handlers::HelpHandler.new }
               .merge(TelegramBot::Handlers::DiceHandler.registry(@dice))
               .merge(TelegramBot::Handlers::SecretDiceHandler.registry(@secret))
    # doc_api 经 context[:api] 被 /log end 使用；send_text 走 @api（build_api 假身）
    TelegramBot::Router.new(
      api: RecordingApiShim.new(@api, doc_api),
      handlers: handlers,
      bot_username: BOT_NAME,
      aux_systems: [],
      session_log: recorder,
      logger: Logger.new(IO::NULL)
    )
  end

  # 把 doc_api 的 send_document 叠在真 TelegramApi 上（其余 send_text 原样走）
  class RecordingApiShim
    def initialize(text_api, doc_api)
      @text_api = text_api
      @doc_api = doc_api
    end

    def send_document(...)
      @doc_api.send_document(...)
    end

    def method_missing(name, *args, **kwargs, &blk)
      @text_api.public_send(name, *args, **kwargs, &blk)
    end

    def respond_to_missing?(name, include_private = false)
      @text_api.respond_to?(name, include_private) || super
    end
  end

  # --- 夹具：gem 真类型消息（与 listen 接缝的真实形状一致）-------------------

  def text_message(text:, chat_id: CHAT_ID, thread_id: nil, user_id: 42,
                   first_name: "Tester", message_id: 1)
    attrs = { message_id: message_id, date: 1_700_000_000,
              chat: { id: chat_id, type: "supergroup" },
              from: { id: user_id, is_bot: false, first_name: first_name },
              text: text }
    attrs[:message_thread_id] = thread_id if thread_id
    Telegram::Bot::Types::Message.new(**attrs)
  end

  def dispatch_text(text, **kwargs)
    @router.dispatch(text_message(text: text, **kwargs))
  end

  def entries(log_id)
    @store.entries(log_id)
  end

  def active_log(thread_id: nil)
    @store.active(chat_id: CHAT_ID, thread_id: thread_id)
  end

  def sent_texts
    @fake.sent_messages.map { |m| m[:text] }
  end

  # =========================================================================
  # A. 基本录制面
  # =========================================================================

  def test_nothing_is_recorded_without_a_log
    dispatch_text("今天天气不错3d6")
    dispatch_text("/roll SB")

    assert_equal 0, @conn.get_first_value("SELECT count(*) FROM session_logs").to_i
    assert_equal 0, @conn.get_first_value("SELECT count(*) FROM log_entries").to_i
  end

  def test_new_announcement_is_the_first_entry_then_chat_and_rolls_follow
    dispatch_text("/log new 接线团")
    dispatch_text("闲聊一条")
    dispatch_text("/roll SB")

    log = active_log
    refute_nil log, "开录后应有进行中的 log"
    rows = entries(log.id)

    # 序：开录回执(1) → 闲聊(2) → /roll SB 命令本身(3) → 掷骰结果(4)
    assert_equal [1, 2, 3, 4], rows.map(&:seq)
    assert_match(/\A已开始录制「接线团」/, rows[0].content)
    assert rows[0].bot?, "开录回执是 bot 输出（录制从回执这一条开始）"
    assert_equal "闲聊一条", rows[1].content
    assert_equal 42, rows[1].user_id
    assert_equal "Tester", rows[1].sender_name
    refute rows[1].bot?
    assert_equal "/roll SB", rows[2].content, "命令消息本身也录（群内可见）"
    assert_equal "サツバツ！", rows[3].content, "掷骰结果逐字落盘"
    assert rows[3].bot?, "bot 掷骰结果 is_bot=1"
    assert_nil rows[3].user_id
    assert_equal BOT_NAME, rows[3].sender_name
  end

  def test_bot_result_matches_what_actually_went_to_the_group
    dispatch_text("/log new 一致性")
    dispatch_text("/roll SB")

    wire = sent_texts.last
    stored = entries(active_log.id).last.content

    assert_equal wire, stored, "落盘内容与代发原文逐字一致"
  end

  def test_aux_track_rolls_are_recorded_too
    dispatch_text("/log new 辅助轨")
    dispatch_text("2d6>=4") # 裸 ASCII 辅助轨（不依赖规则前缀的通用表达式）

    rows = entries(active_log.id)

    # 序：开录回执(1) → 裸式(2) → 结果(3)
    assert_equal 3, rows.size
    assert_equal "2d6>=4", rows[1].content
    refute rows[1].bot?
    assert_equal "判定成功！", rows[2].content
    assert rows[2].bot?, "辅助轨的掷骰结果同样落 is_bot=1"
  end

  def test_non_text_messages_are_recorded_as_placeholders
    dispatch_text("/log new 占位")
    @router.dispatch(Telegram::Bot::Types::Message.new(
                       message_id: 2, date: 1_700_000_000,
                       chat: { id: CHAT_ID, type: "supergroup" },
                       from: { id: 42, is_bot: false, first_name: "Tester" },
                       photo: [{ file_id: "f", file_unique_id: "u", width: 90, height: 90 }]
                     ))
    @router.dispatch(Telegram::Bot::Types::Message.new(
                       message_id: 3, date: 1_700_000_000,
                       chat: { id: CHAT_ID, type: "supergroup" },
                       from: { id: 42, is_bot: false, first_name: "Tester" },
                       voice: { file_id: "v", file_unique_id: "u", duration: 3 }
                     ))

    rows = entries(active_log.id)
    kinds = rows.map(&:msg_kind)
    assert_equal %w[text photo voice], kinds
    assert_equal "（照片）", rows[1].content
    assert_equal "（语音）", rows[2].content
    assert_equal 42, rows[1].user_id, "占位条目也要有发送者（人发的）"
  end

  def test_service_messages_are_not_recorded
    dispatch_text("/log new 服务消息")
    @router.dispatch(Telegram::Bot::Types::Message.new(
                       message_id: 4, date: 1_700_000_000,
                       chat: { id: CHAT_ID, type: "supergroup" },
                       from: { id: 42, is_bot: false, first_name: "Tester" },
                       new_chat_title: "改了个群名"
                     ))

    rows = entries(active_log.id)
    assert_equal 1, rows.size, "只有开录回执；服务消息不录"
  end

  # =========================================================================
  # B. 暂停 / 继续 / 结束
  # =========================================================================

  def test_pause_resume_gate_the_recording
    dispatch_text("/log new 状态机团")
    dispatch_text("闲聊1")
    dispatch_text("/log off")
    dispatch_text("闲聊2")
    dispatch_text("/log on")
    dispatch_text("闲聊3")

    contents = entries(active_log.id).map(&:content)

    # 语义：录的是「到达时正在录」的消息——
    #   /log off 在暂停生效**前**到达 → 录；/log on 在暂停**中**到达 → 不录；
    #   暂停期间的闲聊不录；继续后恢复录。
    assert_includes contents, "闲聊1"
    assert_includes contents, "/log off"
    refute_includes contents, "闲聊2", "暂停期间的发言绝不录"
    refute_includes contents, "/log on", "/log on 到达时还在暂停中（语义即如此，见注释）"
    assert_includes contents, "闲聊3", "继续后恢复录"
    assert(contents.any? { |c| c.include?("已继续录制") }, "继续回执（发送时已恢复）录了")
  end

  def test_end_stops_recording_and_exports_two_documents_to_the_same_scope
    dispatch_text("/log new 收工团", thread_id: TOPIC)
    dispatch_text("闲聊一条", thread_id: TOPIC, message_id: 2)
    dispatch_text("/roll SB", thread_id: TOPIC, message_id: 3)

    dispatch_text("/log end", thread_id: TOPIC, message_id: 4)

    assert_equal 2, @doc_api.documents.size, "end 必须发 txt + json"
    txt, json = @doc_api.documents
    assert_equal CHAT_ID, txt.chat_id
    assert_equal TOPIC, txt.thread_id, "导出文件发回原话题"
    assert_equal TOPIC, json.thread_id

    # txt 逐行序 = seq 升序：回执 → 闲聊 → /roll SB → 结果 → /log end
    body_lines = txt.content.split("\n").drop(5)
    assert_equal 5, body_lines.size
    assert_match(/\A\[0001\] .+ \[bot\] #{BOT_NAME}：已开始录制「收工团」/, body_lines[0])
    assert_match(/\A\[0002\] .+ Tester：闲聊一条\z/, body_lines[1])
    assert_match(/\A\[0003\] .+ Tester：\/roll SB\z/, body_lines[2])
    assert_match(/\A\[0004\] .+ \[bot\] #{BOT_NAME}：サツバツ！\z/, body_lines[3])
    assert_match(/\A\[0005\] .+ Tester：\/log end\z/, body_lines[4],
                 "结束命令本身在 finish 生效前到达 → 也录进最后一条")

    # end 之后不再录
    dispatch_text("收工后的闲聊", message_id: 5)
    assert_equal 5, entries(@store.list(chat_id: CHAT_ID, thread_id: TOPIC).first.id).size
  end

  # =========================================================================
  # C. 暗骰防线（负向钉）
  # =========================================================================

  def test_secret_command_and_ephemeral_result_never_hit_the_log
    dispatch_text("/log new 暗骰团")
    before = entries(active_log.id).size

    dispatch_text("/secret SB")

    # 暗骰本身必须已经真的执行了（ephemeral 发出、落 secrets 表）——
    # 否则这条测试可能只是「什么都没发生」
    ephemeral = @fake.sent_messages.find do |m|
      m[:ephemeral_message_parameters] || m.key?(:ephemeral_message_parameters)
    end
    refute_nil ephemeral, "sanity：/secret 应经 ephemeral 发送"
    assert_includes ephemeral[:text], "サツバツ！"

    rows = entries(active_log.id)
    assert_equal before, rows.size, "录制中执行 /secret：条目数不许变"
    refute(rows.any? { |r| r.content.include?("サツバツ！") },
           "暗骰结果文本绝不能出现在录制里")
    refute(rows.any? { |r| r.content.include?("/secret") },
           "ephemeral 命令消息本身也不录（群内不可见的东西不落盘）")
  end

  def test_s_prefix_aux_secret_result_is_not_recorded_but_visible_input_is
    dispatch_text("/log new S 前缀")
    dispatch_text("S2d6")

    rows = entries(active_log.id)

    assert_includes rows.map(&:content), "S2d6",
                    "裸 S 骰式本身是群内可见消息（照录）"
    refute(rows.any? { |r| r.content.include?("秘密のサツバツ结果") },
           "S 前缀的秘密结果绝不落盘")
    assert_equal 1, rows.count(&:bot?), "bot 条目只有开录回执一条（秘密结果没有对应条目）"
  end

  # =========================================================================
  # D. 作用域隔离 / E4
  # =========================================================================

  def test_two_topics_record_separately
    dispatch_text("/log new 话题甲", thread_id: TOPIC)
    dispatch_text("甲的话", thread_id: TOPIC, message_id: 2)
    dispatch_text("乙的无人录的话", thread_id: OTHER_TOPIC, message_id: 3)
    dispatch_text("/log new 话题乙", thread_id: OTHER_TOPIC, message_id: 4)
    dispatch_text("乙的话", thread_id: OTHER_TOPIC, message_id: 5)

    a = entries(active_log(thread_id: TOPIC).id).map(&:content)
    b = entries(active_log(thread_id: OTHER_TOPIC).id).map(&:content)

    assert_includes a, "甲的话"
    refute_includes a, "乙的无人录的话", "没开录的话题不录"
    refute_includes a, "乙的话", "两话题各录各的"
    assert_includes b, "乙的话"
    refute_includes b, "甲的话"
  end

  def test_general_topic_falls_into_the_group_log
    dispatch_text("/log new 群级团")                                   # 群级（thread 0）
    dispatch_text("来自 General 的发言", thread_id: GENERAL_TOPIC, message_id: 2)

    log = active_log # thread_id 省略 = 群级行
    assert_includes entries(log.id).map(&:content), "来自 General 的发言",
                    "E4：General=1 与群级 0 同一作用域 → 录进群级 log"
  end

  def test_other_chats_are_untouched
    dispatch_text("/log new 本群团")
    @router.dispatch(text_message(text: "别群的发言", chat_id: OTHER_CHAT_ID, message_id: 9))

    contents = entries(active_log.id).map(&:content)
    assert(contents.any? { |c| c.include?("已开始录制「本群团」") })
    refute(contents.any? { |c| c.include?("别群的发言") }, "别的 chat_id 的消息不进本作用域")
    assert_nil @store.active(chat_id: OTHER_CHAT_ID), "别的群也没有冒出一条 log"
  end

  # =========================================================================
  # E. 排除面：回调 / 迁移 / 编辑
  # =========================================================================

  def test_callback_queries_migration_and_edited_messages_are_not_recorded
    dispatch_text("/log new 排除面")
    before = entries(active_log.id).size

    callback = Telegram::Bot::Types::CallbackQuery.new(
      id: "q1", from: { id: 42, is_bot: false, first_name: "Tester" },
      chat_instance: "ci", data: "sec:nonexistent"
    )
    @router.dispatch(callback)

    migration = Telegram::Bot::Types::Message.new(
      message_id: 7, date: 1_700_000_000,
      chat: { id: CHAT_ID, type: "supergroup" },
      from: { id: 42, is_bot: false, first_name: "Tester" },
      migrate_to_chat_id: -1_009_876_543_210
    )
    @router.dispatch(migration)

    edited = Telegram::Bot::Types::Message.new(
      message_id: 8, date: 1_700_000_000, edit_date: 1_700_000_100,
      chat: { id: CHAT_ID, type: "supergroup" },
      from: { id: 42, is_bot: false, first_name: "Tester" },
      text: "编辑过的消息"
    )
    @router.dispatch(edited)

    assert_equal before, entries(active_log.id).size, "三类 update 都不进录制"
  end

  # =========================================================================
  # F. 开关短路与故障兜底
  # =========================================================================

  def test_disabled_recorder_never_touches_the_database_even_with_a_recording_log
    # 预置一条**正在录**的 log（直接经 store，绕开 recorder）
    log = @store.start(chat_id: CHAT_ID, name: "已存在的录制").log

    boom_recorder = TelegramBot::SessionLogRecorder.new(
      session_logs: BoomStore.new, enabled: false, logger: Logger.new(IO::NULL)
    )
    router = build_router(recorder: boom_recorder)

    router.dispatch(text_message(text: "闲聊一条"))
    router.dispatch(text_message(text: "/roll SB", message_id: 2))
    router.dispatch(text_message(text: "/log new 插队", message_id: 3))

    assert_equal 0, entries(log.id).size, "enabled: false → 一条都不落（BoomStore 没炸即证明没碰 DB）"
  end

  def test_recorder_failure_does_not_break_message_processing
    flaky = Class.new do
      def record_incoming(**_kw)
        raise "store down"
      end

      def record_bot_output(**_kw)
        raise "store down"
      end
    end.new
    router = build_router(recorder: flaky)

    router.dispatch(text_message(text: "闲聊一条"))
    router.dispatch(text_message(text: "/roll SB", message_id: 2))

    assert_includes sent_texts, "サツバツ！", "录制故障时掷骰照常回复（不杀消息处理）"
  end

  # =========================================================================
  # G. 端到端全旅程（开录 → 一段 → 导出）
  # =========================================================================

  def test_full_journey_via_router
    dispatch_text("/log new 全旅程", thread_id: TOPIC)
    dispatch_text("我们开始吧", thread_id: TOPIC, message_id: 2)
    dispatch_text("/roll SB", thread_id: TOPIC, message_id: 3)
    dispatch_text("/log end", thread_id: TOPIC, message_id: 4)

    rows = entries(@store.list(chat_id: CHAT_ID, thread_id: TOPIC).first.id)
    contents = rows.map(&:content)
    assert_match(/\A已开始录制/, contents[0], "回执是第一条")
    assert_equal ["我们开始吧", "/roll SB", "サツバツ！", "/log end"], contents[1..],
                 "条目序 = 事件发生序（闲聊 → 命令 → 结果 → 结束命令）"

    # txt 逐行核对：第 5+i 行必须以「：seq 内容」结尾（即行序 = seq 序）
    txt = @doc_api.documents.first.content
    body = txt.split("\n").drop(5)
    assert_equal contents.size, body.size
    contents.each_with_index do |content, i|
      assert body[i].end_with?("：#{content}"),
             "第 #{i + 1} 行应为 seq #{i + 1} 的内容；实际：#{body[i].inspect}"
      assert_includes body[i], format("[%04d]", i + 1)
    end
  end
end
