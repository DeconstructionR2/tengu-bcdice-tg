# frozen_string_literal: true

require "json"
require "logger"
require "tmpdir"

# ============================================================================
# bot/handlers/session_log.rb — 跑团 log 录制与导出 /log（T3.5）
#
# 计划依据：§6（/log new/on/off/end/list）/ §8 T3.5（录制、暂停/继续、结束、
# 导出 txt+json 由 bot 发 document 到群、/log list）/ §13 第 6 项定案（对标
# 海豹 .log 工作流；第一版只做通用文本导出，专用染色器格式适配留 backlog）/
# §12 R8（隐私边界：显式 /log new 才开录 + 群内明示 + .env 主开关 +
# 导出文件仅发回原群/原话题）。
#
# ── 子命令 ────────────────────────────────────────────────────────────────
#   /log new <名>   开录（作用域 = 入站 (chat_id, thread_id) 归一后的话题级）
#   /log off        暂停（recording → paused）
#   /log on         继续（paused → recording）
#   /log end        结束（任一进行中状态 → ended）并导出 txt+json **发回原作用域**
#   /log list       本作用域的录制清单（最新在前，最多 LIST_LIMIT 条）
#   /log help       用法（无参同）
#
# ── 群内明示（R8 的缓解措施逐条落地）──────────────────────────────────────
#   开录/暂停/继续/结束都有回执（明文写进群里）；导出文件只发到 log 自己的
#   (chat_id, thread_id)——即用户当初在哪儿开的录。thread 透传用 **log 的
#   归一后 thread_id**（0=群级 → 不发 message_thread_id；>1 → 发），与 T3.1
#   评审修的「0→nil 归一防 forum 群 400」同一纪律。
#
# ── LOGGING_ENABLED=0（.env 主开关）──────────────────────────────────────
#   本 handler 的每个子命令（含无参与 help）都回「未启用」——不装死、不部分
#   可用。录制侧的短路在 bot/session_log_recorder.rb（enabled: false 时一次
#   DB 都不碰），main.rb 把同一个 Config.logging_enabled? 同时传给两处。
#
# ── 导出格式（实现级决策，样例见 docs/t3.5-report.md §3）──────────────────
#   txt：头部（名/作用域/时间段/条目数）+ 逐行 `[seq] 时间 名：内容`
#        （bot 条目在名字前加 `[bot] ` 标记）；按 seq 升序，逐字保真。
#   json：{format, version, log{...}, entries[{seq, sender_name, user_id,
#         is_bot, msg_kind, content, created_at}]}（JSON.pretty_generate）。
#   两个文件用同一份数据渲染，同一个临时目录里写好、发完即删。
#
# ── 其余纪律 ─────────────────────────────────────────────────────────────
#   - 消息里**绝不回显**无关用户输入；名字回显限 ≤100 字符（DB 层已校验）。
#   - 导出失败（网络/API）不回滚已结束的录制——数据都在库里，回执里讲清
#     「录制已结束、文件没发出去」，不假装成功（不把发送失败说成已发送）。
#   - 本 handler 不走 Admin 权限助手：录制的开关是**群内任何人**可用的功能
#     （R8 的隐私靠「显式开录 + 群内明示」而不是权限——录的是本群自己说的话，
#     这是实施级决策，见报告 §4）。
#
# 只读红线：本文件不修改 vendor/bundle/** 与 references/src/**。
# ============================================================================

require_relative "../../db/session_logs"
require_relative "../../db/settings"

module TelegramBot
  module Handlers
    # ----------------------------------------------------------------------
    # SessionLogHandler
    # ----------------------------------------------------------------------
    class SessionLogHandler
      # 无参 /log 与 /log help 的用法表
      USAGE = <<~USAGE.chomp
        跑团 log 录制（每个群/话题各自一份，互不相通）
        /log new <名> — 开始录制本群/话题的消息（含 bot 掷骰结果）
        /log off — 暂停录制；/log on — 继续录制
        /log end — 结束录制，并把 txt+json 两个导出文件发到本群/话题
        /log list — 查看本群/话题的录制记录列表
        说明：只有显式开录后才会记录；文件也只发回本群/话题。
      USAGE

      UNKNOWN_SUBCOMMAND = "未知子命令。用 /log help 查看用法。"

      # LOGGING_ENABLED=0：全部子命令的统一应答（不装死——菜单上架命令必须有应答）
      DISABLED = "跑团 log 录制功能未启用（运维开关 LOGGING_ENABLED=0）。请联系运营方开启。"

      # 名字缺失（/log new 没给名）
      NAME_REQUIRED = "给这次录制起个名字：/log new <名>（例：/log new 第一次跑团）"

      # DB 层拒收名字（空/超 100 字符/含控制字符；空名上面已拦，这里兜余下两种）
      BAD_NAME = "这个名字用不了：请用 1～#{TenguDB::SessionLogs::MAX_NAME_LENGTH} 个字符、不含换行等控制字符的名字。"

      STORAGE_ERROR = "存储故障：这次操作没有完成，请稍后再试。"

      # /log end 的文件已发出 / 没发出 两种回执（不把失败说成成功）
      EXPORT_SENT = "已结束录制「%s」（共 %d 条），导出文件（txt + json）已发送。"
      EXPORT_FAILED = "已结束录制「%s」（共 %d 条），但导出文件发送失败——录制数据已保留在服务器，可联系管理员重导出。"

      # list 单次最多展示的条数（更早的只提示存在；防止刷屏）
      LIST_LIMIT = 10

      def initialize(session_logs: nil, enabled: true, logger: ::Logger.new($stderr))
        @session_logs = session_logs
        @enabled = enabled ? true : false
        @logger = logger
      end

      # 懒加载：注入了假 store 的用例完全不碰 SQLite
      def session_logs
        @session_logs ||= TenguDB::SessionLogs.new
      end

      # router 的 handler 注册表接口
      def self.registry(handler = new)
        { log: handler }
      end

      # ------------------------------------------------------------------
      # 统一入口（返回 String = 由 router 代发；nil = 静默）
      # ------------------------------------------------------------------
      def call(context)
        return nil unless context[:name].to_s == "log"
        return DISABLED unless @enabled

        chat_id = context[:chat_id].to_i
        # 拿不到 chat_id → 归不到任何作用域；静默（不该发生：入站消息必有 chat）
        return nil if chat_id.zero?

        args = context[:args].to_s.strip
        return USAGE if args.empty?

        verb, rest = args.split(/\s+/, 2)
        case verb.to_s.downcase
        when "new" then sub_new(context, chat_id, rest.to_s.strip)
        when "off" then sub_off(context, chat_id)
        when "on" then sub_on(context, chat_id)
        when "end" then sub_end(context, chat_id)
        when "list" then sub_list(context, chat_id)
        when "help" then USAGE
        else UNKNOWN_SUBCOMMAND
        end
      rescue StandardError => e
        # handler 抛异常会被 router 静默吞掉（用户只看到没反应），故兜底回话
        warn_line("[session_log] 未捕获异常：#{e.class}")
        STORAGE_ERROR
      end

      # ------------------------------------------------------------------
      # new / off / on / end / list
      # ------------------------------------------------------------------

      def sub_new(context, chat_id, name)
        return NAME_REQUIRED if name.empty?

        result = session_logs.start(chat_id: chat_id, thread_id: context[:thread_id],
                                    name: name)
        log = result.log

        case result.status
        when TenguDB::LogResult::OK
          "已开始录制「#{log.name}」（log ##{log.id}）。本#{scope_word(context)}的消息将开始记录；" \
            "/log off 暂停，/log end 结束并导出。"
        when TenguDB::LogResult::ALREADY_ACTIVE
          "本#{scope_word(context)}已有进行中的录制「#{log.name}」（##{log.id}，#{log.status_label}）。" \
            "先 /log end 结束它，再开新的。"
        when TenguDB::LogResult::INVALID_NAME
          BAD_NAME
        else
          STORAGE_ERROR
        end
      end

      def sub_off(context, chat_id)
        result = session_logs.pause(chat_id: chat_id, thread_id: context[:thread_id])

        case result.status
        when TenguDB::LogResult::OK
          "已暂停录制「#{result.log.name}」。/log on 继续，/log end 结束并导出。"
        when TenguDB::LogResult::ALREADY_PAUSED
          "录制「#{result.log.name}」已处于暂停状态。/log on 继续，/log end 结束并导出。"
        else
          no_active_message(context)
        end
      end

      def sub_on(context, chat_id)
        result = session_logs.resume(chat_id: chat_id, thread_id: context[:thread_id])

        case result.status
        when TenguDB::LogResult::OK
          "已继续录制「#{result.log.name}」。"
        when TenguDB::LogResult::ALREADY_RECORDING
          "录制「#{result.log.name}」本来就在进行中。"
        else
          no_active_message(context)
        end
      end

      def sub_end(context, chat_id)
        result = session_logs.finish(chat_id: chat_id, thread_id: context[:thread_id])
        return no_active_message(context) unless result.status == TenguDB::LogResult::OK

        log = result.log
        # finish 之后录制已停止：这里的读库是**收尾导出**，不是录制路径
        entries = session_logs.entries(log.id)

        begin
          send_exports(context, log, entries)
        rescue StandardError => e
          # 发送失败不回滚已结束的录制（数据都在库里）；回执如实说失败
          warn_line("[session_log] 导出发送失败（log=#{log.id}）：#{e.class}")
          return format(EXPORT_FAILED, log.name, entries.size)
        end

        format(EXPORT_SENT, log.name, entries.size)
      end

      def sub_list(context, chat_id)
        logs = session_logs.list(chat_id: chat_id, thread_id: context[:thread_id],
                                 limit: LIST_LIMIT + 1)
        return "本#{scope_word(context)}还没有跑团 log。用 /log new <名> 开始。" if logs.empty?

        overflow = logs.size > LIST_LIMIT
        shown = overflow ? logs.first(LIST_LIMIT) : logs
        lines = ["本#{scope_word(context)}的跑团 log（最新在前）："]
        lines.concat(shown.map { |log| render_list_line(log) })
        lines << "（只显示最近 #{LIST_LIMIT} 条，更早的未列出）" if overflow
        lines.join("\n")
      end

      # ------------------------------------------------------------------
      # 导出渲染（公开以便直测；两个文件同一份数据）
      # ------------------------------------------------------------------

      # txt 导出：头部 + 逐行 `[seq] 时间 名：内容`（bot 行加 `[bot] ` 前缀）
      #
      # 按 seq 升序（条目本来就以 seq 升序读出；这里不重排——重排会掩盖
      # DB 层的排序 bug，测试要能钉住「导出序 == seq 序」）。
      def render_txt(log, entries)
        scope = log.thread_id.positive? ? "群 #{log.chat_id} / 话题 #{log.thread_id}" \
                                        : "群 #{log.chat_id}"
        lines = []
        lines << "===== 跑团 log：#{log.name} ====="
        lines << "作用域：#{scope}"
        lines << "时间段：#{log.created_at} ～ #{log.ended_at}（UTC）" # kimi T3.5 评审提案 #7：UTC 必须标注
        lines << "条目数：#{entries.size}"
        lines << "-----"
        entries.each do |entry|
          marker = entry.bot? ? "[bot] " : ""
          # 多行内容缩进续行（2026-10-18 审核）：此前 content 里的换行原样
          # 拼进输出，任何成员发一条含 `\n[0099] … 名：…` 的消息就能在导出里
          # 伪造出一条与真实条目同形的新行（json 导出不受影响）。
          # 续行统一加 4 空格前缀：内容不丢，且不再与本格式的行首同形。
          lines << format("[%04d] %s %s%s：%s",
                          entry.seq, entry.created_at, marker,
                          txt_indent(entry.sender_name), txt_indent(entry.content))
        end
        "#{lines.join("\n")}\n"
      end

      # txt 导出的多行安全化：CR/LF 与 Unicode 行/段分隔符 → 换行 + 4 空格缩进
      def txt_indent(text)
        text.to_s.gsub(/\r\n|\r|\n|\u2028|\u2029/, "\n    ")
      end

      # json 导出：结构化全字段（is_bot 在 json 里是布尔，落库形态是 0/1）
      def render_json(log, entries)
        JSON.pretty_generate(
          "format" => "tengu-bcdice-tg/session-log",
          "version" => 1,
          "log" => {
            "id" => log.id, "name" => log.name, "chat_id" => log.chat_id,
            "thread_id" => log.thread_id, "status" => log.status,
            "created_at" => log.created_at, "ended_at" => log.ended_at
          },
          "entries" => entries.map do |entry|
            {
              "seq" => entry.seq, "sender_name" => entry.sender_name,
              "user_id" => entry.user_id, "is_bot" => entry.bot?,
              "msg_kind" => entry.msg_kind, "content" => entry.content,
              "created_at" => entry.created_at
            }
          end
        )
      end

      private

      # 导出并发送两个 document。**只发回 log 自己的 (chat_id, thread_id)**。
      #
      # thread 归一：log.thread_id 在落库时已归一（0=群级）；0 → 不发
      # message_thread_id（Ruby 里 0 为真，直接透传会把 `message_thread_id: 0`
      # 拍上 wire，forum 群有 400 风险——T3.1 评审修过的同款坑）。General
      # 话题（入站 1 → 归一 0）因此也发到 General，语义正确。
      def send_exports(context, log, entries)
        api = context[:api]
        raise "no api injected" if api.nil?

        thread_id = log.thread_id.positive? ? log.thread_id : nil
        txt_name = "tengu-log-#{log.id}.txt"
        json_name = "tengu-log-#{log.id}.json"

        Dir.mktmpdir("tengu-log-") do |dir|
          txt_path = File.join(dir, txt_name)
          json_path = File.join(dir, json_name)
          File.write(txt_path, render_txt(log, entries))
          File.write(json_path, render_json(log, entries))

          api.send_document(log.chat_id, txt_path, thread_id: thread_id,
                            caption: caption(log, entries, "txt"), filename: txt_name)
          api.send_document(log.chat_id, json_path, thread_id: thread_id,
                            caption: caption(log, entries, "json"), filename: json_name)
        end
      end

      def caption(log, entries, kind)
        "跑团 log「#{log.name}」· #{kind} 导出（#{entries.size} 条）"
      end

      def render_list_line(log)
        if log.ended?
          "##{log.id}「#{log.name}」 已结束（#{log.entry_count} 条） #{log.created_at} ～ #{log.ended_at}"
        else
          "##{log.id}「#{log.name}」 #{log.status_label}（#{log.entry_count} 条） 开始 #{log.created_at}"
        end
      end

      def no_active_message(context)
        "本#{scope_word(context)}没有进行中的录制。用 /log new <名> 开始。"
      end

      # 作用域显示词（E4 归一后判话题级；与 bank.rb 同款）
      def scope_word(context)
        thread = TenguDB::Settings.normalize_thread_id(context[:thread_id])
        thread > TenguDB::Settings::GENERAL_THREAD_ID ? "话题" : "群"
      end

      # 只记结构性信息，绝不记用户正文/名字
      def warn_line(message)
        @logger.warn(message)
      rescue StandardError
        nil
      end
    end
  end
end
