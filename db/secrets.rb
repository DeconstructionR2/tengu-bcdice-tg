# frozen_string_literal: true

# ============================================================================
# db/secrets.rb — 暗骰结果持久化（T3.1，计划 §3 决3 / §4.1 / §12 R6 / §15.3 E5）
#
# ── 为什么需要这张表 ────────────────────────────────────────────────────────
#   暗骰走 Bot API 10.3 的 ephemeral（is_ephemeral 命令 + ephemeral_message_parameters
#   回复），但 ephemeral 是**当下可见的短生命周期媒介**——T2.2 真机实测约 25 分钟
#   即从客户端消失（docs/t2.2-spike-report.md §3）。即：掷完看不到 ≠ 没掷过。
#   天狗本家是纯 ephemeral **不落库**（references/src/.../discord_command/snd.js
#   全文无任何持久化）；本项目用 secrets 表兜底，重启不丢、离线可取
#   （`/secret last`），这正是计划 §6「暗骰：secrets 表（**新增持久化**）」的升级点。
#
# ── 数据形状（schema.sql 已建，本文件不碰 DDL）────────────────────────────
#   id          TEXT 主键——**短随机 id**：它要进内联按钮的 callback_data，
#               而 callback_data 的平台上限是 1~64 字节；带上 `sec:` 命名空间
#               前缀后仍要留足余量，故取 16 位十六进制（64 bit 熵）。
#   chat_id     公开时回发的目标群（64 位整数，§0.2.4）
#   thread_id   公开时回发的话题（forum 不掉话题，§3 决6；0 = 群级，E4 同尺度）
#   user_id     **只有本人**可取回 / 可公开（真人 user id，非匿名管理员名）
#   command     原始骰式（诊断用；不回显到公开消息里）
#   result_text 引擎输出全文（公开时**逐字**发，不加前缀、不改格式，§13 第 7 项）
#
# ── 清理策略（§15.3 E5 定案，本文件的实现级决策）──────────────────────────
#   E5 原文只给两个方向：「公开后删除」或「加 TTL 定期清理任务」。**两条都做**：
#     ① 公开成功后删除该行（语义正确——结果已经公开，再留着就是无主残留）；
#     ② 惰性 TTL：每次写入时顺手删掉 created_at 早于 TTL_DAYS 的行。
#   为什么②是「顺手删」而不是定时任务：本服务是单文件 SQLite + 单进程长轮询，
#   **没有调度器**（无 cron/无线程池）。为此专门建定时任务等于给一个「每天每人
#   几次」的表引入一条新的常驻执行路径（要处理停机补跑、并发、重入），而暗骰行
#   本身极低频——写入时顺手扫一次的全表代价可以忽略（主键外的删除走
#   created_at 比较，无索引亦只是几十~几百行的小表扫描）。
#   ⚠️ 惰性清理的固有性质：**没有写入就没有清理**。只掷暗骰不看结果的用户会让
#   过期行滞留到「下一次有人掷暗骰」为止。对本表语义无害（过期行的授权仍受
#   user_id 约束，且 TTL 远长于 ephemeral 生命周期），但要知道这不是严格定时器。
#
# ── 纪律 ────────────────────────────────────────────────────────────────────
#   - **值一律绑定**（db/connection.rb 同款）：command/result_text 来自用户输入。
#   - **判断删没删到读 Connection#changes**：execute 返回的是结果集不是行数。
#   - 本文件**不含引擎依赖**：handler 那边已把引擎结果转成纯字符串再进来。
#
# 只读红线：本文件不修改 vendor/bundle/** 与 references/src/**。
# ============================================================================

require "securerandom"
require_relative "connection"

module TenguDB
  # --------------------------------------------------------------------------
  # 记录值对象（读出来的行；避免调用方直接摸 Hash 键名）
  # --------------------------------------------------------------------------
  class Secret
    attr_reader :id, :chat_id, :thread_id, :user_id, :command, :result_text, :created_at

    def initialize(id:, chat_id:, thread_id:, user_id:, command:, result_text:, created_at:)
      @id = id
      @chat_id = chat_id
      @thread_id = thread_id
      @user_id = user_id
      @command = command
      @result_text = result_text
      @created_at = created_at
      freeze
    end

    # 该条记录属于这个人吗？（公开按钮的**唯一**权限判据，§0.2.4：
    # 用真人 user id 比对，天然规避「匿名管理员」——名字可变、id 不可变）
    def owned_by?(candidate_user_id)
      candidate = normalize_user_id(candidate_user_id)
      !candidate.nil? && candidate == normalize_user_id(user_id)
    end

    def to_h
      { id: id, chat_id: chat_id, thread_id: thread_id, user_id: user_id,
        command: command, result_text: result_text, created_at: created_at }
    end

    private

    # user_id 恒为正整数；nil / 空 / 非数字一律视作「不是本人」（fail-closed）
    def normalize_user_id(value)
      return nil if value.nil?
      return nil if value.is_a?(String) && value.strip.empty?

      int = value.to_i
      int.positive? ? int : nil
    end
  end

  # --------------------------------------------------------------------------
  # Secrets：暗骰结果的存取
  # --------------------------------------------------------------------------
  class Secrets
    # 回调命名空间前缀（callback_data 的数据段，如 `sec:3f9c…`）。
    #
    # **为什么必须有前缀**：callback_data 是**一根共享的线上总线**，本项目将来
    # 还会长出别的按钮（T3.2 银行 / T3.4 自定义表 / T3.5 log）。裸 id 一旦和别的
    # 命名空间撞上，按钮就会去别的表里捞数据；反过来，别的命名空间的后门拿到
    # 本表的 id 就能凭空公开一条暗骰。前缀把「这个回调属于哪个子系统」的判断
    # 收敛到一个字符串常量，也让 router 层的兜底能明确回答「这不是我的按钮」。
    CALLBACK_PREFIX = "sec:"

    # 随机 id 长度（十六进制字符数）：8 字节 = 64 bit 熵。
    # 16 + len(CALLBACK_PREFIX=4) = 20 字节，距 callback_data 64 字节上限极远，
    # 将来往 data 里加别的字段（如 user 自定的短码）也有余量。
    ID_BYTES = 8
    ID_LENGTH = ID_BYTES * 2

    # TTL：7 天（实现级决策，见文件头部「清理策略」）。
    # 取 7 天而非更短：ephemeral 约 25 分钟消失，但 /secret last 的价值恰恰在
    # 「跑团中途/当天忘了结果」；取更长则与「未公开的私密结果不长期留存」的
    # 隐私直觉冲突。7 天是「覆盖一个自然周」与「不留长尾」的折中。
    TTL_DAYS = 7

    # 撞 id 的重试次数（16 位十六进制撞车概率 ≈ 2^-64，实际不可能；
    # 留着只是为了让 PK 冲突不被当成致命错误抛给 router）
    ID_ATTEMPTS = 3

    COLUMNS = "id, chat_id, thread_id, user_id, command, result_text, created_at"

    # @param connection [TenguDB::Connection, nil] nil = DB 层单连接
    def initialize(connection = nil)
      @conn = connection || Connection.instance
    end

    # ------------------------------------------------------------------
    # 写
    # ------------------------------------------------------------------

    # 存一条暗骰结果，返回 [Secret, nil]；连续撞 id 用尽则返回 [nil, 异常类]。
    #
    # 写入前**先做惰性 TTL 清理**（E5 ②）——本方法不是热路径（每人每天几次），
    # 借它做清理不引入任何新的执行路径。
    #
    # @param chat_id [Integer] 64 位
    # @param thread_id [Integer, nil] 入站 message_thread_id（未归一，原样存：
    #   公开时按记录的 thread_id 原样透传给 Telegram；nil → 0 = 群级，E4 同尺度）
    # @param user_id [Integer] 掷骰者（唯一有权限的人）
    # @param command [String] 原始骰式（诊断用）
    # @param result_text [String] 引擎输出全文
    # @return [Array(Secret, nil, Class)] [记录, nil] 或 [nil, 异常类]
    def create(chat_id:, user_id:, result_text:, command:, thread_id: nil)
      purge_expired

      text = result_text.to_s
      return [nil, ArgumentError] if text.empty?
      return [nil, ArgumentError] if chat_id.to_i.zero?
      return [nil, ArgumentError] if user_id.to_i <= 0

      chat = chat_id.to_i
      thread = thread_id.to_i
      who = user_id.to_i
      cmd = command.to_s

      ID_ATTEMPTS.times do
        id = self.class.generate_id
        begin
          conn.execute(
            "INSERT INTO secrets (#{COLUMNS}) " \
            "VALUES (?, ?, ?, ?, ?, ?, datetime('now'))",
            [id, chat, thread, who, cmd, text]
          )
          return [find(id), nil]
        rescue SQLite3::ConstraintException
          next # id 撞了：换一个新的（PK 是 id，别的约束不会这么炸）
        end
      end

      [nil, SQLite3::ConstraintException]
    end

    # 随机短 id（16 位小写十六进制；不用 base36/base62 是为了免掉大小写歧义——
    # callback_data 走一遍 URL/日志/手抄，大小写混淆过的 id 会变成查不到）
    def self.generate_id
      SecureRandom.hex(ID_BYTES)
    end

    # callback_data 编解码（唯一允许拼 callback_data 的地方）
    #
    # @param secret_id [String]
    # @return [String] 形如 `sec:3f9c…`（20 字节，远低于 64 字节上限）
    def self.callback_data(secret_id)
      "#{CALLBACK_PREFIX}#{secret_id}"
    end

    # 反解：只有本命名空间的数据段才返回 id，其余一律 nil
    # （**fail-closed**：不认识的 data 一律 nil，绝不「猜着捞一把」）
    def self.secret_id_from_callback_data(data)
      s = data.to_s
      return nil unless s.start_with?(CALLBACK_PREFIX)

      id = s[CALLBACK_PREFIX.length..].to_s
      return nil if id.empty?

      # 只接受我们自己生成的 id 形态：防止 data 里的奇怪内容被拼进 SQL 之外的
      # 任何地方（值虽一律绑定，但形态校验让日志与调试更可读）
      return nil unless /\A[0-9a-f]{#{ID_LENGTH}}\z/.match?(id)

      id
    end

    # 本 data 是不是本子系统的按钮？（router 用它决定「有没有我的 handler」）
    def self.owns_callback_data?(data)
      !secret_id_from_callback_data(data).nil?
    end

    # ------------------------------------------------------------------
    # 读
    # ------------------------------------------------------------------

    # 按 id 取一行（公开按钮的主查询路径）
    #
    # @return [Secret, nil]
    def find(id)
      key = id.to_s
      return nil if key.empty?

      row = conn.get_first_hash(
        "SELECT #{COLUMNS} FROM secrets WHERE id = ?", [key]
      )
      return nil if row.nil?

      to_secret(row)
    end

    # 某人在某群的**最近一次**暗骰结果（`/secret last` 的数据源，R6 缓解）
    #
    # 作用域刻意是 **(chat_id, user_id)** 而非「全局最近」：
    #   - 跨群的 id 不该互相可见（A 群的按钮载荷拿到 B 群的行）；
    #   - 公开时用的是**记录里的** chat_id/thread_id，本来就是原地回发，
    #     「在哪掷的就在哪取回」也符合用户心智。
    #
    # created_at 只有秒级精度，同秒连掷两条会并列 → rowid DESC 兜底取后写的。
    #
    # @return [Secret, nil]
    def latest_for(chat_id:, user_id:)
      chat = chat_id.to_i
      who = user_id.to_i
      return nil if who <= 0

      row = conn.get_first_hash(
        "SELECT #{COLUMNS} FROM secrets WHERE chat_id = ? AND user_id = ? " \
        "ORDER BY created_at DESC, rowid DESC LIMIT 1",
        [chat, who]
      )
      return nil if row.nil?

      to_secret(row)
    end

    # 该 (chat, user) 名下还有几行（诊断/测试用）
    def count_for(chat_id: nil, user_id: nil)
      sql = +"SELECT count(*) FROM secrets WHERE 1 = 1"
      params = []
      if chat_id
        sql << " AND chat_id = ?"
        params << chat_id.to_i
      end
      if user_id
        sql << " AND user_id = ?"
        params << user_id.to_i
      end
      conn.get_first_value(sql, params).to_i
    end

    # ------------------------------------------------------------------
    # 删
    # ------------------------------------------------------------------

    # 删一行（公开成功后调用，E5 ①）
    #
    # @return [Boolean] 是否真的删掉了一行——读 Connection#changes，
    #   **不能**拿 execute 的返回值判断（它返回结果集，DELETE 恒为 []）
    def delete(id)
      key = id.to_s
      return false if key.empty?

      conn.execute("DELETE FROM secrets WHERE id = ?", [key])
      conn.changes.positive?
    end

    # 惰性 TTL 清理（E5 ②）：删掉 created_at 早于 ttl_days 天的行
    #
    # created_at 与 schema 的 `datetime('now')` 同尺度（UTC 'YYYY-MM-DD HH:MM:SS'），
    # 与 `datetime('now', '-N days')` 同格式 → 可直接字符串比较。
    #
    # @return [Integer] 本次删掉的行数
    def purge_expired(ttl_days: TTL_DAYS)
      days = ttl_days.to_i
      days = TTL_DAYS if days <= 0

      conn.execute(
        "DELETE FROM secrets WHERE created_at < datetime('now', ?)",
        ["-#{days} days"]
      )
      conn.changes
    end

    private

    attr_reader :conn

    def to_secret(row)
      Secret.new(
        id: row["id"],
        chat_id: row["chat_id"].to_i,
        thread_id: row["thread_id"].to_i,
        user_id: row["user_id"].to_i,
        command: row["command"].to_s,
        result_text: row["result_text"].to_s,
        created_at: row["created_at"].to_s
      )
    end
  end
end