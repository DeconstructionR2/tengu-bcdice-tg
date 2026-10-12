# frozen_string_literal: true

# ============================================================================
# test/bot/test_admin_test.rb — 管理员权限助手（T2.6）
#
# 覆盖计划 §8 T2.6 / §0.2.4（getChatMember / 匿名管理员 / bot 管理员前提）：
#   - 各 status：creator/administrator=true；member/restricted/left/banned=false
#   - 私聊恒 true，且**零 API 调用**（豁免不是「打一次 API 看看」）
#   - fail-closed：gem 炸、两条通道都炸、响应体缺 status、api 没注入
#   - raw 兜底：gem 报错时仍应走 raw_api_call（保底通道真的被走到）
#   - 缓存：true 命中不重复打 API、TTL 过期重查、**false 不缓存**
#   - 匿名管理员（GroupAnonymousBot）：不查 API 即判否（§0.2.4）
#   - 64 位 chat_id 透传、user_id 归一、chat_type=nil 按群处理
#
# 全程零联网：假 gem api（记录调用）+ 假 raw_api_call（记录调用）。
# 时钟可注入 → TTL 用例零真实等待。
# ============================================================================

require_relative "test_helper"
require_relative "../../bot/admin"

class TestAdmin < Minitest::Test
  include BotTestHelper

  CHAT_ID = -1_000_000_000_123_456_789 # 超 32 位（§0.2.4）
  USER_ID = 42
  ANON = TelegramBot::Admin::ANONYMOUS_ADMIN_USER_ID

  # 假 ChatMember（gem 路径返回的是 dry-struct，这里用等价形态即可：
  # Admin 只读 #status，形态差异由 test_status_accepts_hash 一条覆盖）
  class FakeMember
    attr_reader :status

    def initialize(status)
      @status = status
    end
  end

  # 假 gem 后端：记录调用，可指定 status 或抛异常
  class FakeGemApi
    attr_reader :calls

    def initialize(status: "administrator", raise_on: nil)
      @status = status
      @raise_on = raise_on
      @calls = []
    end

    def get_chat_member(chat_id:, user_id:)
      @calls << { chat_id: chat_id, user_id: user_id }
      raise @raise_on if @raise_on

      FakeMember.new(@status)
    end
  end

  # 假 TelegramApi：只提供 Admin 需要的两个面（api_client + raw_api_call）
  class FakeApi
    attr_reader :gem, :raw_calls

    def initialize(gem, raw_result: nil, raw_raises: false)
      @gem = gem
      @raw_result = raw_result
      @raw_raises = raw_raises
      @raw_calls = []
    end

    def api_client
      client = Object.new
      gem = @gem
      client.define_singleton_method(:api) { gem }
      client
    end

    def raw_api_call(method, params)
      @raw_calls << { method: method, params: params }
      raise "raw boom" if @raw_raises

      @raw_result
    end
  end

  def setup
    @clock = BotTestHelper::FakeClock.new(1000.0)
  end

  # 造一个 Admin + 它的假 api（真身只有一个接口：能报调用次数）
  def admin_with(status: "administrator", raise_on: nil, raw_result: nil,
                 raw_raises: false, ttl: 300.0, api: nil)
    gem = FakeGemApi.new(status: status, raise_on: raise_on)
    fake = api || FakeApi.new(gem, raw_result: raw_result, raw_raises: raw_raises)
    admin = TelegramBot::Admin.new(api: fake, clock: @clock, ttl: ttl,
                                   logger: Logger.new(IO::NULL))
    [admin, fake]
  end

  # --- 各 status -----------------------------------------------------------

  def test_creator_and_administrator_are_admins
    { "creator" => true, "administrator" => true }.each do |status, expected|
      admin, = admin_with(status: status)
      assert_equal expected, admin.admin?(CHAT_ID, USER_ID, chat_type: "supergroup"),
                   "status=#{status} 应判为管理员"
    end
  end

  def test_non_admin_statuses_are_rejected
    %w[member restricted left banned].each do |status|
      admin, = admin_with(status: status)
      refute admin.admin?(CHAT_ID, USER_ID, chat_type: "supergroup"),
             "status=#{status} 不是管理员"
    end
  end

  def test_unknown_status_is_rejected
    # Telegram 未来加新 status 时，**默认不许**（fail-closed）：
    # 认得 creator/administrator 之外的任何值都当成管理员 = 权限放行漏洞。
    admin, = admin_with(status: "some_new_thing")
    refute admin.admin?(CHAT_ID, USER_ID, chat_type: "supergroup"),
           "未知 status 必须 fail-closed（只认白名单内的 creator/administrator）"
  end

  # --- 私聊豁免 -----------------------------------------------------------

  def test_private_chat_is_always_admin_without_api_call
    # 即便 getChatMember 会回 member：私聊场景**根本不该问**（文件头纪律 2）
    admin, fake = admin_with(status: "member")

    assert admin.admin?(12345, USER_ID, chat_type: "private"), "私聊应恒 true"
    assert_empty fake.gem.calls, "私聊豁免必须是零 API 调用（不是打了再忽略结果）"
  end

  def test_private_chat_without_api_injected_still_true
    admin = TelegramBot::Admin.new(api: nil, clock: @clock, logger: Logger.new(IO::NULL))

    assert admin.admin?(12345, USER_ID, chat_type: "private"),
           "私聊豁免不应依赖 API 通道是否可用"
  end

  # --- fail-closed ---------------------------------------------------------

  def test_api_failure_fails_closed
    admin, = admin_with(status: "administrator", raise_on: Class.new(StandardError).new("net down"))

    refute admin.admin?(CHAT_ID, USER_ID, chat_type: "supergroup"),
           "查询失败必须 fail-closed（权限判定的错误方向只能选安全侧）"
  end

  def test_both_channels_failing_fails_closed
    admin, = admin_with(status: "administrator",
                        raise_on: Class.new(StandardError).new("gem down"),
                        raw_raises: true)

    refute admin.admin?(CHAT_ID, USER_ID, chat_type: "supergroup"),
           "两条通道都失败时仍须 fail-closed"
  end

  def test_malformed_response_fails_closed
    # 响应体没有 status 字段（或形态完全不对）→ 不许当成管理员
    admin, = admin_with(raise_on: Class.new(StandardError).new("x"),
                        raw_result: { "ok" => true, "result" => { "user" => { "id" => 1 } } })

    refute admin.admin?(CHAT_ID, USER_ID, chat_type: "supergroup"),
           "缺 status 的响应体必须 fail-closed"
  end

  def test_nil_api_fails_closed_without_network
    admin = TelegramBot::Admin.new(api: nil, clock: @clock, logger: Logger.new(IO::NULL))

    refute admin.admin?(CHAT_ID, USER_ID, chat_type: "supergroup"),
           "未注入 api 时应直接 false（绝不去打网络）"
  end

  # --- raw 兜底（§12 R2 保底通道）-------------------------------------------

  def test_raw_fallback_is_used_when_gem_raises
    admin, fake = admin_with(
      status: "administrator",
      raise_on: Class.new(StandardError).new("gem channel down"),
      raw_result: { "ok" => true, "result" => { "status" => "creator" } }
    )

    assert admin.admin?(CHAT_ID, USER_ID, chat_type: "supergroup"),
           "gem 通道失败时 raw_api_call 保底应给出结果"
    assert_equal 1, fake.raw_calls.size, "raw 兜底必须真的被调用过一次"
    assert_equal "getChatMember", fake.raw_calls.first[:method]
    assert_equal({ chat_id: CHAT_ID, user_id: USER_ID }, fake.raw_calls.first[:params],
                 "raw 通道参数应与 gem 通道同形")
  end

  def test_raw_fallback_hash_shape_is_accepted
    # gem 端点缺失的形态（老 gem 抛 NoMethodError）→ raw 兜底
    admin, = admin_with(
      raise_on: NoMethodError.new("undefined method `get_chat_member'"),
      raw_result: { "ok" => true, "result" => { "status" => "administrator" } }
    )

    assert admin.admin?(CHAT_ID, USER_ID, chat_type: "supergroup"),
           "raw 通道返回的 Hash 形态应被归一成 status 字符串"
  end

  def test_gem_success_does_not_call_raw
    admin, fake = admin_with(status: "creator")

    assert admin.admin?(CHAT_ID, USER_ID, chat_type: "supergroup")
    assert_empty fake.raw_calls, "gem 通道打通时不该再打 raw（多一次往返）"
  end

  # --- 缓存 ---------------------------------------------------------------

  def test_cache_hit_avoids_repeated_api_calls
    admin, fake = admin_with(status: "administrator")

    3.times { assert admin.admin?(CHAT_ID, USER_ID, chat_type: "supergroup") }

    assert_equal 1, fake.gem.calls.size, "TTL 内重复判定只应打一次 getChatMember"
    assert_equal 1, admin.cached_admin_count
  end

  def test_cache_expires_after_ttl
    admin, fake = admin_with(status: "administrator", ttl: 300.0)

    admin.admin?(CHAT_ID, USER_ID, chat_type: "supergroup")
    @clock.advance(299.0)
    admin.admin?(CHAT_ID, USER_ID, chat_type: "supergroup")
    assert_equal 1, fake.gem.calls.size, "TTL 内不该重查"

    @clock.advance(2.0) # 越过 300
    admin.admin?(CHAT_ID, USER_ID, chat_type: "supergroup")
    assert_equal 2, fake.gem.calls.size, "TTL 过期后应重新查询（撤职才能生效）"
  end

  def test_broken_clock_degrades_to_no_cache_not_never_expiring
    # 时钟故障回退的语义必须是「恒过期」（2026-10-12 三审订正：旧实现返回 0.0，
    # 而缓存写入的是 now+ttl=300 → 300 > 0 恒真 = 恒命中**永不失效**，方向反了
    # ——时钟故障期间被撤职的管理员会被无限期缓存成仍有权限）。
    gem = FakeGemApi.new(status: "administrator")
    fake = FakeApi.new(gem)
    admin = TelegramBot::Admin.new(api: fake, clock: -> { raise "clock boom" },
                                   ttl: 300.0, logger: Logger.new(IO::NULL))

    3.times { assert admin.admin?(CHAT_ID, USER_ID, chat_type: "supergroup") }

    assert_equal 3, gem.calls.size,
                 "时钟故障必须退化为「不用缓存」——每次都真查（恒过期）"
    # 缓存条目可能存在（写入值 = ∞），但永不命中（∞ > ∞ 为 false）
  end

  def test_false_is_not_cached
    # 缓存一个 false 会让**刚上任**的管理员在 TTL 内改不了设置；
    # 缓存一个 true 在 TTL 内仍可改设置（不限次数）——代价不对称，故只缓存 true。
    admin, fake = admin_with(status: "member")

    3.times { refute admin.admin?(CHAT_ID, USER_ID, chat_type: "supergroup") }

    assert_equal 3, fake.gem.calls.size, "false 不该被缓存（管理身份可升可降）"
    assert_equal 0, admin.cached_admin_count
  end

  def test_cache_is_per_chat_and_user
    admin, fake = admin_with(status: "administrator")

    admin.admin?(CHAT_ID, USER_ID, chat_type: "supergroup")
    admin.admin?(CHAT_ID, 43, chat_type: "supergroup")       # 同群不同人
    admin.admin?(CHAT_ID + 1, USER_ID, chat_type: "supergroup") # 群人不同

    assert_equal 3, fake.gem.calls.size, "缓存键必须是 (chat_id, user_id) 组合"
  end

  def test_clear_cache_forces_recheck
    admin, fake = admin_with(status: "administrator")

    admin.admin?(CHAT_ID, USER_ID, chat_type: "supergroup")
    admin.clear_cache!
    admin.admin?(CHAT_ID, USER_ID, chat_type: "supergroup")

    assert_equal 2, fake.gem.calls.size, "clear_cache! 后应重新查询"
  end

  # --- 匿名管理员（§0.2.4）------------------------------------------------

  def test_anonymous_admin_user_id_is_rejected_without_api_call
    # 匿名管理员的消息 sender 是 GroupAnonymousBot；用它去查必然不是管理员。
    # 本类在**打 API 之前**就识破并拒（fail-closed，且不打无用请求）。
    admin, fake = admin_with(status: "administrator")

    refute admin.admin?(CHAT_ID, ANON, chat_type: "supergroup"),
           "匿名 bot 不是管理员（且不应去查它）"
    assert_empty fake.gem.calls, "识别出匿名 bot 后不该再打 API"
  end

  def test_anonymous_admin_predicate
    admin = TelegramBot::Admin.new(api: nil, clock: @clock, logger: Logger.new(IO::NULL))

    assert admin.anonymous_admin?(ANON), "应能识别匿名 bot id"
    assert admin.anonymous_admin?(ANON.to_s), "字符串形态也应识别"
    refute admin.anonymous_admin?(USER_ID)
    refute admin.anonymous_admin?(nil)
  end

  # --- 边界与归一 ---------------------------------------------------------

  def test_zero_and_nil_identifiers_are_rejected
    admin, fake = admin_with(status: "administrator")

    refute admin.admin?(0, USER_ID, chat_type: "supergroup"), "chat_id=0 是黑洞守卫"
    refute admin.admin?(nil, USER_ID, chat_type: "supergroup")
    refute admin.admin?(CHAT_ID, 0, chat_type: "supergroup"), "user_id=0 = 未知发起人"
    refute admin.admin?(CHAT_ID, nil, chat_type: "supergroup")
    assert_empty fake.gem.calls, "以上都不该打 API"
  end

  def test_chat_type_nil_is_treated_as_group_not_private
    # 「没传 type」不等于「私聊豁免」——未知必须按更严的一侧处理。
    admin, fake = admin_with(status: "member")

    refute admin.admin?(CHAT_ID, USER_ID, chat_type: nil),
           "chat_type 未知时应按群处理（打 API 查询，而不是豁免）"
    assert_equal 1, fake.gem.calls.size, "chat_type=nil 应真的走查询路径"
  end

  def test_64bit_chat_id_is_passed_through_without_precision_loss
    admin, fake = admin_with(status: "creator")

    admin.admin?(CHAT_ID, USER_ID, chat_type: "supergroup")

    assert_equal CHAT_ID, fake.gem.calls.first[:chat_id],
                 "64 位 chat_id 必须原样传给 API（§0.2.4）"
  end

  def test_string_chat_id_is_normalized_to_integer
    admin, fake = admin_with(status: "creator")

    admin.admin?(CHAT_ID.to_s, USER_ID.to_s, chat_type: "supergroup")

    assert_equal CHAT_ID, fake.gem.calls.first[:chat_id],
                 "字符串入参应归一成整型（入站形态差异不该传到 API）"
    assert_equal USER_ID, fake.gem.calls.first[:user_id]
  end

  # --- 日志纪律 ------------------------------------------------------------

  def test_logs_never_contain_exception_messages
    # 异常消息可能夹带 token / 响应体（kimi T2.4 评审立的 RawApiError 契约）
    lines = []
    logger = Object.new
    logger.define_singleton_method(:warn) { |m| lines << m }

    secret_msg = "net down: token=1234567890:AAsecrettokenvalue"
    gem = FakeGemApi.new(raise_on: Class.new(StandardError).new(secret_msg))
    admin = TelegramBot::Admin.new(api: FakeApi.new(gem, raw_raises: true),
                                   clock: @clock, logger: logger)

    refute admin.admin?(CHAT_ID, USER_ID, chat_type: "supergroup")

    refute_empty lines, "失败应留痕（否则问题静默）"
    lines.each do |line|
      refute_includes line, "AAsecrettokenvalue", "日志绝不可回显异常消息（可能夹带 token）"
      assert_includes line, "[admin]", "日志应带结构性前缀"
    end
  end

  def test_broken_logger_does_not_break_verdict
    broken = Object.new
    broken.define_singleton_method(:warn) { |_m| raise "logger dead" }

    admin, = admin_with(status: "administrator")
    admin.instance_variable_set(:@logger, broken)

    assert admin.admin?(CHAT_ID, USER_ID, chat_type: "supergroup"),
           "logger 自身坏了也不能让权限判定失败"
  end
end