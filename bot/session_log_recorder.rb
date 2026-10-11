# frozen_string_literal: true

require "logger"

# ============================================================================
# bot/session_log_recorder.rb — 跑团 log 录制的「消息 → 条目」桥（T3.5）
#
# 这是 router **dispatch 集中挂钩**背后的小对象：router 只认两个方法
# （`record_incoming` / `record_bot_output`），把 Telegram 消息对象与作用域
# 交给它；其余（作用域是否在录、非文本分类、发送者名、落库）全在这里。
# 这样 router 保持「不碰 DB、不碰 gem 细节」的既有纪律（测试注入假身即可）。
#
# ── 两条录制面（对应计划 §13 第 6 项定案「录全部文本消息 + bot 掷骰结果」）
#
#   ① record_incoming（用户侧，is_bot=0）：
#      - 文本消息 → msg_kind="text"，content=原文；
#      - **非文本消息** → 按媒体种类记占位符（msg_kind="photo"，content="（照片）"，
#        见 KIND_PLACEHOLDERS）。**无可识别内容的服务消息**（入群/置顶/话题创建/
#        改名等）不录——它们不是「谁说了什么」，录进来只会是噪声（实现级决策，
#        见 docs/t3.5-report.md）。
#      - **captions 不单独提取**：带图带字的消息只记占位符（计划口径「非文本记
#        占位符」；把 caption 混进占位符会制造「半条文本」的模糊语义）。
#   ② record_bot_output（bot 侧，is_bot=1，user_id=NULL）：router 代发的
#      handler 返回值（掷骰结果、命令应答……）。sender_name = 注入的 bot_name。
#
# ── 暗骰（防泄纪律 > 录制完整度）────────────────────────────────────────────
#   `/secret` 的结果**从不经过本对象**（SecretDiceHandler 恒返回 nil、自己走
#   ephemeral 发送）——这是结构性保证，不靠 if 判断。`/secret` 命令消息的
#   排除在 **router 层**做（ephemeral 命令群内不可见，录进去会泄露「某人做了
#   暗骰」这一元信息；见 bot/router.rb 的 record_incoming 注释）。
#
# ── 开关短路（R8 的 .env 主开关 LOGGING_ENABLED）─────────────────────────
#   enabled: false 时两个方法**立即返回 nil、一次 DB 都不碰**（main.rb 传
#   Config.logging_enabled?）。「全链路短路」由此为真：不是「录了再删」，而是
#   根本不进入录制路径。
#
# ── 故障纪律 ────────────────────────────────────────────────────────────────
#   本对象**不吞异常**：DB 故障原样抛给 router 的挂钩兜底（warn + 继续处理
#   消息）——录制坏掉不该影响掷骰/查账等主功能。
#
# 只读红线：本文件不修改 vendor/bundle/** 与 references/src/**。
# ============================================================================

require_relative "../db/session_logs"

module TelegramBot
  class SessionLogRecorder
    # 非文本消息 → 占位符。**顺序即判定顺序**（Ruby Hash 保序；Telegram 一条
    # 消息至多一种媒体，顺序只影响理论上的多重判别）。字段名与 gem Message
    # 的 dry-struct 属性一致；缺失属性读出来是 nil，故一律「非 nil 即命中」。
    # ⚠️ 名单只收**用户可发送的内容型消息**；服务消息（new_chat_members /
    #    pinned_message / new_chat_title / forum_topic_* 等）刻意不在内——跳过。
    KIND_PLACEHOLDERS = {
      "photo" => "（照片）",
      "sticker" => "（贴纸）",
      "voice" => "（语音）",
      "video" => "（视频）",
      "video_note" => "（视频留言）",
      "animation" => "（动图）",
      "audio" => "（音频）",
      "document" => "（文件）",
      "location" => "（位置）",
      "venue" => "（地点）",
      "contact" => "（联系人）",
      "poll" => "（投票）",
      "dice" => "（骰子）",
      "game" => "（游戏）"
    }.freeze

    # 拿不出任何名字时的兜底（匿名管理员/服务消息等边缘形状）
    UNKNOWN_SENDER = "（未知）"

    attr_reader :session_logs, :bot_name

    # @param session_logs [TenguDB::SessionLogs, nil] nil = DB 层单连接
    # @param enabled [Boolean] LOGGING_ENABLED 主开关（false = 全链路短路）
    # @param bot_name [String] bot 条目的 sender_name（导出文本里的显示名）
    # @param logger [#warn, nil] 只记结构性信息，绝不记用户正文
    def initialize(session_logs: nil, enabled: true, bot_name: "骰子bot",
                   logger: ::Logger.new($stderr))
      @session_logs = session_logs
      @enabled = enabled ? true : false
      @bot_name = bot_name.to_s.empty? ? "骰子bot" : bot_name.to_s
      @logger = logger
    end

    # 懒加载：注入了假 store 的用例完全不碰 SQLite
    def session_logs
      @session_logs ||= TenguDB::SessionLogs.new
    end

    def enabled?
      @enabled
    end

    # ------------------------------------------------------------------
    # ① 用户侧：一条入站消息
    # ------------------------------------------------------------------
    #
    # @param message [Telegram::Bot::Types::Message]
    # @param chat_id [Integer]
    # @param thread_id [Integer, nil] 入站 message_thread_id（归一归 DB 层）
    # @return [TenguDB::LogEntry, nil] nil = 未录（未启用/不在录/无可录内容）
    def record_incoming(message:, chat_id:, thread_id: nil)
      return nil unless @enabled
      return nil if message.nil?

      kind, content = classify(message)
      return nil if kind.nil?

      log = session_logs.recording_for(chat_id: chat_id, thread_id: thread_id)
      return nil if log.nil?

      sender = sender_of(message)
      session_logs.append_entry(
        log_id: log.id,
        sender_name: sender[:name],
        user_id: sender[:user_id],
        is_bot: 0,
        msg_kind: kind,
        content: content
      )
    end

    # ------------------------------------------------------------------
    # ② bot 侧：router 代发的一条输出
    # ------------------------------------------------------------------
    #
    # @param text [String] router 代发的原文（逐字落盘）
    # @return [TenguDB::LogEntry, nil]
    def record_bot_output(chat_id:, thread_id: nil, text:)
      return nil unless @enabled
      return nil if text.to_s.empty?

      log = session_logs.recording_for(chat_id: chat_id, thread_id: thread_id)
      return nil if log.nil?

      session_logs.append_entry(
        log_id: log.id,
        sender_name: bot_name,
        user_id: nil,
        is_bot: 1,
        msg_kind: "text",
        content: text.to_s
      )
    end

    private

    # 消息 → [msg_kind, content]。
    #   文本消息（text 非空）→ ["text", 原文]
    #   非文本 → 命中媒体列表 → [英文种类, 中文占位符]
    #   其余（服务消息等）→ [nil, nil]（不录）
    def classify(message)
      text = message.respond_to?(:text) ? message.text : nil
      return ["text", text.to_s] unless text.nil? || text.to_s.empty?

      KIND_PLACEHOLDERS.each do |kind, placeholder|
        next unless message.respond_to?(kind)

        value = begin
          message.public_send(kind)
        rescue StandardError
          nil
        end
        return [kind, placeholder] unless value.nil?
      end

      [nil, nil]
    end

    # 发送者显示名：first_name [+ last_name] → @username → sender_chat.title
    # → UNKNOWN_SENDER。user_id 拿不到时留 nil（schema 允许，bot 条目本就是 NULL）。
    def sender_of(message)
      from = message.respond_to?(:from) ? message.from : nil
      name = display_name(from)
      user_id = (from && from.respond_to?(:id)) ? from.id : nil

      if name.nil?
        sender_chat = message.respond_to?(:sender_chat) ? message.sender_chat : nil
        name = sender_chat.respond_to?(:title) ? sender_chat.title : nil if sender_chat
      end

      { name: (name.nil? || name.to_s.empty?) ? UNKNOWN_SENDER : name.to_s,
        user_id: user_id.nil? ? nil : user_id.to_i }
    end

    def display_name(from)
      return nil if from.nil?

      first = from.respond_to?(:first_name) ? from.first_name : nil
      last = from.respond_to?(:last_name) ? from.last_name : nil
      full = [first, last].compact.map(&:to_s).reject(&:empty?).join(" ")
      return full unless full.empty?

      username = from.respond_to?(:username) ? from.username : nil
      return "@#{username}" unless username.nil? || username.to_s.empty?

      nil
    end

    def warn_line(message)
      @logger.warn(message)
    rescue StandardError
      nil
    end
  end
end
