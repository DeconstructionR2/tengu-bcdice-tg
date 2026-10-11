# frozen_string_literal: true

# ============================================================================
# test/bot/test_settings_handler_test.rb — /settings handler（T2.6）
#
# 覆盖计划 §6（/settings 主轨 + 「每群 /settings 可关辅助轨」）/ §8 T2.6：
#   - 无参总览：显示生效规则系统 + **来源**（话题/群/全局三种）+ 辅助轨状态
#   - /settings aux on|off 往返（写库 → 总览能看到 → 再改回来）
#   - 权限：群内**仅管理员**可改（非管理员一句拒答，且不写库）、
#           私聊豁免（自由改）、admin? 抛异常也拒（双重 fail-closed）
#   - 未识别子命令 → 用法提示
#   - aux 关闭后裸打骰式静默（**经 router 端到端**）
#   - 话题内改 aux 写的是**群级**行（每群一份），回复文案说清「全群生效」
#
# 两层测试（与 T2.4 的 dice handler 同款结构）：
#   1. handler 直调（注入内存 DB + 真引擎）——验语义；
#   2. 经 Router 端到端（假 TelegramApi）——验接线、静默、aux 关闭的实效。
#
# 全程零联网、零真 token、零落盘（DB 用 :memory:）。
# ============================================================================

require_relative "test_helper"
require_relative "../../bot/router"
require_relative "../../bot/admin"
require_relative "../../bot/handlers/dice"
require_relative "../../bot/handlers/settings"
require_relative "../../db/settings"
require_relative "../../lib/engine_bootstrap"

EngineBootstrap.bootstrap!(reload_backend: true)

# 假管理员助手：按 user_id 白名单回答（零联网、可断言「问了几次」）
class FakeAdmin
  attr_reader :asked

  def initialize(admins: [], default: false, raise_on: false)
    @admins = Array(admins).map(&:to_i)
    @default = default
    @raise_on = raise_on
    @asked = []
  end

  def admin?(_chat_id, user_id, chat_type: nil)
    @asked << [user_id, chat_type]
    raise "getChatMember exploded" if @raise_on

    @default || @admins.include?(user_id.to_i)
  end
end

class TestSettingsHandler < Minitest::Test
  include BotTestHelper

  CHAT_ID = -1_000_000_000_123_456_789 # 超 32 位（§0.2.4）
  TOPIC = 88
  ADMIN_USER = 7
  NORMAL_USER = 42
  NS1EX = "NinjaSlayerEx"

  def setup
    @conn = TenguDB::Connection.open(path: ":memory:")
    @settings = TenguDB::Settings.new(@conn)
    @admin = FakeAdmin.new(admins: [ADMIN_USER])
    @handler = TelegramBot::Handlers::SettingsHandler.new(
      settings: @settings, admin: @admin, logger: Logger.new(IO::NULL)
    )
  end

  def teardown
    @conn.close
  end

  # 造一个 handler 上下文（形状与 router run_handler 完全一致）
  def ctx(args: "", chat_id: CHAT_ID, thread_id: nil, user_id: ADMIN_USER,
          chat_type: "supergroup")
    { router: nil, api: nil, kind: :slash, command: nil,
      name: "settings", args: args, text: "/settings #{args}".strip,
      chat_id: chat_id, thread_id: thread_id, user_id: user_id,
      chat_type: chat_type, message: nil }
  end

  # --- 无参总览 -----------------------------------------------------------

  def test_overview_shows_global_default_when_nothing_set
    out = @handler.call(ctx)

    assert_includes out, "NinjaSlayer2Ex", "总览应显示生效规则系统"
    assert_includes out, "全局默认", "未设置过的群应显示来源=全局默认"
    assert_includes out, "辅助轨：开", "默认辅助轨是开的"
  end

  def test_overview_shows_group_scope_source
    @settings.set_game_system(CHAT_ID, thread_id: 0, game_system: NS1EX)

    out = @handler.call(ctx)

    assert_includes out, NS1EX
    assert_includes out, "来源：本群设置"
  end

  def test_overview_shows_topic_scope_source
    @settings.set_game_system(CHAT_ID, thread_id: 0, game_system: NS1EX)
    @settings.set_game_system(CHAT_ID, thread_id: TOPIC, game_system: "NinjaSlayer2Ex")

    out = @handler.call(ctx(thread_id: TOPIC))

    assert_includes out, "来源：本话题设置"
    assert_includes out, "NinjaSlayer2Ex", "话题内应显示话题自己的规则系统"
  end

  def test_overview_shows_fallback_to_group_when_topic_not_set
    @settings.set_game_system(CHAT_ID, thread_id: 0, game_system: NS1EX)

    out = @handler.call(ctx(thread_id: TOPIC))

    assert_includes out, NS1EX, "未设置的话题回落到群设置"
    assert_includes out, "来源：本群设置"
  end

  def test_overview_reflects_aux_off
    @handler.call(ctx(args: "aux off"))

    out = @handler.call(ctx)

    assert_includes out, "辅助轨：关"
    refute_includes out, "辅助轨：开"
  end

  def test_overview_survives_unavailable_game_system
    # 库里存了个引擎里没有的 ID（换 gem 版本/手改 DB）：总览不能因此崩掉，
    # 应退回显示 ID 本身。
    @settings.set_game_system(CHAT_ID, thread_id: 0, game_system: "NoSuchSystemXYZ")

    out = @handler.call(ctx)

    assert_includes out, "NoSuchSystemXYZ"
    assert_includes out, "辅助轨"
  end

  def test_overview_in_private_chat_has_no_group_wording
    @handler.call(ctx(args: "aux off"))
    out = @handler.call(ctx(chat_type: "private", user_id: 999))

    assert_includes out, "（私聊）", "私聊应有标注"
    refute_includes out, "本群设置", "私聊文案不该出现「本群」（私聊没有群）"
  end

  # --- aux on|off ---------------------------------------------------------

  def test_aux_off_then_on_round_trip
    off = @handler.call(ctx(args: "aux off"))
    assert_includes off, "已关闭"
    assert_includes off, "全群生效", "群里的回复应说明这是全群级别的开关"
    refute @settings.aux_enabled(CHAT_ID), "写库后应读回 false"

    on = @handler.call(ctx(args: "aux on"))
    assert_includes on, "已开启"
    assert @settings.aux_enabled(CHAT_ID), "写库后应读回 true"
  end

  def test_aux_subcommand_is_case_insensitive
    assert_includes @handler.call(ctx(args: "aux OFF")), "已关闭"
    assert_includes @handler.call(ctx(args: "AUX On")), "已开启"
  end

  def test_aux_accepts_trailing_garbage
    out = @handler.call(ctx(args: "aux on 谢谢"))

    assert_includes out, "已开启", "参数只取前两段，后面粘贴手滑不该致命"
  end

  def test_aux_whitespace_variants
    assert_includes @handler.call(ctx(args: "  aux   off  ")), "已关闭"
  end

  def test_aux_in_topic_writes_group_level_row
    # 「每群一份」：话题内改也要写到群级行（db/settings.rb 的定案）
    @handler.call(ctx(args: "aux off", thread_id: TOPIC))

    refute @settings.aux_enabled(CHAT_ID), "群级应已关闭"
    rows = @settings.entries_for_chat(CHAT_ID)
    assert_equal 1, rows.size, "只该有一行（群级），不该为话题另写一行"
    assert_equal 0, rows.first["thread_id"].to_i
  end

  def test_aux_does_not_disturb_game_system
    @settings.set_game_system(CHAT_ID, thread_id: 0, game_system: NS1EX)

    @handler.call(ctx(args: "aux off"))

    assert_equal NS1EX, @settings.game_system(CHAT_ID),
                 "改 aux 开关不得把规则系统带回默认值"
  end

  def test_aux_reply_confirms_effective_state
    out = @handler.call(ctx(args: "aux off"))
    refute @settings.aux_enabled(CHAT_ID), "回复说关了，库里就得是关的"

    out2 = @handler.call(ctx)
    assert_includes out2, "辅助轨：关", "确认文案与库内状态必须一致"
  end

  # --- 权限 ---------------------------------------------------------------

  def test_non_admin_cannot_change_aux_in_group
    out = @handler.call(ctx(args: "aux off", user_id: NORMAL_USER))

    assert_includes out, "管理员", "非管理员应被明确拒答（不回静默：用户点名问了）"
    assert @settings.aux_enabled(CHAT_ID), "拒答时绝不能写库"
  end

  def test_non_admin_rejection_happens_before_any_write
    @handler.call(ctx(args: "aux off", user_id: NORMAL_USER))

    assert_empty @settings.entries_for_chat(CHAT_ID), "拒答不该产生任何行"
  end

  def test_admin_can_change_aux
    out = @handler.call(ctx(args: "aux off", user_id: ADMIN_USER))

    assert_includes out, "已关闭"
    refute @settings.aux_enabled(CHAT_ID)
  end

  def test_private_chat_bypasses_admin_check
    admin_spy = FakeAdmin.new(admins: [], default: false)
    handler = TelegramBot::Handlers::SettingsHandler.new(
      settings: @settings, admin: admin_spy, logger: Logger.new(IO::NULL)
    )

    out = handler.call(ctx(args: "aux off", chat_type: "private", user_id: NORMAL_USER))

    assert_includes out, "已关闭", "私聊自由改（私聊是用户自己的对话）"
    refute @settings.aux_enabled(CHAT_ID)
    assert_empty admin_spy.asked, "私聊不该去打 getChatMember（零网络）"
  end

  def test_admin_predicate_receives_chat_type
    @handler.call(ctx(args: "aux off", chat_type: "group", user_id: NORMAL_USER))

    assert_equal [[NORMAL_USER, "group"]], @admin.asked,
                 "handler 必须把 chat_type 传给 admin?（判私聊豁免用）"
  end

  def test_admin_predicate_failure_is_treated_as_denied
    # 双重 fail-closed：admin? 本身已 fail-closed，它若仍抛异常也必须当拒绝
    exploding = FakeAdmin.new(raise_on: true)
    handler = TelegramBot::Handlers::SettingsHandler.new(
      settings: @settings, admin: exploding, logger: Logger.new(IO::NULL)
    )

    out = handler.call(ctx(args: "aux off", user_id: ADMIN_USER))

    assert_includes out, "管理员", "判定异常应当拒绝，不得变成放行"
    assert @settings.aux_enabled(CHAT_ID), "异常时绝不写库"
  end

  def test_overview_is_visible_to_everyone
    # 只读操作不做权限门：普通成员也该能看到本群设置（否则群里没人知道怎么改）
    out = @handler.call(ctx(user_id: NORMAL_USER))

    assert_includes out, "辅助轨"
    assert_empty @admin.asked, "只读总览不该触发 getChatMember"
  end

  def test_missing_admin_injection_denies_in_group
    # 漏注入 admin 不能变成「所有人都能改群设置」——那是权限判定的错误方向
    handler = TelegramBot::Handlers::SettingsHandler.new(
      settings: @settings, admin: nil, logger: Logger.new(IO::NULL)
    )

    out = handler.call(ctx(args: "aux off", chat_type: "supergroup"))

    assert_includes out, "管理员", "未注入 admin 时群内应拒绝"
    assert @settings.aux_enabled(CHAT_ID), "拒绝时不该写库"
  end

  def test_missing_admin_injection_still_allows_private
    # 私聊不受影响（用户自己的对话），别把 fail-closed 扩大到私聊
    handler = TelegramBot::Handlers::SettingsHandler.new(
      settings: @settings, admin: nil, logger: Logger.new(IO::NULL)
    )

    out = handler.call(ctx(args: "aux off", chat_type: "private"))

    assert_includes out, "已关闭", "私聊自由改，不受 admin 注入影响"
    refute @settings.aux_enabled(CHAT_ID)
  end

  # --- 用法提示 -----------------------------------------------------------

  def test_unknown_subcommand_shows_usage
    out = @handler.call(ctx(args: "foo bar"))

    assert_includes out, "/settings"
    assert_includes out, "aux on"
    assert_includes out, "aux off"
  end

  def test_aux_without_on_off_shows_usage
    out = @handler.call(ctx(args: "aux"))

    assert_includes out, "用法", "漏打 on|off 应给用法而不是猜"
    assert @settings.aux_enabled(CHAT_ID), "用法提示不该改任何设置"
  end

  def test_enable_disable_words_are_not_guessed
    # 只认 on/off：打错时回用法（不猜方向——猜错=静默关掉群设置）
    out = @handler.call(ctx(args: "aux enable"))

    assert_includes out, "用法"
    assert @settings.aux_enabled(CHAT_ID), "未识别的词不该改设置"
  end

  def test_japanese_words_are_not_guessed
    out = @handler.call(ctx(args: "aux 开启"))

    assert_includes out, "用法", "纯 ASCII 定案（§13 第 2 项）：只认 on/off"
    assert @settings.aux_enabled(CHAT_ID)
  end
end

# ============================================================================
# 经 Router 的端到端接线（假 TelegramApi，零联网）
# ============================================================================
class TestSettingsHandlerRouting < Minitest::Test
  include BotTestHelper

  CHAT_ID = -1_000_000_000_123_456_789
  TOPIC = 88
  ADMIN_USER = 7
  NORMAL_USER = 42

  def setup
    @api, @fake, = build_api
    @conn = TenguDB::Connection.open(path: ":memory:")
    @settings = TenguDB::Settings.new(@conn)
    @admin = FakeAdmin.new(admins: [ADMIN_USER])
    @settings_handler = TelegramBot::Handlers::SettingsHandler.new(
      settings: @settings, admin: @admin, logger: Logger.new(IO::NULL)
    )
    @dice = TelegramBot::Handlers::DiceHandler.new(
      settings: @settings, logger: Logger.new(IO::NULL)
    )
    build_router
  end

  def teardown
    @conn.close
  end

  def build_router(aux_enabled: nil)
    @router = TelegramBot::Router.new(
      api: @api,
      handlers: TelegramBot::Handlers::DiceHandler.registry(@dice)
                      .merge(TelegramBot::Handlers::SettingsHandler.registry(@settings_handler)),
      bot_username: "example_dice_bot",
      aux_enabled: aux_enabled || method(:aux_enabled_for_chat),
      logger: Logger.new(IO::NULL)
    )
  end

  # 与 main.rb 接线同形：读群级 chat_settings.aux_enabled
  def aux_enabled_for_chat(chat_id, thread_id)
    @settings.aux_enabled(chat_id, thread_id: thread_id)
  end

  def update(text:, chat_id: CHAT_ID, thread_id: nil, user_id: NORMAL_USER,
             chat_type: "supergroup")
    attrs = { message_id: 1, date: 1_700_000_000,
              chat: { id: chat_id, type: chat_type },
              from: { id: user_id, is_bot: false, first_name: "Tester" },
              text: text }
    attrs[:message_thread_id] = thread_id if thread_id
    Telegram::Bot::Types::Update.new(update_id: 1,
                                     message: Telegram::Bot::Types::Message.new(**attrs))
  end

  def sent_texts
    @fake.sent_messages.map { |m| m[:text] }
  end

  # --- 接线 ---------------------------------------------------------------

  def test_settings_command_is_registered_and_answered
    @router.dispatch(update(text: "/settings"))

    assert_equal 1, sent_texts.size, "/settings 已在菜单里，必须有 handler 应答"
    assert_includes sent_texts.first, "当前规则系统"
  end

  def test_settings_reply_keeps_thread_id
    @router.dispatch(update(text: "/settings", thread_id: TOPIC))

    assert_equal TOPIC, @fake.sent_messages.first[:message_thread_id],
                 "forum 话题内的回复必须带 thread_id（§3 决6）"
  end

  def test_router_passes_chat_type_into_handler_context
    seen = []
    router = TelegramBot::Router.new(api: @api, bot_username: "example_dice_bot",
                                     logger: Logger.new(IO::NULL))
    router.register(:settings) { |c| seen << c[:chat_type] }
    router.dispatch(update(text: "/settings", chat_type: "private"))

    assert_equal ["private"], seen, "handler 上下文必须带 chat_type（T2.6 权限判定依赖）"
  end

  def test_admin_can_disable_aux_end_to_end
    @router.dispatch(update(text: "/settings aux off", user_id: ADMIN_USER))

    assert_includes sent_texts.first, "已关闭"
    refute @settings.aux_enabled(CHAT_ID), "持久化链路要通（main.rb 的接线形态）"
  end

  def test_non_admin_rejected_end_to_end
    @router.dispatch(update(text: "/settings aux off", user_id: NORMAL_USER))

    assert_includes sent_texts.first, "管理员"
    assert @settings.aux_enabled(CHAT_ID), "非管理员不该改到库"
  end

  # --- 核心闭环：aux 关掉后裸打骰式静默 ----------------------------------

  def test_aux_roll_is_silent_after_disabling_via_settings
    # 关之前：裸打 SB 出骰
    @router.dispatch(update(text: "SB"))
    assert_equal 1, sent_texts.size, "默认辅助轨是开的"
    assert_includes sent_texts.first, "サツバツ"

    # 管理员关掉
    @router.dispatch(update(text: "/settings aux off", user_id: ADMIN_USER))
    assert_equal 2, sent_texts.size
    assert_includes sent_texts.last, "已关闭"

    # 关之后：裸打静默（router 的 aux_enabled 已读到库里的 0）
    @router.dispatch(update(text: "SB"))
    assert_equal 2, sent_texts.size, "aux 关掉后裸打骰式必须一条都不发（防抢话，§12 R4）"
  end

  def test_slash_commands_still_work_after_disabling_aux
    @router.dispatch(update(text: "/settings aux off", user_id: ADMIN_USER))
    @router.dispatch(update(text: "/roll SB"))

    assert_equal 2, sent_texts.size
    assert_includes sent_texts.last, "サツバツ", "关辅助轨不影响 slash 主轨"
  end

  def test_aux_roll_returns_after_reenabling
    @router.dispatch(update(text: "/settings aux off", user_id: ADMIN_USER))
    @router.dispatch(update(text: "/settings aux on", user_id: ADMIN_USER))
    @router.dispatch(update(text: "SB"))

    assert_equal 3, sent_texts.size
    assert_includes sent_texts.last, "サツバツ", "重新打开后辅助轨应恢复"
  end

  def test_aux_switch_is_per_chat_not_global
    other_chat = CHAT_ID + 1
    @router.dispatch(update(text: "/settings aux off", user_id: ADMIN_USER, chat_id: CHAT_ID))
    @router.dispatch(update(text: "SB", chat_id: other_chat))

    assert_equal 2, sent_texts.size
    assert_includes sent_texts.last, "サツバツ",
                    "A 群关掉辅助轨不该影响 B 群（每群一份）"
    assert @settings.aux_enabled(other_chat)
  end

  def test_aux_switch_applies_to_all_topics_of_the_chat
    @router.dispatch(update(text: "/settings aux off", user_id: ADMIN_USER))
    @router.dispatch(update(text: "SB", thread_id: TOPIC))

    assert_equal 1, sent_texts.size,
                 "话题内裸打同样应静默（开关是每群一份，不是每话题）"
  end

  # --- 静默纪律不变 -------------------------------------------------------

  # 本注册表只有 settings/dice 键；名单列的都是**在这里没有 handler** 的命令。
  # /secret（T3.1）与 /bank（T3.2）自各自任务起已是真 handler（挂在 main.rb 的
  # 完整注册表上），不在此名单——写进来会让本用例语义随版本漂移。
  def test_other_unregistered_commands_stay_silent
    %w[/secret /bank /ct /log /help].each do |text|
      @router.dispatch(update(text: text))
    end

    assert_empty sent_texts, "本注册表没有的键一律静默（未注册 → 不抢话）"
  end
end