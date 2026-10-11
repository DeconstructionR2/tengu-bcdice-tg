# frozen_string_literal: true

# ============================================================================
# bot/handlers/settings.rb — /settings（T2.6，计划 §6 主轨 / §8 T2.6）
#
# 三个子命令（无参 / aux on|off / 其余 → 用法）：
#
#   /settings              → 本群设置总览：生效规则系统 + **来源**（话题/群/全局）
#                             + 辅助轨开关状态 + 一句怎么改
#   /settings aux on       → 开辅助轨（裸 ASCII 骰式）
#   /settings aux off      → 关辅助轨
#
# ── 权限：群/超级群里**仅管理员**能改，私聊自由改 ────────────────────────────
#
#   判定走 bot/admin.rb（getChatMember 的唯一实现，T3.4 会复用同一个实例）。
#   非管理员改开关 → **回一句拒答**，不回静默：slash 主轨是显式意图（用户
#   @ 了 bot 或打了 /settings），静默会让用户以为 bot 挂了/命令拼错了。
#   这与辅助轨的「静默防抢话」（bot/router.rb）**刻意相反**——那里是 bot
#   自己猜这行是不是骰式，回话就是抢话；这里用户点名问了，不回才是坏体验。
#
#   为什么私聊豁免：私聊是用户自己的对话（bot/admin.rb 纪律 2），改自己
#   的设置不需要任何审核。
#
# ── aux 开关是「每群一份」，话题内也写群级行 ─────────────────────────────────
#
#   计划 §6 的口径是「每群 /settings 可关辅助轨」。故话题内执行
#   `/settings aux off` **改的是全群的开关**，回复文案必须说清楚这一点
#   （否则用户在话题里关了、发现 General 话题还在抢话，会以为 bot 有 bug）。
#   存储层细节见 db/settings.rb「aux_enabled 只走群级行」一节。
#
# ── 显示「来源」而不是只显示值 ──────────────────────────────────────────────
#
#   /system 无参已经会回「当前规则系统 + 来源」（T2.4）。/settings 是**总览**，
#   必然重复这一项——但 /settings 是 Telegram 官方的三件套之一
#   （§6：start/help/settings），用户对它的预期是「这个群的设置面板」。
#   两处都显示不是重复劳动而是同一事实的两个入口，故直接复用
#   DiceHandler#describe_current 的文案结构（同源，避免两套措辞漂移）。
#
# ── 依赖注入（全可注 → 单测零 DB 文件、零联网、零引擎 bootstrap 之外的状态）─
#
#   settings : TenguDB::Settings（默认单连接）
#   admin    : #admin?(chat_id, user_id, chat_type:) → Boolean
#             （默认注入 TelegramBot::Admin 的**真身由 main.rb 负责**；
#              这里不自动 new——真身需要 api（TelegramApi），handler 自己 new
#              会绕过 main.rb 的单连接/单实例纪律）。**群内未注入 = 拒绝**。
#   resolver : #call(id) → BCDice 规则类（取 NAME 显示名，默认走 EngineResolver）
#
# 只读红线：本文件不修改 vendor/bundle/** 与 references/src/**。
# ============================================================================

require_relative "../telegram_api" # MainMenu 等
require_relative "../admin"
require_relative "dice"            # EngineResolver（规则系统的显示名来源）
require_relative "../../db/settings"

module TelegramBot
  module Handlers
    # ------------------------------------------------------------------
    # SettingsHandler
    # ------------------------------------------------------------------
    class SettingsHandler
      # 用法（未识别的子命令 / `/settings aux` 少打 on|off 都用它）
      USAGE = <<~TEXT.strip
        用法：
        /settings            查看本群设置（规则系统与来源、辅助轨开关）
        /settings aux on     开启辅助轨（裸打 N4,3、SB 也能掷骰）
        /settings aux off    关闭辅助轨（只保留 /roll /nd 等 slash 命令）
      TEXT

      # 子命令名
      AUX = "aux"

      # 开/关的取值词表。**只认这两个**（纯 ASCII，§13 第 2 项）。
      # 其它输入（enable/disable/是/开）一律走用法提示——用户打错时回一句
      # 明确的用法，比猜他想要的方向安全（猜错 = 静默关掉/打开群设置）。
      ON_WORDS = %w[on].freeze
      OFF_WORDS = %w[off].freeze

      # 拒答（非管理员改开关）
      NOT_ADMIN = "只有本群管理员能改这个设置。需要的话请让管理员执行 /settings aux on|off。"

      # 私聊里的确认文案前缀（区分群/私聊，私聊的「群」字样会让人困惑）
      PRIVATE_PREFIX = "（私聊）"

      # 注入项
      attr_reader :settings, :admin, :resolver

      # @param settings [TenguDB::Settings, nil] nil = 用单连接新建
      # @param admin [#admin?, nil] **群内未注入即拒绝**（fail-closed：漏注入不该
      #   变成「所有人都能改群设置」；私聊不受影响）。main.rb 注入真身。
      # @param resolver [#call, nil] id → 规则类（取显示名）
      # @param logger [#warn, nil] 日志器（只记结构性信息；测试注入 IO::NULL）
      def initialize(settings: nil, admin: nil, resolver: nil, logger: $stderr)
        @settings = settings
        @admin = admin
        @resolver = resolver || EngineResolver.method(:call)
        @logger = logger
      end

      # settings 懒加载：注入优先，否则取 DB 层单连接。
      # （与 DiceHandler 同一套做法——handler 单测可以完全不碰 SQLite。）
      def settings
        @settings ||= TenguDB::Settings.new
      end

      # 注册表（bot/main.rb 调一次即可）
      def self.registry(handler = new)
        { settings: handler }
      end

      # router 的 handler 注册表接口
      def call(context)
        handle(context)
      end

      # ------------------------------------------------------------------
      # 分发
      # ------------------------------------------------------------------

      def handle(context)
        args = context[:args].to_s.strip
        return overview(context) if args.empty?

        # 只取前两段：/settings aux on extra（粘贴手滑）不致命。
        # 逐段 downcase：`/settings AUX ON` 也认（Telegram 用户爱随手大写）。
        parts = args.split(/\s+/).first(2).map(&:downcase)

        if parts.first == AUX && ON_WORDS.include?(parts[1])
          set_aux(context, true)
        elsif parts.first == AUX && OFF_WORDS.include?(parts[1])
          set_aux(context, false)
        else
          # 未识别子命令 → 用法（**不静默**：显式命令给反馈，见文件头）
          USAGE
        end
      end

      # ------------------------------------------------------------------
      # 无参：总览
      # ------------------------------------------------------------------

      # 本群设置总览：生效规则系统 + 来源 + 辅助轨开关。
      def overview(context)
        chat_id = context[:chat_id].to_i
        resolved = settings.resolve(chat_id, thread_id: context[:thread_id])
        klass = @resolver.call(resolved.game_system)
        name = klass ? display_name(klass, resolved.game_system) : resolved.game_system
        aux_on = settings.aux_enabled(chat_id, thread_id: context[:thread_id])
        in_private = private?(context)

        # 私聊里「本群/该群」这组词自相矛盾（私聊没有群），故整组换成
        # 「你的私聊」。文案分支集中在这里，别散在拼装处。
        origin =
          if in_private
            case resolved.scope
            when TenguDB::Scope::THREAD then "来源：本话题设置"
            when TenguDB::Scope::GROUP then "来源：私聊默认设置"
            else "来源：全局默认（尚未设置过）"
            end
          else
            case resolved.scope
            when TenguDB::Scope::THREAD then "来源：本话题设置"
            when TenguDB::Scope::GROUP then "来源：本群设置"
            else "来源：全局默认（该群尚未设置）"
            end
          end

        aux_line =
          if aux_on
            "辅助轨：开（裸打 N4,3、SB 也能掷骰）"
          else
            "辅助轨：关（只响应 /roll /nd 等 slash 命令）"
          end

        hint =
          if in_private
            "私聊里可以直接改：/settings aux on|off。"
          else
            "用 /settings aux on|off 开关辅助轨（仅管理员可改，全群生效）。"
          end

        # 私聊标注：群里的用户不需要这个前缀（上下文本来就是群）
        prefix = in_private ? PRIVATE_PREFIX : ""

        [
          "#{prefix}当前规则系统：#{resolved.game_system}（#{name}）",
          origin,
          aux_line,
          hint
        ].join("\n")
      end

      # ------------------------------------------------------------------
      # aux on|off
      # ------------------------------------------------------------------

      def set_aux(context, on)
        chat_id = context[:chat_id].to_i

        return NOT_ADMIN unless authorized?(context)

        settings.set_aux_enabled(chat_id, enabled: on, thread_id: context[:thread_id])

        state = on ? "已开启" : "已关闭"
        scope = private?(context) ? PRIVATE_PREFIX : "（全群生效）"
        detail =
          if on
            "#{state}辅助轨——裸打 N4,3、SB 也能掷骰#{scope}"
          else
            "#{state}辅助轨——裸打骰式不再响应，仍可用 /roll、/nd#{scope}"
          end

        detail
      end

      # ------------------------------------------------------------------
      # 权限
      # ------------------------------------------------------------------

      # 该不该允许这个人改？私聊自由、群内要管理员。
      #
      # ⚠️ **未注入 admin 时群内一律拒绝**（不是放行）：权限判定的错误方向
      #   只能选安全的那侧——忘了注入 admin 就等于「任何人都能改这个群的设置」，
      #   那是最坏的一种故障（且完全静默）。私聊不受影响（用户自己的对话）。
      #   单测请注入假 admin（见 test/bot/test_settings_handler_test.rb 的
      #   FakeAdmin），不要靠「不注入 = 免检」来测。
      def authorized?(context)
        return true if private?(context)
        return false if @admin.nil? # 缺依赖 = 拒绝（fail-closed）

        @admin.admin?(context[:chat_id], context[:user_id],
                       chat_type: context[:chat_type])
      rescue StandardError => e
        # admin? 本身已 fail-closed；这里是「它不该抛」的兜底，抛了也当
        # 不通过（双重保险，不能让判定层异常变成放行）。
        warn_line("[settings] 管理员判定异常，按拒绝处理：#{e.class}")
        false
      end

      def private?(context)
        context[:chat_type].to_s == "private"
      end

      def display_name(klass, id)
        EngineResolver.display_name(klass, id)
      end

      # 只记结构性信息，绝不记用户正文
      def warn_line(message)
        @logger.warn(message)
      rescue StandardError
        nil
      end
    end
  end
end