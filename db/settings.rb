# frozen_string_literal: true

# ============================================================================
# db/settings.rb — chat_settings 读写（T2.4）
#
# 语义（计划 §3 决6 / §4.1 / §13 第 5 项 + §15.3 E4）：
#
#   键 = (chat_id, thread_id) 复合键。
#   **E4 定案：thread_id ∈ {0, 1} 都视为群级作用域**——forum 群所有消息都带
#   message_thread_id，General 话题恒为 1，于是「话题外打 = 群默认」在 forum 群
#   内**根本没有对应场景**（§15.3 E4 原文）。把 0 与 1 归一为群级后：
#     - 普通群/超级群（无 forum）：message_thread_id 缺失 → 0 → 群级；
#     - forum 的 General 话题：thread_id=1 → 群级（用户心智 = 「群默认」）；
#     - forum 的其它话题：thread_id>1 → 话题级。
#   写路径因此**只有两个落点**：话题内 → (chat, >1)；话题外或 General → (chat, 0)。
#
#   查找顺序（三级，§3 决6）：话题设置 → 群默认 → 全局默认 NinjaSlayer2Ex。
#
# ── aux_enabled（T2.6）：**只走群级行，不分话题** ─────────────────────────
#
#   计划 §6 的口径是「每群 /settings 可关辅助轨」——**按群一份**，故读写都
#   固定 thread_id=0（话题内执行 `/settings aux off` 也写群级行；话题行里
#   的 aux_enabled 一律不读）。这与 game_system 的三级查找是**刻意不同**的：
#   规则系统是「话题可以有自己的」，辅助轨开关是「这个群烦不烦抢话」——
#   让每个话题各关各的只会制造「A 话题以为关了、B 话题还在抢」的错觉。
#   （想改成话题级只需把下面的 GROUP_THREAD_ID 换成归一后的 thread_id，
#     但那要改 /settings 的文案与本注释，故明写为不可随手改。）
#
# 本文件**不碰引擎**（不知道 NinjaSlayer2Ex 是否注册）——ID 校验是 bot 层的
# 职责（bot/handlers/dice.rb 拿 BCDice.all_game_systems 校验）。保持 DB 层纯净，
# 也让 DB 层单测不必 bootstrap 引擎。
# ============================================================================

require_relative "connection"

module TenguDB
  # --------------------------------------------------------------------------
  # 作用域与查找结果
  # --------------------------------------------------------------------------

  # 查找结果的来源。handler 靠它决定回复文案（「本话题」/「本群」/「默认」）。
  module Scope
    THREAD = :thread   # 命中 (chat_id, thread_id>1) 的行
    GROUP  = :group    # 命中 (chat_id, 0) 的行（含 forum General 话题写入）
    DEFAULT = :default # 两级都没命中 → 全局默认常量
  end

  # Resolved：一次查找的完整结果（值 + 来源 + 归一后的作用域）
  class Resolved
    attr_reader :chat_id, :thread_id, :game_system, :scope

    def initialize(chat_id:, thread_id:, game_system:, scope:)
      @chat_id = chat_id
      @thread_id = thread_id
      @game_system = game_system
      @scope = scope
      freeze
    end

    # 群级作用域？（回群默认 → 文案「本群」）
    def group_level?
      scope != Scope::THREAD
    end

    # 显示名（/system 无参时回显来源用）
    def scope_label
      case scope
      when Scope::THREAD then "本话题"
      when Scope::GROUP then "本群"
      else "默认"
      end
    end

    def to_h
      { chat_id: chat_id, thread_id: thread_id,
        game_system: game_system, scope: scope }
    end
  end

  # --------------------------------------------------------------------------
  # Settings
  # --------------------------------------------------------------------------
  class Settings
    # 全局默认（§4.1 chat_settings 的列默认值）
    DEFAULT_GAME_SYSTEM = "NinjaSlayer2Ex"

    # 辅助轨开关的全局默认（T2.6）：**开**。
    # 与 schema.sql 的 `aux_enabled INTEGER NOT NULL DEFAULT 1` 一致——
    # 未设置过的群读不到行 → 回这里。两处默认值必须同，否则「库里有行但
    # 值为 0」与「库里没有行」两种群的默认行为会不一致（前者关、后者开）。
    DEFAULT_AUX_ENABLED = true

    # 群级作用域的 thread_id（E4：forum General 话题 = 1）
    GROUP_THREAD_ID = 0
    GENERAL_THREAD_ID = 1

    # @param connection [TenguDB::Connection]
    def initialize(connection = nil)
      @conn = connection || Connection.instance
    end

    # --- 作用域工具（模块级纯函数，handler 也用） ---------------------------

    # 入站 thread_id（可能 nil / 0 / 1 / >1）→ 存储层 thread_id。
    #
    # 归一规则（E4）：nil、0、1 → 0（群级）；>1 → 原值（话题级）。
    # **写与读都必须过这一层**，否则 General 话题写的行落在 thread_id=1，
    # 而普通群查的是 thread_id=0 → 互相看不见。
    def self.normalize_thread_id(thread_id)
      t = thread_id.to_i
      return GROUP_THREAD_ID if t <= GENERAL_THREAD_ID # 负数/0/1 一律归群级

      t
    end

    # 入站 thread_id 是否指向**真话题**（即 /system 应写话题级而非群级）
    def self.topic_scope?(thread_id)
      normalize_thread_id(thread_id) > GENERAL_THREAD_ID
    end

    def self.topic_thread_id(thread_id)
      normalize_thread_id(thread_id)
    end

    # --- 读 -----------------------------------------------------------------

    # 三级查找：话题设置 → 群默认 → 全局默认。
    #
    # @param chat_id [Integer] 64 位（§0.2.4）
    # @param thread_id [Integer, nil] 入站 message_thread_id
    # @return [Resolved] 永不为 nil（最差回全局默认）
    def resolve(chat_id, thread_id: nil)
      raw_thread = thread_id.to_i
      topic_thread = self.class.normalize_thread_id(raw_thread)

      if self.class.topic_scope?(raw_thread)
        row = fetch_row(chat_id, topic_thread)
        return Resolved.new(chat_id: chat_id, thread_id: topic_thread,
                            game_system: row["game_system"], scope: Scope::THREAD) if row
      end

      group_row = fetch_row(chat_id, GROUP_THREAD_ID)
      return Resolved.new(chat_id: chat_id, thread_id: GROUP_THREAD_ID,
                          game_system: group_row["game_system"],
                          scope: Scope::GROUP) if group_row

      Resolved.new(chat_id: chat_id, thread_id: GROUP_THREAD_ID,
                   game_system: DEFAULT_GAME_SYSTEM, scope: Scope::DEFAULT)
    end

    # 只要系统 ID 的简写（handler 的热路径）
    def game_system(chat_id, thread_id: nil)
      resolve(chat_id, thread_id: thread_id).game_system
    end

    # 直读某一行（原始形态，不做级联）——测试与诊断用
    def fetch_row(chat_id, thread_id)
      normalized = self.class.normalize_thread_id(thread_id)
      @conn.get_first_hash(
        "SELECT chat_id, thread_id, game_system, aux_enabled, updated_at " \
        "FROM chat_settings WHERE chat_id = ? AND thread_id = ?",
        [chat_id.to_i, normalized]
      )
    end

    # 该群已显式设置过的全部行（不含全局默认），按 thread_id 升序
    # （/settings 展示与测试断言用；单群行数天然很小）
    def entries_for_chat(chat_id)
      @conn.execute_query(
        "SELECT chat_id, thread_id, game_system, aux_enabled, updated_at " \
        "FROM chat_settings WHERE chat_id = ? ORDER BY thread_id ASC",
        [chat_id.to_i]
      ).map do |(chat, thread, system, aux, updated)|
        { "chat_id" => chat, "thread_id" => thread,
          "game_system" => system, "aux_enabled" => aux,
          "updated_at" => updated }
      end
    end

    # --- 写 -----------------------------------------------------------------

    # 写一条设置（UPSERT）。thread_id 走归一：
    #   话题内（>1）→ 写话题行；话题外/General（0/1/nil）→ 写群级行。
    #
    # @param game_system [String] 规则系统 ID（**调用方已校验存在性**）
    # @return [Integer] 实际落库的 thread_id（回给 handler 判作用域文案）
    def set_game_system(chat_id, thread_id: nil, game_system:)
      chat = chat_id.to_i
      thread = self.class.normalize_thread_id(thread_id)
      id = game_system.to_s

      @conn.execute(
        "INSERT INTO chat_settings (chat_id, thread_id, game_system, updated_at) " \
        "VALUES (?, ?, ?, datetime('now')) " \
        "ON CONFLICT(chat_id, thread_id) DO UPDATE SET " \
        "game_system = excluded.game_system, updated_at = excluded.updated_at",
        [chat, thread, id]
      )
      thread
    end

    # 删一行（回落到上一级；/settings 复位与 T2.5 迁移收尾可能用）
    #
    # @return [Boolean] 是否真的删掉了一行（读 @conn.changes 而非 execute 的
    #   返回值——后者是结果集，DELETE 一律是空数组，拿它判断会永远 false）
    def delete(chat_id, thread_id: nil)
      @conn.execute(
        "DELETE FROM chat_settings WHERE chat_id = ? AND thread_id = ?",
        [chat_id.to_i, self.class.normalize_thread_id(thread_id)]
      )
      @conn.changes.positive?
    end

    # --- aux_enabled（T2.6）：辅助轨开关，按群一份 ---------------------------

    # 读该群的辅助轨开关
    #
    # **忽略 thread_id 参数**（接口与 game_system 对齐、便于 router 复用同一个
    # `->(chat_id, thread_id)` 形状），但语义上永远是群级：本文件头部
    # 「aux_enabled 只走群级行」一节有完整理由。
    #
    # 没有群级行 → DEFAULT_AUX_ENABLED（true，即默认开）。
    # 有行但值为 NULL（不该发生：列 NOT NULL）→ 也回默认，fail-safe。
    #
    # @return [Boolean]
    def aux_enabled(chat_id, thread_id: nil) # rubocop:disable Lint/UnusedMethodArgument
      row = @conn.get_first_hash(
        "SELECT aux_enabled FROM chat_settings WHERE chat_id = ? AND thread_id = ?",
        [chat_id.to_i, GROUP_THREAD_ID]
      )
      return DEFAULT_AUX_ENABLED if row.nil? || row["aux_enabled"].nil?

      truthy_flag?(row["aux_enabled"])
    end

    # 写该群的辅助轨开关（UPSERT 到群级行）
    #
    # 用 `ON CONFLICT DO UPDATE` **只更新 aux_enabled**：本方法绝不碰
    # game_system/updated_at 之外的东西——更准确地说，它连 game_system 都不碰，
    # 这样「管理员只改开关」不会把该群的规则系统带回列默认值
    # （INSERT 时不写 game_system，走列默认值 'NinjaSlayer2Ex'）。
    #
    # ⚠️ **与 set_game_system 的对称问题**：`set_game_system` 的 UPSERT 同样
    #   只更新 game_system，不碰 aux_enabled——故两个开关互不覆盖（各自
    #   DO UPDATE SET 自己的列）。这是刻意设计：改系统不该顺手把辅助轨打开，
    #   反之亦然。单测「与 game_system 共存不互相覆盖」钉住这条。
    #
    # @param enabled [Boolean, 0, 1, "0", "1"] 真值即写 1
    # @return [Boolean] 写入后的值（回读确认，避免 handler 报喜不报忧）
    def set_aux_enabled(chat_id, enabled:, thread_id: nil) # rubocop:disable Lint/UnusedMethodArgument
      flag = truthy_flag?(enabled) ? 1 : 0
      @conn.execute(
        "INSERT INTO chat_settings (chat_id, thread_id, aux_enabled, updated_at) " \
        "VALUES (?, ?, ?, datetime('now')) " \
        "ON CONFLICT(chat_id, thread_id) DO UPDATE SET " \
        "aux_enabled = excluded.aux_enabled, updated_at = excluded.updated_at",
        [chat_id.to_i, GROUP_THREAD_ID, flag]
      )
      aux_enabled(chat_id)
    end

    private

    # SQLite 无 BOOLEAN：整数 0/1。取值侧要能同时吃库里出来的整数、
    # 来自测试/handler 的布尔、以及字符串（手工 SQL 灌过的库）。
    #
    # 只有**明确的 0 / "0" / false / nil 之外的一切**才算真：把
    # `to_i` 直接当真值是错的——`"off".to_i == 0` 会让一个乱写的值静默变「关」。
    def truthy_flag?(value)
      case value
      when true then true
      when false, nil then false
      when String then !%w[0 false off no].include?(value.strip.downcase)
      when Numeric then !value.zero?
      else true
      end
    end

    # @conn 由 initialize 注入；此处保留 attr 以便测试注入内存库连接
    attr_reader :conn
  end
end