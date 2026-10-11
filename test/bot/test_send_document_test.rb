# frozen_string_literal: true

# ============================================================================
# test/bot/test_send_document_test.rb — send_document 三形态（T2.1 评审修复 F2/F4）
#
# 本文件补的是 T2.1 交付时的**零覆盖**地带。修复前的实现把
# String / IO / Tempfile 全塞进 File.open：
#
#   io = file.is_a?(String) || file.is_a?(IO) || file.is_a?(Tempfile) \
#         ? File.open(file, "rb") : file
#
# 两个真实缺陷：
#   1. **无 to_path 的 IO**（IO.pipe 的读端、socket 等）→ File.open 抛 TypeError，
#      根本发不出去；
#   2. **File / Tempfile** 被按 to_path **重开** → 丢掉 fd 语义：调用方 rewind
#      到的位置、已 unlink 但仍打开的 fd、共享偏移量全部作废，gem 读到的是
#      「按路径从头另开一份」的内容。
#
# 修复后的契约：
#   - String 路径 → 本方法 File.open(file, "rb")，ensure 里 close；
#   - IO / Tempfile → **原样**透传给 gem/faraday（multipart 直接读 fd），
#     且本方法**不碰**它的生命周期；
#   - 白名单缺失降级 → raw 通道无法上传文件 → 明确 raise SendError（F4）。
# ============================================================================

require "tempfile"
require "tmpdir"
require "fileutils"
require "stringio"
require_relative "test_helper"

class TestSendDocument < Minitest::Test
  include BotTestHelper

  # 记录 gem **在调用那一刻**看到的 document 形态与内容。
  # 必须在调用时快照：修复后的实现会在 ensure 里 close 自己打开的 File，
  # 事后读已经来不及（这正是「fd 语义」可断言的原因）。
  #
  # 关键：**不 rewind** —— gem（faraday multipart）是从当前偏移读的，
  # rewind 会把「调用方已读到第 4 字节」这一证据抹掉，让用例失去鉴别力。
  class RecordingApi
    attr_reader :calls

    def initialize
      @calls = []
    end

    def send_document(**params)
      doc = params[:document]
      @calls << {
        params: params,
        document: doc,
        content: read_from_current_position(doc)
      }
      :fake_document
    end

    private

    def read_from_current_position(doc)
      return nil unless doc.respond_to?(:read)

      doc.read
    rescue IOError, Errno::ESPIPE, Errno::EINVAL
      nil
    end
  end

  def build_doc_api(fake = RecordingApi.new, **opts)
    clock = BotTestHelper::FakeClock.new
    sleeper = BotTestHelper::FakeSleeper.new(clock)
    http = BotTestHelper::FakeHttpExecutor.new
    api = TelegramBot::TelegramApi.new(token: FAKE_TOKEN,
                                      api_client: BotTestHelper::FakeClient.new(fake),
                                      sleeper: sleeper, clock: clock,
                                      http_executor: http, **opts)
    [api, fake, sleeper, http]
  end

  def with_tmp(content, name = "log.txt")
    dir = Dir.mktmpdir
    path = File.join(dir, name)
    File.binwrite(path, content)
    yield path
  ensure
    FileUtils.remove_entry(dir) if dir && File.directory?(dir)
  end

  # --- 形态 1：String 路径 → 本方法自己 File.open --------------------------

  def test_string_path_is_opened_as_file_and_content_reaches_gem
    with_tmp("hello log") do |path|
      api, fake, = build_doc_api
      api.send_document(77, path)

      call = fake.calls.fetch(0)
      assert_kind_of File, call[:document], "String 路径应被打开成 File 交给 gem"
      assert_equal "hello log", call[:content], "gem 必须能读到文件真实内容"
      assert_equal 77, call[:params][:chat_id]
    end
  end

  def test_string_path_file_is_closed_after_send
    with_tmp("x", "log2.txt") do |path|
      api, fake, = build_doc_api
      api.send_document(77, path)

      document = fake.calls.fetch(0)[:document]
      assert_predicate document, :closed?,
                       "本方法自己打开的 IO 必须在 ensure 里关闭（不漏 fd）"
    end
  end

  # --- 形态 2：Tempfile → 原样透传，不重开 --------------------------------

  def test_tempfile_is_passed_through_untouched
    Tempfile.create("tengu-log") do |tf|
      tf.binmode
      tf.write("tempfile payload")
      tf.rewind

      api, fake, = build_doc_api
      api.send_document(77, tf)

      assert_same tf, fake.calls.fetch(0)[:document],
                  "Tempfile 必须**原样**传给 gem（按 to_path 重开会丢掉 fd 语义）"
      refute_predicate tf, :closed?, "调用方传进来的 IO 不得被本方法关闭"
    end
  end

  # 鉴别力核心：修复前是 File.open(tf.path, "rb")，得到的是**另一个 File 对象**
  # 且内容按路径从头读。assert_same 钉住对象同一性。
  def test_tempfile_content_comes_from_caller_fd_not_a_reread
    Tempfile.create("tengu-fd") do |tf|
      tf.binmode
      tf.write("0123456789")
      tf.rewind
      tf.read(4) # 调用方已读到第 4 字节

      api, fake, = build_doc_api
      api.send_document(77, tf)

      assert_same tf, fake.calls.fetch(0)[:document],
                  "修复前会被 File.open(tf.path) 重开成另一个 File —— 对象同一性断言在此鉴别"
      # gem 应从调用方 fd 的当前位置继续读；若被重开则会从 0 读到 "0123"
      assert_equal "456789", fake.calls.fetch(0)[:content]
    end
  end

  # --- 形态 3：裸 IO（无 to_path，如 IO.pipe）→ 原样透传 --------------------
  #
  # 这是修复前必炸的形态：File.open(IO.pipe_r) → TypeError。

  def test_plain_io_without_to_path_is_passed_through
    reader, writer = IO.pipe
    begin
      writer.write("piped bytes")
      writer.close

      api, fake, = build_doc_api
      api.send_document(77, reader) # 修复前此处 TypeError

      assert_same reader, fake.calls.fetch(0)[:document],
                  "无 to_path 的 IO 必须原样透传（修复前 File.open 会 TypeError）"
      assert_equal "piped bytes", fake.calls.fetch(0)[:content]
      refute_predicate reader, :closed?, "调用方的 IO 生命周期归调用方，本方法不得关闭"
    ensure
      reader.close unless reader.closed?
      writer.close unless writer.closed?
    end
  end

  def test_already_closed_io_is_still_passed_through
    io = StringIO.new("in memory")
    io.close

    api, fake, = build_doc_api
    # 不应抛 TypeError/IOError —— 本方法对非 String 一律不碰 fd
    api.send_document(77, io)

    assert_same io, fake.calls.fetch(0)[:document]
  end

  # --- 附属参数与配速 -----------------------------------------------------

  def test_caption_and_thread_are_passed
    with_tmp("y", "log3.txt") do |path|
      api, fake, = build_doc_api
      api.send_document(-100_5, path, thread_id: 88, caption: "跑团 log")

      params = fake.calls.fetch(0)[:params]
      assert_equal "跑团 log", params[:caption]
      assert_equal 88, params[:message_thread_id]
      refute params.key?(:parse_mode), "默认纯文本不应带 parse_mode"
    end
  end

  def test_parse_mode_is_configurable
    with_tmp("y", "log5.txt") do |path|
      api, fake, = build_doc_api(parse_mode: "Markdown")
      api.send_document(77, path)

      assert_equal "Markdown", fake.calls.fetch(0)[:params][:parse_mode]
    end
  end

  def test_document_is_paced_per_chat_across_threads
    fake = RecordingApi.new
    clock = BotTestHelper::FakeClock.new
    sleeper = BotTestHelper::FakeSleeper.new(clock)
    api = TelegramBot::TelegramApi.new(token: FAKE_TOKEN,
                                      api_client: BotTestHelper::FakeClient.new(fake),
                                      sleeper: sleeper, clock: clock)

    Tempfile.create("tengu-pace") do |tf|
      tf.write("a")
      tf.rewind
      api.send_document(5, tf, thread_id: 1)
      api.send_document(5, tf, thread_id: 2) # 同聊天不同话题 → 仍须配速（F1）
    end

    assert_equal 1, sleeper.calls.size,
                 "send_document 也走每聊天配速（同群跨话题仍要等，否则 forum 多话题撞 429）"
    assert_equal 2, fake.calls.size
  end

  # --- F4：raw 降级是死路，必须明确报错而不是静默发坏请求 ------------------

  def test_raw_fallback_raises_send_error_instead_of_sending_broken_json
    gem_like = BotTestHelper::FakeGemLikeApi.new(missing: ["sendDocument"])
    api, _fake, _sleeper, http = build_doc_api(gem_like)

    with_tmp("z", "log4.txt") do |path|
      err = assert_raises(TelegramBot::SendError) { api.send_document(77, path) }

      assert_match(/raw 通道暂不支持文件上传/, err.message)
      assert_match(/T3\.5/, err.message, "错误文案须指明 multipart 的后置任务号")
      assert_empty http.calls, "绝不允许把 File 塞进 JSON body 静默发出坏请求"
      assert_empty gem_like.documents, "白名单缺失 → gem 侧不应真的派发成功"
    end
  end

  # 业务 bug 型 NoMethodError（receiver 不是 api）→ 原样抛出，绝不降级。
  # 用真实存在的 String 路径，让 File.open 先成功，再在 gem 调用处抛错。
  def test_business_bug_no_method_error_is_re_raised_not_downgraded
    bug = NoMethodError.new("undefined method `gone' for nil", :gone, [], receiver: nil)
    fake = BotTestHelper::FakeApi.new(raise_on: { send_document: bug })
    api, _f, _s, http = build_doc_api(fake)

    with_tmp("w", "log6.txt") do |path|
      assert_raises(NoMethodError) { api.send_document(77, path) }
      assert_empty http.calls, "业务 bug 不得降级走 raw"
    end
  end
end
