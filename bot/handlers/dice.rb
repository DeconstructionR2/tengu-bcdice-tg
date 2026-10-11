# frozen_string_literal: true

require "logger"

# ============================================================================
# bot/handlers/dice.rb — 通用掷骰 + /system 双作用域切换（T2.4）
#
# 覆盖四个注册键（计划 §6 / §8 T2.4）：
#   :roll   `/roll <式>`      当前群/话题的规则系统；无参 → 用法提示
#   :nd     `/nd <式>`        **无视群设置**，固定 NinjaSlayer2Ex（§6）
#   :system `/system [ID]`    话题/群双作用域切换；无参 → 显示当前生效系统+来源
#   :aux    裸 ASCII 骰式     等同 /roll，但**引擎 nil 时静默**（防抢话，§12 R4）
#
# ── 「slash 提示 vs 辅助轨静默」是本文件最重要的一处不对称 ────────────────
#
#   slash 是**显式意图**（用户点名 @ 了 bot 或打了 /roll），引擎不接受时回一句
#   「该规则系统不认识这个命令」是正当反馈，还能告诉用户怎么写；
#   辅助轨是**裸 ASCII 猜测**（bot 自己猜这行是不是骰式），此时回一句就等于
#   在群里公开抢话——尤其闸门是「语法闸」，`NRS` 这类语法合法但引擎 nil 的输入
#   本就会被放行（见 docs/t2.3-report.md D2）。故 nil 一律静默。
#
# ── 规则系统查找（§3 决6 / §13 第 5 项 + §15.3 E4）────────────────────────
#
#   话题设置 → 群默认 → 全局默认 NinjaSlayer2Ex（db/settings.rb 实现三级查找）。
#   E4：thread_id ∈ {0, 1} 都算群级（forum General 话题恒为 1，故「话题外打 =
#   群默认」在 forum 里必须映射到 General）。
#   `/system` 的写路径对称：话题内打 → 话题行；话题外/General → 群级行。
#
# ── 输出 ────────────────────────────────────────────────────────────────
#
#   引擎 result.text **直发纯文本**（§13 第 7 项拍板：不做 Markdown/富格式转换，
#   引擎与天狗数据天生纯文本）；超长由 TelegramApi 的 Chunker 切段兜底
#   （handler 只管给字符串，切段是发送层的职责）。
#
# ── 依赖注入 ────────────────────────────────────────────────────────────
#
#   settings  : TenguDB::Settings（默认单连接）
#   resolver  : #call(id) → BCDice 规则类（默认走 BCDice.game_system_class）
#   system_ids: #call → 全部可用 ID 数组（默认走 BCDice.all_game_systems）
#   全可注入 → handler 单测**零 DB 文件、零引擎 bootstrap 之外的全局状态**。
#
# 只读红线：本文件不修改 vendor/bundle/** 与 references/src/**。
# ============================================================================

require_relative "../telegram_api" # MainMenu 等；也保证发送层的存在
require_relative "../../db/settings"

module TelegramBot
  module Handlers
    # ----------------------------------------------------------------------
    # 引擎桥：把「规则系统 ID」翻译成 BCDice 规则类
    #
    # 单独成模块而非散在 handler 里，是为了 handler 单测能注入假引擎——
    # handler 逻辑（作用域/文案/静默）与真引擎行为（数百个规则系统）解耦。
    # ----------------------------------------------------------------------
    module EngineResolver
      module_function

      # @param id [String]
      # @return [Class, nil] 不存在或解析失败一律 nil（**不抛**——调用方要回
      #   用户友好提示，异常会冒到 router 的兜底里变成静默，用户只看到没反应）
      def call(id)
        klass = ::BCDice.game_system_class(id.to_s)
        klass.is_a?(Class) ? klass : nil
      rescue StandardError
        nil
      end

      # 全部可用 ID（升序），供 /system 报「可用示例」
      def system_ids
        ::BCDice.all_game_systems.map { |k| k::ID }.sort
      rescue StandardError
        []
      end

      # 规则系统的日文/中文显示名（引擎有 NAME 常量则用；无则退回 ID）
      def display_name(klass, id)
        name =
          begin
            klass.const_get(:NAME)
          rescue StandardError, NameError
            nil
          end
        name.nil? || name.to_s.empty? ? id.to_s : name.to_s
      end

      # ID 是否有效
      def valid_id?(id)
        !call(id).nil?
      end
    end

    # ----------------------------------------------------------------------
    # DiceHandler
    # ----------------------------------------------------------------------
    class DiceHandler
      # /nd 固定路由（§6：无视群设置，直通 2 版扩展）
      ND_GAME_SYSTEM = "NinjaSlayer2Ex"

      # 无参 /roll 的用法提示（短；不列举规则系统命令，那是 /help 的活）
      ROLL_USAGE = "用法：/roll <骰式或命令>，例：/roll SB、/roll N4,3、/roll 2d6>=4"

      # 无参 /nd 的用法提示
      ND_USAGE = "用法：/nd <忍杀2版命令>，例：/nd SB、/nd NSRS、/nd JITSB_C"

      # 引擎不接受该命令时的提示（slash 轨专用；辅助轨静默）
      UNKNOWN_COMMAND = "当前规则系统不接受这个命令。换 /system <系统ID> 可切换规则系统。"

      # 暗骰（S 前缀）提示（slash 轨专用；**绝不含结果**；辅助轨静默）
      #
      # T3.1 后 /secret 已真实现（T3.1 落 bot/handlers/secret_dice.rb），本提示
      # 改为**指路**而非「将于后续版本提供」——文案陈旧会让用户以为 /secret 不能用。
      # 回发规则一字未改：结果文本永远不在这条路径上。
      SECRET_NOT_SUPPORTED = "暗骰（S 前缀）的结果不会在这里显示——请用 /secret <骰式>（只有你自己看得到）。"

      # 无参 /system
      SYSTEM_USAGE = "用法：/system <规则系统ID> 切换；在话题内执行只改本话题。"

      # 系统 ID 建议条数（Telegram 消息虽可切段，但一屏之内可读性更重要；
      # 也别把 338 个系统全刷出来）
      EXAMPLE_COUNT = 6

      # 注入项
      attr_reader :settings, :resolver, :system_ids_provider

      # @param settings [TenguDB::Settings, nil] nil = 用单连接新建
      # @param resolver [#call] id → 规则类（nil → 走 EngineResolver）
      # @param system_ids [#call] → 可用 ID 数组（nil → 走 EngineResolver）
      # @param logger [#warn, nil] 日志器（只记结构性信息；测试注入 IO::NULL）
      def initialize(settings: nil, resolver: nil, system_ids: nil, logger: ::Logger.new($stderr))
        @settings = settings
        @resolver = resolver || EngineResolver.method(:call)
        @system_ids_provider = system_ids || EngineResolver.method(:system_ids)
        @logger = logger
      end

      # settings 懒加载：注入优先；否则取 DB 层单连接。
      #
      # 懒是为了**测试可零 DB 启动**：注入了假 settings 的用例根本不碰 SQLite。
      def settings
        @settings ||= TenguDB::Settings.new
      end

      # 注册表（bot/main.rb 调一次即可挂全四个键）
      #
      # @return [Hash{Symbol=>#call}]
      def self.registry(handler = new)
        {
          roll: handler,
          nd: handler,
          system: handler,
          aux: handler
        }
      end

      # router 的 handler 注册表接口：按 kind/命令名分发
      def call(context)
        case context[:name]
        when "roll" then handle_roll(context)
        when "nd" then handle_nd(context)
        when "system" then handle_system(context)
        else handle_aux(context)
        end
      end

      # ------------------------------------------------------------------
      # /roll <式> —— 当前群/话题规则系统
      # ------------------------------------------------------------------
      def handle_roll(context)
        args = context[:args].to_s.strip
        return ROLL_USAGE if args.empty?

        eval_in(context, args, silent: false)
      end

      # ------------------------------------------------------------------
      # /nd <式> —— 固定 NinjaSlayer2Ex，**无视群设置**（§6）
      # ------------------------------------------------------------------
      def handle_nd(context)
        args = context[:args].to_s.strip
        return ND_USAGE if args.empty?

        eval_with_system(context, ND_GAME_SYSTEM, args, silent: false)
      end

      # ------------------------------------------------------------------
      # 辅助轨：裸 ASCII 骰式 = 当前规则系统，**nil 静默**
      # ------------------------------------------------------------------
      def handle_aux(context)
        text = context[:text].to_s.strip
        return nil if text.empty?

        eval_in(context, text, silent: true)
      end

      # ------------------------------------------------------------------
      # /system [ID] —— 话题/群双作用域切换（§3 决6）
      # ------------------------------------------------------------------
      def handle_system(context)
        arg = context[:args].to_s.strip

        # 无参 → 显示当前生效系统 + 来源（话题/群/默认）
        return describe_current(context) if arg.empty?

        # 只取第一段：/system NinjaSlayer2Ex 后面跟别的（粘贴手滑）不致命，
        # 取首个词当 ID（ID 不含空格，见 all_game_systems 的 ID 形态）
        id = arg.split(/\s+/).first.to_s

        klass = @resolver.call(id)
        return unknown_system(context, id) if klass.nil?

        chat_id = context[:chat_id].to_i
        thread_id = context[:thread_id]
        stored_thread = settings.set_game_system(chat_id, thread_id: thread_id, game_system: id)

        reply =
          if TenguDB::Settings.topic_scope?(stored_thread)
            "已切换本话题规则系统 → #{id}（#{display_name(klass, id)}）"
          else
            "已切换本群规则系统 → #{id}（#{display_name(klass, id)}）"
          end
        reply
      end

      # ------------------------------------------------------------------
      # 引擎调用
      # ------------------------------------------------------------------

      # 按当前作用域解析规则系统并 eval
      def eval_in(context, text, silent:)
        resolved = settings.resolve(context[:chat_id], thread_id: context[:thread_id])
        eval_with_system(context, resolved.game_system, text,
                         silent: silent, resolved: resolved)
      end

      # 指定规则系统 eval；引擎 nil 时按 silent 决定「静默」还是「回一句」
      def eval_with_system(context, system_id, text, silent:, resolved: nil)
        klass = @resolver.call(system_id)

        if klass.nil?
          # 设置里存了个引擎里不存在的 ID（换 gem 版本/手改 DB 的可能）。
          # slash 轨给可诊断的话；辅助轨静默。
          return nil if silent

          return "规则系统 #{system_id} 当前不可用（可能已被移除）。请用 /system <其他ID> 切换。"
        end

        result =
          begin
            klass.eval(text)
          rescue StandardError => e
            warn_line("[dice] 引擎执行异常（system=#{system_id}）：#{e.class}")
            nil
          end

        # 引擎不接受 → nil
        if result.nil?
          return nil if silent

          return UNKNOWN_COMMAND
        end

        # **暗骰结果绝不公开回发**（kimi T2.4 评审必修，实测复现过）：
        # BCDice 把 S 前缀当暗骰标记（base.rb:254-267 置 secret?=true），
        # 而 router 闸门显式放行 S 前缀 → 不拦的话 `S2d6` 结果会广播进群。
        # 真正的暗骰走 /secret（ephemeral，T3.1）；在那之前：
        # slash 轨回一句**不含结果**的提示；辅助轨静默（nil）。
        if result.respond_to?(:secret?) && result.secret?
          return nil if silent

          return SECRET_NOT_SUPPORTED
        end

        text_out = result.respond_to?(:text) ? result.text.to_s : result.to_s
        return nil if text_out.empty? # 空文本与 nil 同义：辅助轨静默、slash 回提示

        # **直发纯文本**（§13 第 7 项），不贴标签、不加前缀——
        # 骰子 bot 的价值就是结果干净可复制。
        text_out
      end

      # ------------------------------------------------------------------
      # /system 回复文案
      # ------------------------------------------------------------------

      # 无参：当前生效系统 + 来源
      def describe_current(context)
        resolved = settings.resolve(context[:chat_id], thread_id: context[:thread_id])
        klass = @resolver.call(resolved.game_system)
        name = klass ? display_name(klass, resolved.game_system) : resolved.game_system

        origin =
          case resolved.scope
          when TenguDB::Scope::THREAD then "来源：本话题设置"
          when TenguDB::Scope::GROUP then "来源：本群设置"
          else "来源：全局默认（该群尚未设置）"
          end

        hint =
          if resolved.scope == TenguDB::Scope::THREAD
            "话题内执行 /system <ID> 只改本话题；本话题未设置时回落到本群/默认。"
          else
            "在话题内执行 /system <ID> 可只改那个话题。"
          end

        "当前规则系统：#{resolved.game_system}（#{name}）\n#{origin}\n#{hint}"
      end

      # 非法 ID：回一句 + 几颗可用示例（不给 338 条刷屏）
      def unknown_system(context, id)
        "未知规则系统 ID：#{id}\n" \
          "可用示例：#{examples.join('、')}\n" \
          "#{SYSTEM_USAGE}"
      end

      # 示例 ID：优先忍杀系列（本 bot 的主角），再补几个常见的上游规则
      def examples
        all = @system_ids_provider.call
        return [] if all.empty?

        preferred = all.grep(/NinjaSlayer/)
        others = (all - preferred).first(EXAMPLE_COUNT)
        (preferred + others).first(EXAMPLE_COUNT)
      end

      def display_name(klass, id)
        EngineResolver.display_name(klass, id)
      end

      # 只记结构性信息，绝不记用户正文（隐私）
      def warn_line(message)
        @logger.warn(message)
      rescue StandardError
        nil # logger 自身坏了也不能影响掷骰
      end
    end
  end
end