# frozen_string_literal: true

# ============================================================================
# test/bot/test_session_log_handler_test.rb — /log handler（T3.5）
#
# 覆盖计划 §8 T3.5 / §6（/log new/on/off/end/list）/ §13 第 6 项 / §12 R8：
#   - 子命令与文案：new/off/on/end/list/help + 未知子命令 + 无参用法
#   - 状态机经 handler 的观察面：开录确认、暂停/继续、重复操作、无进行中
#   - end 导出：txt 逐行序（seq 升序）+ 头部 + 格式；json 结构断言；
#     **两个 document 发回原作用域**（chat/thread/caption/filename 透传）；
#     发送失败不假装成功（回执如实说失败）；临时文件发完即删
#   - list：空态 / 清单渲染 / 作用域隔离 / 超上限提示
#   - LOGGING_ENABLED=0（enabled: false）：**每个子命令**统一「未启用」，
#     且一次 store 都不碰（注入见谁咬谁的假 store 钉死短路）
#
# 全程 mock，零联网、零真 token、零 bot 进程。
# ============================================================================

require "minitest/autorun"
require "logger"
require "json"
require_relative "test_helper"
require_relative "../../bot/handlers/session_log"
require_relative "../../db/connection"
require_relative "../../db/session_logs"

class TestSessionLogHandler < Minitest::Test
  CHAT_ID = -1_000_000_000_123_456_789
  TOPIC = 88
  OTHER_TOPIC = 99

  # 记录发送的假 api：content 在**调用那一刻**读（handler 发完就删临时目录，
  # 事后读就来不及了——与 send_document 测试的 RecordingApi 同一手法）
  class RecordingApi
    Call = Struct.new(:chat_id, :thread_id, :caption, :filename, :path, :content, keyword_init: true)

    attr_reader :documents

    def initialize(raise_on_document: nil)
      @documents = []
      @raise_on_document = raise_on_document
    end

    def send_document(chat_id, file, thread_id: nil, caption: nil, filename: nil)
      raise @raise_on_document if @raise_on_document

      @documents << Call.new(
        chat_id: chat_id, thread_id: thread_id, caption: caption, filename: filename,
        path: file.to_s, content: File.read(file)
      )
      :fake_document
    end
  end

  # 谁碰它谁炸的假 store：验证 enabled: false 的「一次 DB 都不碰」是真短路
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
    @api = RecordingApi.new
    @handler = TelegramBot::Handlers::SessionLogHandler.new(
      session_logs: @store, logger: Logger.new(IO::NULL)
    )
  end

  def teardown
    @conn.close
  end

  def call(args, chat_id: CHAT_ID, thread_id: nil, user_id: 42, api: @api, handler: @handler)
    handler.call(name: "log", args: args, chat_id: chat_id, thread_id: thread_id,
                 user_id: user_id, api: api)
  end

  # 预置一条**录制中**的日志（含三条条目：用户/ bot / 照片占位）并返回 log
  def seed_log_with_entries(name: "接线log", thread_id: nil)
    log = @store.start(chat_id: CHAT_ID, thread_id: thread_id, name: name).log
    @store.append_entry(log_id: log.id, sender_name: "Tester", user_id: 42,
                        is_bot: 0, msg_kind: "text", content: "闲聊一条")
    @store.append_entry(log_id: log.id, sender_name: "骰子bot", user_id: nil,
                        is_bot: 1, msg_kind: "text", content: "サツバツ！")
    @store.append_entry(log_id: log.id, sender_name: "Tester", user_id: 42,
                        is_bot: 0, msg_kind: "photo", content: "（照片）")
    log
  end

  # --- 用法与基本分派 -------------------------------------------------------

  def test_no_args_shows_usage
    out = call("")

    %w[new off on end list].each { |sub| assert_includes out, "/log #{sub}" }
  end

  def test_help_subcommand_is_the_same_usage
    assert_equal call(""), call("help")
  end

  def test_unknown_subcommand
    out = call("export")

    assert_includes out, "未知子命令"
    assert_includes out, "/log help"
  end

  def test_handler_ignores_commands_that_are_not_log
    assert_nil @handler.call(name: "roll", args: "new x", chat_id: CHAT_ID, thread_id: nil)
    assert_nil @handler.call(name: nil, args: "new x", chat_id: CHAT_ID, thread_id: nil)
  end

  def test_handler_is_silent_without_chat_id
    assert_nil call("new x", chat_id: 0)
    assert_nil @handler.call(name: "log", args: "new x", chat_id: nil, thread_id: nil)
  end

  # --- new -----------------------------------------------------------------

  def test_new_starts_recording_and_announces_in_group
    out = call("new 第一次跑团")

    assert_includes out, "已开始录制"
    assert_includes out, "第一次跑团"
    assert_includes out, "本群", "群级作用域的措辞"
    log = @store.active(chat_id: CHAT_ID)
    assert log.recording?
    assert_equal "第一次跑团", log.name
  end

  def test_new_in_topic_uses_topic_wording_and_scope
    out = call("new 话题团", thread_id: TOPIC)

    assert_includes out, "本话题"
    assert @store.active(chat_id: CHAT_ID, thread_id: TOPIC).recording?
    assert_nil @store.active(chat_id: CHAT_ID), "话题开录不该动群级"
  end

  def test_new_requires_a_name
    out = call("new")

    assert_includes out, "/log new <名>"
    assert_nil @store.active(chat_id: CHAT_ID)
    assert_includes call("new    "), "/log new <名>", "全空白名字同拒"
  end

  def test_new_refuses_while_active_and_points_at_the_running_one
    call("new 先来的团")

    out = call("new 后来的团")

    assert_includes out, "已有进行中的录制"
    assert_includes out, "先来的团"
    assert_includes out, "/log end"
  end

  def test_new_refuses_bad_name_at_db_layer
    out = call("new #{'あ' * 101}")

    assert_includes out, "这个名字用不了"
    assert_nil @store.active(chat_id: CHAT_ID)
  end

  # --- off / on -------------------------------------------------------------

  def test_off_and_on_round_trip
    call("new 接线团")

    paused = call("off")
    assert_includes paused, "已暂停"
    assert @store.active(chat_id: CHAT_ID).paused?

    again = call("off")
    assert_includes again, "已处于暂停状态", "重复暂停要明示现状，不装成功"

    resumed = call("on")
    assert_includes resumed, "已继续录制"
    assert @store.active(chat_id: CHAT_ID).recording?

    again = call("on")
    assert_includes again, "本来就在进行中"
  end

  def test_off_on_without_active_report_no_active
    assert_includes call("off"), "没有进行中的录制"
    assert_includes call("on"), "没有进行中的录制"
  end

  # --- end / 导出 -----------------------------------------------------------

  def test_end_without_active_reports_no_active
    out = call("end")

    assert_includes out, "没有进行中的录制"
    assert_empty @api.documents
  end

  def test_end_exports_txt_and_json_back_to_the_same_scope
    call("new 接线log", thread_id: TOPIC)
    @store.append_entry(log_id: @store.active(chat_id: CHAT_ID, thread_id: TOPIC).id,
                        sender_name: "Tester", user_id: 42, is_bot: 0,
                        msg_kind: "text", content: "闲聊一条")

    out = call("end", thread_id: TOPIC)

    assert_includes out, "已结束录制"
    assert_includes out, "共 1 条"
    assert_includes out, "已发送"

    assert_equal 2, @api.documents.size, "end 必须发 txt + json 两个文件"
    txt, json = @api.documents
    assert_equal CHAT_ID, txt.chat_id
    assert_equal TOPIC, txt.thread_id, "thread 透传（forum 不掉话题）"
    assert_equal CHAT_ID, json.chat_id
    assert_equal TOPIC, json.thread_id
    assert_equal "tengu-log-#{@store.list(chat_id: CHAT_ID, thread_id: TOPIC).first.id}.txt",
                 txt.filename
    assert_includes txt.caption, "「接线log」"
    assert_includes txt.caption, "txt 导出（1 条）"
    assert_includes json.caption, "json 导出（1 条）"

    # 发完即删：文档路径在调用返回后应不存在（临时目录已清理）
    refute File.exist?(txt.path), "临时文件必须发完即删（txt）"
    refute File.exist?(json.path), "临时文件必须发完即删（json）"
  end

  def test_group_level_end_sends_without_thread
    call("new 群级团")

    call("end")

    assert_equal 2, @api.documents.size
    @api.documents.each do |doc|
      assert_nil doc.thread_id, "群级/General 作用域必须不发 message_thread_id（0→nil 归一）"
    end
  end

  def test_end_from_paused_still_exports
    call("new 暂停收工")
    call("off")

    out = call("end")

    assert_includes out, "已结束录制"
    assert_equal 2, @api.documents.size
    assert @store.find(@store.list(chat_id: CHAT_ID).first.id).ended?
  end

  def test_txt_export_is_sequenced_and_formatted
    seed_log_with_entries

    out = call("end")
    assert_includes out, "已结束录制"
    txt = @api.documents.first.content
    lines = txt.split("\n")

    assert_equal "===== 跑团 log：接线log =====", lines[0]
    assert_equal "作用域：群 #{CHAT_ID}", lines[1]
    assert_match(/\A时间段：.+\z/, lines[2])
    assert_equal "条目数：3", lines[3]
    assert_equal "-----", lines[4]

    # 逐行序 = seq 升序；bot 条目带 [bot] 前缀；非文本占位原样呈现
    assert_match(/\A\[0001\] .+ Tester：闲聊一条\z/, lines[5])
    assert_match(/\A\[0002\] .+ \[bot\] 骰子bot：サツバツ！\z/, lines[6])
    assert_match(/\A\[0003\] .+ Tester：（照片）\z/, lines[7])
    assert_equal 8, lines.size, "没有多余尾行（尾部只有换行）"
    assert txt.end_with?("\n")
  end

  def test_json_export_structure
    seed_log_with_entries(thread_id: TOPIC)

    call("end", thread_id: TOPIC)
    payload = JSON.parse(@api.documents.last.content)

    assert_equal "tengu-bcdice-tg/session-log", payload["format"]
    assert_equal 1, payload["version"]
    log = payload["log"]
    assert_equal "接线log", log["name"]
    assert_equal CHAT_ID, log["chat_id"]
    assert_equal TOPIC, log["thread_id"]
    assert_equal "ended", log["status"]
    refute_nil log["ended_at"]

    entries = payload["entries"]
    assert_equal 3, entries.size
    first = entries[0]
    assert_equal 1, first["seq"]
    assert_equal "Tester", first["sender_name"]
    assert_equal 42, first["user_id"]
    assert_equal false, first["is_bot"]
    assert_equal "text", first["msg_kind"]
    assert_equal "闲聊一条", first["content"]

    bot = entries[1]
    assert_equal true, bot["is_bot"]
    assert_nil bot["user_id"], "bot 条目 user_id 为 null"
    assert_equal "サツバツ！", bot["content"]

    photo = entries[2]
    assert_equal "photo", photo["msg_kind"]
    assert_equal "（照片）", photo["content"]
    assert_equal [1, 2, 3], entries.map { |e| e["seq"] }
  end

  def test_export_failure_is_reported_not_disguised
    failing = RecordingApi.new(raise_on_document: RuntimeError.new("boom"))
    call("new 会失败")
    @store.append_entry(log_id: @store.active(chat_id: CHAT_ID).id,
                        sender_name: "T", user_id: 1, is_bot: 0, content: "x")

    out = call("end", api: failing)

    assert_includes out, "已结束录制"
    assert_includes out, "导出文件发送失败"
    refute_includes out, "已发送", "发送失败绝不能报「已发送」"
    assert @store.find(@store.active(chat_id: CHAT_ID)&.id || @store.list(chat_id: CHAT_ID).first.id).ended?,
           "发送失败不回滚已结束状态（数据都在库里）"
  end

  # --- list -----------------------------------------------------------------

  def test_list_empty_scope
    out = call("list")

    assert_includes out, "还没有跑团 log"
    assert_includes out, "/log new"
  end

  def test_list_renders_logs_newest_first_with_counts
    call("new 第一个")
    @store.append_entry(log_id: @store.active(chat_id: CHAT_ID).id,
                        sender_name: "T", user_id: 1, is_bot: 0, content: "x")
    call("end")
    call("new 第二个")

    out = call("list")
    lines = out.split("\n")

    assert_includes lines[0], "本群的跑团 log"
    assert_match(/\A#\d+「第二个」 录制中（0 条） 开始 /, lines[1])
    assert_match(/\A#\d+「第一个」 已结束（1 条） /, lines[2])
  end

  def test_list_is_scope_scoped
    call("new 群级团")
    call("end")
    call("new 话题团", thread_id: TOPIC)

    group = call("list")
    topic = call("list", thread_id: TOPIC)

    assert_includes group, "群级团"
    refute_includes group, "话题团"
    assert_includes topic, "话题团"
    refute_includes topic, "群级团"
    assert_includes topic, "本话题"
  end

  def test_list_notes_the_overflow_beyond_the_limit
    limit = TelegramBot::Handlers::SessionLogHandler::LIST_LIMIT
    (limit + 1).times do |i|
      call("new 第#{i}团")
      call("end")
    end

    out = call("list")

    assert_includes out, "只显示最近 #{limit} 条"
  end

  # --- LOGGING_ENABLED=0：全链路短路 ----------------------------------------

  def test_disabled_handler_answers_disabled_for_every_subcommand
    disabled = TelegramBot::Handlers::SessionLogHandler.new(
      session_logs: BoomStore.new, enabled: false, logger: Logger.new(IO::NULL)
    )
    ["", "new x", "off", "on", "end", "list", "help"].each do |args|
      out = call(args, handler: disabled)
      assert_includes out, "未启用", "子命令 #{args.inspect} 应回「未启用」"
    end
  end

  def test_disabled_handler_never_touches_the_store
    # BoomStore 谁碰谁炸：上面逐子命令跑完都没炸，即「一次 DB 都不碰」
    disabled = TelegramBot::Handlers::SessionLogHandler.new(
      session_logs: BoomStore.new, enabled: false, logger: Logger.new(IO::NULL)
    )
    out = call("new 试图开录", handler: disabled)

    assert_includes out, "未启用"
  end

  def test_disabled_handler_exports_nothing_even_for_existing_log
    log = seed_log_with_entries
    call("end") # 先正常收起一条
    assert @store.find(log.id).ended?

    disabled = TelegramBot::Handlers::SessionLogHandler.new(
      session_logs: @store, enabled: false, logger: Logger.new(IO::NULL)
    )
    api = RecordingApi.new
    out = call("new 又一个", handler: disabled, api: api)

    assert_includes out, "未启用"
    assert_empty api.documents
    assert_nil @store.active(chat_id: CHAT_ID), "未启用时不许开录"
  end
end
