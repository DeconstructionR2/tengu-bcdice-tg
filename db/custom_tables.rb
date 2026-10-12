# frozen_string_literal: true

require "logger"

# ============================================================================
# db/custom_tables.rb — 天狗 CT（自定义表）db 层 12 操作（T3.3）
#
# 语义母本（**只读**，逐行对照移植）：
#   references/src/TenguDiceBot/TenguDiceBot/DB/db.js
#   references/src/TenguDiceBot/TenguDiceBot/DB/db_wrapper.js
#   references/src/TenguDiceBot/TenguDiceBot/classes/SearchTableDiceroll.js
#   references/src/TenguDiceBot/TenguDiceBot/ct_command/*.js（命令层，判定顺序的来源）
# 计划依据：§0.2.3（CT 12 操作清单与查找顺序）、§4.1（custom_tables schema）、
# §4.2（12 操作映射验收单）、§8 T3.3、§5（CT 行）。
#
# ── 天狗的数据形状与本项目的映射 ───────────────────────────────────────────
#   天狗（Firestore）：两个 collection
#       private_db / doc(Discord 频道 id) / field(表名) = {
#           dice: { 快捷名: 骰式 }, data: { 出目: 结果文本 },
#           permission: [ admin, admin, admin, 限定用户… ],
#           datarange: { isUse, max, min } }
#       public_db  / doc('99')           / field(表名) = 同上
#     换句话说天狗是「一篇文档一张 map」，本项目是「**一表一行**」——UNIQUE
#     (scope, chat_id, name)（schema.sql）取代 Firestore 的 field 名唯一性。
#   本项目（SQLite）：custom_tables 一行一张表，spec/permissions/datarange
#     三个 JSON 列（schema.sql 已建，本文件不碰 DDL）。
#
# ── 12 操作 → 本文件方法（§4.2 验收单逐条落点）─────────────────────────────
#    1 建表        → create_table      （db_wrapper.js:43 createTable）
#    2 改名        → rename_table      （db_wrapper.js:39 updateTableName）
#    3 改骰型      → update_dice       （db_wrapper.js:73 updateDice）
#    4 改条目      → update_data       （db_wrapper.js:77 updateData）
#    5 改范围钳    → set_datarange     （db_wrapper.js:81 updateAddition）
#    6 改权限      → set_permissions   （db_wrapper.js:105 updatePermission）
#    7 发布到公共  → publish_table     （db_wrapper.js:65 publishTable + ct_command/publishTable.js）
#    8 删骰型      → delete_dice       （db_wrapper.js:114 deleteDice）
#    9 删条目      → delete_data       （db_wrapper.js:117 deleteData）
#   10 删表        → delete_table      （db_wrapper.js:132 deleteTable）
#   11 按频道查全部 → all_for_chat      （db_wrapper.js:21 getAllTable）
#   12 查单表      → resolve_table     （SearchTableDiceroll.js:13-24 getTableData）
#     （+ fetch：直查单一 scope，命令层「看单表详情」用）
#
# ── 查找顺序（**逐字保留**，SearchTableDiceroll.js:14 注释原文）──────────────
#       //default -> private -> publicで検索。
#     即 default（代码内置表）→ 频道私有 → 公共。resolve_table 按同序尝试，
#     LOOKUP_ORDER 常量即该顺序本身，单元测试对该常量与三态命中做断言。
#     内置表**不在本文件**：它来自引擎侧 nd_datatable（天狗 datatable.dataTable），
#     故 resolve_table 接受一个可注入的内置源（Hash 或 callable），DB 层保持零
#     引擎依赖（与 db/settings.rb 的同一纪律）。
#     键的折叠口径照抄天狗：内置查找用 `tableName.toLowerCase()`，
#     而 Firestore 的 field 查找是**精确匹配** → 本实现同样对内置源 downcase、
#     对 DB 侧按原样精确匹配（天狗 CT 表名本就非 ASCII，见 §3 决8 纯 ASCII 定案
#     下本项目表名更不会依赖大小写折叠）。
#
# ── 与天狗的**刻意**语义差异（其余逐条忠实，详见 docs/t3.3-report.md）──────
#   ① datarange 的「不设限」用 **JSON null** 表示，天狗用 MAX/MIN_SAFE_INTEGER。
#      理由见 §4.2 明文定案（SQL 语义等价、天狗那两个哨兵值是 JS 侧的产物），
#      且本表的数据键是**用户可见的小整数**（出目），用 ±2^53 当哨兵毫无意义。
#      ⚠️ 注意：datarange 列是 `TEXT NOT NULL`，所以「SQL NULL」在列层面不可行
#      —— 定案落在 JSON 内的 null（DataRange#unbounded?）。
#   ② 权限数组存**整数** user_id（天狗存 Discord 的字符串 id）。Telegram 的
#      user_id 是 int64，与 secrets.user_id / chat_id 口径统一。比较侧
#      （permitted? / admin?）一律 to_i 归一 → 手工灌库的字符串 id 仍能命中。
#   ③ 表存在唯一性改由 UNIQUE(scope, chat_id, name) 保证，故 create/rename/
#      publish 的「同名冲突」走**先查后写 + UNIQUE 兜底**双保险，而不是像
#      Firestore 那样只靠 field 覆盖语义。
#   ④ 发布 = **复制 + 删私有**（天狗 publishTable 就是这么做的：写完公共再
#      `deleteTable(channelID)` 把私有那张删掉——是「移」不是「复制一份留着」）。
#      两步合进一个 :immediate 事务，中途失败则私有表原样不动。
#
# ── 天狗的 quirks / 语义细节（忠实保留）────────────────────────────────────
#   - delete_data 删一个本来就不存在的出目：ct_command/deleteData.js
#     `if (!userTable.data[dataIndex]) return {result:true, …}`——**视为成功**
#     并给「入力した番号のデータは存在しません」文案。本实现回 DATA_MISSING
#     状态（success? 为真），handler 据此选文案，绝不当成错误。
#   - delete_table 删一张不存在的表：Firestore 的 FieldValue.delete 删不存在的
#     field 也返回成功 → 本实现回 OK 但 changed? = false。
#   - delete_dice 删一个不存在的快捷名：同理 → OK 且表内容不变（幂等）。
#   - 权限的**位置语义**：天狗 permission 的**前三位是 admin 位**（KOOREME /
#     群主 / 建表者），改权限与删表只认前三位（ct_command/updateTableName.js、
#     addPermission.js、deletePermission.js、deleteTable.js 的 `permission[0..2]`），
#     改骰型/条目只认全体 permission。本值对象保留该语义（#admins / #admin? /
#     #permitted?），位置即权限层级，不做集合化简。
#   - deletePermission 不允许删前三位（天狗「管理範囲のチェック」）→ handler
#     层（T3.4）据此拦；db 层的 set_permissions 是**整体替换**，不内置那条限制。
#   - 发布时的数据完整性校验（ct_command/publishTable.js 的 dataVerification：
#     出目区间与登记数据数是否吻合）属于**命令层**，本 db 层不做——它需要
#     解析骰式算式，而骰式语义在引擎侧。T3.4 如需该校验，应在 handler 实现。
#
# ── 纪律 ────────────────────────────────────────────────────────────────────
#   - **值一律绑定**（db/connection.rb 同款）：表名/骰式/条目文本全来自用户输入。
#     SQL 里唯一插值的是本文件 frozen 常量（TABLE / COLUMNS / LOOKUP_ORDER…）。
#   - **多步写走 :immediate 事务**（改名 = 改名+删旧；发布 = 读+写+删；任何
#     spec/datarange/permissions 的读改写），块内**绝不 return**（sqlite3 的
#     transaction 是「BEGIN → yield → ensure commit」，块内 return 走正常路径
#     → 半截改动被提交；同 db/bank.rb 纪律）。
#   - 判断删没删到读 Connection#changes（execute 返回的是结果集不是行数）。
#   - JSON 列解析**容错**：坏 JSON 不当致命（参照 db/bank.rb 的 parse_array：
#     warn + 降级成空结构），只有异常类名进日志，绝不记用户正文。
#   - 本文件**不含引擎依赖**：内置表由调用方注入（见上）。
#
# 只读红线：本文件不修改 vendor/bundle/** 与 references/src/**。
# ============================================================================

require "json"
require_relative "connection"

module TenguDB
  # int64 上下界（SQLite INTEGER 列是动态类型，超界值会被静默存成 REAL——
  # db/bank.rb 同款守卫；kimi T3.3 评审提案 #6。界为含 INT64_MIN 的闭区间，
  # 2026-10-12 三审统一四文件口径）
  INT64_MAX = 9_223_372_036_854_775_807
  INT64_MIN = -9_223_372_036_854_775_808

  # --------------------------------------------------------------------------
  # DataRange：datarange 的值对象（isUse / max / min，**null = 不设限**）
  # --------------------------------------------------------------------------
  #
  # 天狗：{isUse: false, max: Number.MAX_SAFE_INTEGER, min: Number.MIN_SAFE_INTEGER}
  # 本项目：{isUse: false, max: null, min: null}（§4.2 定案，见文件头部①）
  class DataRange
    # 天狗的 JSON 键名逐字保留（handler 与文档都按这组键读）
    KEY_IS_USE = "isUse"
    KEY_MAX = "max"
    KEY_MIN = "min"

    attr_reader :is_use, :max, :min

    def initialize(is_use: false, max: nil, min: nil)
      @is_use = is_use ? true : false
      @max = optional_int(max)
      @min = optional_int(min)
      freeze
    end

    # 「不设限」：两端都没有上/下限（天狗那两个 MAX/MIN_SAFE_INTEGER 哨兵）
    def self.unbounded
      new(is_use: false)
    end

    def self.bounded(is_use: true, max:, min:)
      new(is_use: is_use, max: max, min: min)
    end

    # 两端都不设限？（= 天狗 isUse=false 且 max/min 仍是哨兵值的初始状态）
    def unbounded?
      @max.nil? && @min.nil?
    end

    # max < min 的倒挂钳制对 handler 毫无意义（钳完必空），本层直接拒
    def invalid_bounds?
      return false if @max.nil? || @min.nil?

      @max < @min
    end

    def to_h
      { KEY_IS_USE => @is_use, KEY_MAX => @max, KEY_MIN => @min }
    end
    alias to_json_hash to_h

    def to_s
      "#{KEY_IS_USE}=#{@is_use} #{KEY_MAX}=#{@max.inspect} #{KEY_MIN}=#{@min.inspect}"
    end

    private

    # nil / 空串 / 垃圾值 → nil（= 不设限）；整数字符串 → 整数
    def optional_int(value)
      return nil if value.nil?
      return value if value.is_a?(Integer)
      return nil if value.is_a?(String) && value.strip.empty?

      int = Integer(value.to_s, exception: false)
      int.nil? ? nil : int
    end
  end

  # --------------------------------------------------------------------------
  # CustomTable：读出来的一张表（spec / permissions / datarange 均已解析）
  # --------------------------------------------------------------------------
  class CustomTable
    SCOPE_PRIVATE = "private"
    SCOPE_PUBLIC = "public"

    attr_reader :id, :scope, :chat_id, :name, :dice, :data, :permissions,
                :datarange, :author_id, :created_at, :updated_at

    def initialize(id:, scope:, chat_id:, name:, dice:, data:, permissions:,
                   datarange:, author_id:, created_at: nil, updated_at: nil)
      @id = id.to_i
      @scope = scope.to_s
      @chat_id = chat_id.to_i
      @name = name.to_s
      @dice = stringify_map(dice).freeze
      @data = stringify_map(data).freeze
      @permissions = permissions.map(&:to_i).freeze
      @datarange = datarange
      @author_id = author_id.to_i
      @created_at = created_at.to_s
      @updated_at = updated_at.to_s
      freeze
    end

    def public?
      @scope == SCOPE_PUBLIC
    end

    def private?
      !public?
    end

    # 天狗 datatable.dataTable[tableName] 的等价物：快捷名 → 骰式
    def dice_string(dice_name)
      @dice[dice_name.to_s]
    end

    # 天狗 table.data[dataIndex]：出目（字符串数字）→ 结果文本
    def data_entry(index)
      @data[index.to_s]
    end

    # 天狗 updateDice/updateData/deleteDice/deleteData 的判据：**全体** permission
    def permitted?(user_id)
      key = normalize_user(user_id)
      !key.nil? && @permissions.include?(key)
    end

    # 天狗 updateTableName/addPermission/deletePermission/deleteTable 的判据：
    # permission 的**前三位**（admin 位）——位置即层级，不做集合化简。
    def admins
      @permissions.first(3)
    end

    def admin?(user_id)
      key = normalize_user(user_id)
      !key.nil? && admins.include?(key)
    end

    def to_h
      { id: id, scope: scope, chat_id: chat_id, name: name, dice: dice,
        data: data, permissions: permissions, datarange: datarange.to_h,
        author_id: author_id, created_at: created_at, updated_at: updated_at }
    end

    private

    def stringify_map(source)
      case source
      when Hash
        source.each_with_object({}) { |(k, v), acc| acc[k.to_s] = v.to_s }
      else
        {}
      end
    end

    # user_id 归一：nil / 空串 / 非数字 → nil（fail-closed）
    def normalize_user(value)
      return nil if value.nil?
      return nil if value.is_a?(String) && value.strip.empty?

      # 严格解析（kimi T3.3 评审提案 #5）：宽容 to_i 会把 "42abc" 折成 42——
      # 比较侧 fail-open 方向反了，必须与写入侧 normalize_user_ids 同款严格
      int = value.is_a?(Integer) ? value : Integer(value.to_s, exception: false)
      return nil if int.nil?
      return nil unless int.between?(INT64_MIN, INT64_MAX)

      int.zero? ? nil : int
    end
  end

  # --------------------------------------------------------------------------
  # MutationResult：写操作的返回值（不抛异常给 handler 分支用，同 bank.rb）
  # --------------------------------------------------------------------------
  #
  # 天狗的每个 ct_command 都返回 {result: bool, message: String}，false 分支
  # 各有固定文案。本层给 handler 一个**可判别**的三态/五态返回值：状态名决定
  # 文案，错误类名（若有）留日志，二者都不含用户正文。
  class MutationResult
    OK = :ok
    NOT_FOUND = :not_found              # 表不存在（天狗「テーブルがありません。」）
    ALREADY_EXISTS = :already_exists    # 撞名（天狗「同名のテーブルが…」/「既に存在します。」）
    INVALID_ARGUMENT = :invalid_argument # 入参不合法（命令层多半已拦，这里兜底）
    DATA_MISSING = :data_missing        # 删一个本来就没有的出目（天狗**视为成功**）
    ERROR = :error                      # 存储层失败

    attr_reader :status, :table, :error, :changed

    def initialize(status, table: nil, error: nil, changed: nil)
      @status = status
      @table = table
      @error = error
      @changed = changed
      freeze
    end

    def self.ok(table = nil, changed: true)
      new(OK, table: table, changed: changed)
    end

    def self.not_found
      new(NOT_FOUND, changed: false)
    end

    def self.already_exists
      new(ALREADY_EXISTS, changed: false)
    end

    def self.invalid_argument
      new(INVALID_ARGUMENT, changed: false)
    end

    # 天狗 deleteData 的「本就没有该出目」：**成功语义**（见文件头部）
    def self.data_missing(table = nil)
      new(DATA_MISSING, table: table, changed: false)
    end

    def self.error(error_class)
      new(ERROR, error: error_class, changed: false)
    end

    # 天狗 ct_command 的 result:true —— 含 DATA_MISSING（天狗那条路径也回 true）
    def success?
      @status == OK || @status == DATA_MISSING
    end

    def ok?
      @status == OK
    end

    def not_found?
      @status == NOT_FOUND
    end

    def already_exists?
      @status == ALREADY_EXISTS
    end

    def invalid_argument?
      @status == INVALID_ARGUMENT
    end

    def data_missing?
      @status == DATA_MISSING
    end

    def error?
      @status == ERROR
    end

    # 本次是否真的动到了数据（天狗不回这个信息；handler 用来区分
    # 「删掉了」与「本来就没有」两种成功）
    def changed?
      @changed ? true : false
    end

    def to_h
      { status: @status, table: @table&.to_h, error: @error, changed: @changed }
    end
  end

  # --------------------------------------------------------------------------
  # Resolution：查单表的结果（值 + **命中来源**）
  # --------------------------------------------------------------------------
  #
  # 来源就是查找顺序的三级：builtin（代码内置）→ private（频道私有）→ public。
  class Resolution
    SOURCES = %i[builtin private public].freeze

    attr_reader :source, :table, :builtin

    def initialize(source:, table: nil, builtin: nil)
      @source = source
      @table = table
      @builtin = builtin
      freeze
    end

    def found?
      !@table.nil? || !@builtin.nil?
    end

    def builtin?
      @source == :builtin
    end

    def private?
      @source == :private
    end

    def public?
      @source == :public
    end

    # 「这个表是哪一级来的」给 handler 的文案用（与 Settings#scope_label 同款思路）
    def source_label
      case @source
      when :builtin then "内置"
      when :private then "本群"
      else "公共"
      end
    end

    def to_h
      { source: @source, table: @table&.to_h, builtin: @builtin }
    end
  end

  # --------------------------------------------------------------------------
  # CustomTables：custom_tables 的存取（天狗 CT 12 操作）
  # --------------------------------------------------------------------------
  class CustomTables
    # ⚠️ 表名/列名是**插值**进 SQL 的（值一律绑定）。安全前提：它们来自本文件
    #   里的 frozen 字面量常量，不含任何外部输入（同 Migration::TABLES 纪律）。
    TABLE = "custom_tables"
    COLUMNS = "id, scope, chat_id, name, spec, permissions, datarange, " \
              "author_id, created_at, updated_at"

    SCOPE_PRIVATE = "private"
    SCOPE_PUBLIC = "public"
    SCOPES = [SCOPE_PRIVATE, SCOPE_PUBLIC].freeze

    # 公共表的 chat_id 占位（schema 注释：0=public 占位，避免 NULL 使 UNIQUE
    # 失效——SQLite 中 NULL 互不相等）。天狗侧对应 public_db 的固定 doc '99'。
    PUBLIC_CHAT_ID = 0

    # 天狗 createTable 的初始骰型：`dice: {a: '1d6'}`（db_wrapper.js:45-47）。
    # 其余骰型由 update_dice 逐个加。data 恒为空对象（同款）。
    DEFAULT_DICE = { "a" => "1d6" }.freeze

    # 天狗 createTable 的初始权限三元组：[KOOREME_USER_ID, guild_owner_id,
    # author_id]（db_wrapper.js:50-54）——**admin 位占满前三位**。
    # 本项目没有「bot 所有者」这个概念，故默认只放 [author_id]；handler（T3.4）
    # 要复刻群主也占一位时，显式传 permissions: 即可（位置语义不变）。
    #
    # 查找顺序（SearchTableDiceroll.js:14 原文注释）：
    #     //default -> private -> publicで検索。
    LOOKUP_ORDER = %i[builtin private public].freeze

    # @param connection [TenguDB::Connection, nil] nil = DB 层单连接
    # @param logger [#warn, nil] 只记结构性信息（异常类名），绝不记用户输入
    def initialize(connection = nil, logger: ::Logger.new($stderr))
      @conn = connection || Connection.instance
      @logger = logger
    end

    # ==================================================================
    # 操作 1：建表（天狗 createTable，db_wrapper.js:43）
    # ==================================================================
    #
    # 天狗 createTable 的完整初始物：dice {a:'1d6'} + data {} +
    # permission [owner, guild_owner, author] + datarange {isUse:false, 哨兵}。
    # 这里的差别见文件头部（权限三元组、T3.4 可显式传入；哨兵→null）。
    #
    # ⚠️ **只建私有表**：天狗也只有 publishTable 会写 public_db
    #   （db_wrapper.js:65-70：`channelID ? PRIVATE_DB : PUBLIC_DB`，
    #   而唯一传 null 的调用方就是 publishTable）——公共行只能由
    #   publish_table 产生。本层因此拒收 scope: :public。
    #
    # @param chat_id [Integer] 64 位（Telegram chat_id，§0.2.4）
    # @param name [String] 表名（非空）
    # @param author_id [Integer] 建表者
    # @param permissions [Array<Integer>, nil] nil = 只放建表者
    # @param dice [Hash, nil] nil = 天狗初始 {a:'1d6'}
    # @param datarange [DataRange, nil] nil = 不设限（天狗初始 isUse:false）
    # @return [MutationResult]
    def create_table(chat_id:, name:, author_id:, permissions: nil,
                     dice: nil, datarange: nil, scope: SCOPE_PRIVATE)
      chat = normalize_chat_id(chat_id)
      key = normalize_name(name)
      author = normalize_user_ids([author_id])&.first
      sc = normalize_scope(scope)
      # sc.nil? 必须与兄弟方法（rename/publish/edit/delete/list/count）同口径：
      # 非法 scope 字符串经 normalize_scope 得 nil，漏判会让 nil 直接进 INSERT，
      # 撞 scope 列的 NOT NULL 约束后被 rescue 误报 already_exists（2026-10-12 验收轮修复 [3]）
      return MutationResult.invalid_argument if chat.nil? || key.nil? || author.nil? || sc.nil?

      # 公共行只由发布产生（见上）
      return MutationResult.invalid_argument if sc == SCOPE_PUBLIC

      scope_name = sc
      range = coerce_datarange(datarange)
      return MutationResult.invalid_argument if range.invalid_bounds?

      perms = permissions.nil? ? [author] : normalize_user_ids(permissions)
      return MutationResult.invalid_argument if perms.nil? || perms.empty?

      spec = { "dice" => dice.nil? ? DEFAULT_DICE.dup : stringify_map(dice),
               "data" => {} }

      begin
        conn.execute(
          "INSERT INTO #{TABLE} (scope, chat_id, name, spec, permissions, " \
          "datarange, author_id, updated_at) " \
          "VALUES (?, ?, ?, ?, ?, ?, ?, datetime('now'))",
          [scope_name, chat, key, JSON.generate(spec), JSON.generate(perms),
           JSON.generate(range.to_h), author]
        )
      rescue SQLite3::ConstraintException
        # UNIQUE(scope, chat_id, name)：同一群同名。**不静默覆盖**
        # （Firestore 的同 field set 是覆盖，本项目必须显式拦——见头部③）。
        return MutationResult.already_exists
      rescue SQLite3::Exception => e
        # 存储层故障（锁竞争等）与「重名」分开：回 error 态 + 结构性 warn——
        # 与 edit_row/rename/publish 同一契约（kimi T3.3 评审提案 #4）
        warn_line("[custom_tables] 建表失败：#{e.class}")
        return MutationResult.error(e.class)
      end

      MutationResult.ok(fetch_row_to_table(scope_name, chat, key))
    end

    # ==================================================================
    # 操作 2：改名（天狗 updateTableName，db_wrapper.js:39）
    # ==================================================================
    #
    # 天狗是「按新名写一份 + 删旧名」两步（updateTableName.js:19-32），本层
    # 合成一条 UPDATE **并放进同一个 :immediate 事务**：中途失败则连旧名一起
    # 不动（天狗两步之间失败会留下**两张**表，那是 Firestore 无事务的遗留）。
    #
    # 撞名按天狗回 already_exists（「新テーブル名のデータは既に存在します。」）。
    #
    # ⚠️ 天狗此处支持 **flag t**（`data.flag ? null : ids.channelId` 走公共库）
    #   ——公共表也可改名。本层同款：`scope: :public` 时 chat_id 恒取 0 占位
    #   （与调用方在哪个群无关，同 delete_table）。**T3.3 审计已修**：原稿漏了
    #   这一分支——公共表改名**恒不可达**（传真实 chat_id → 按 (public, 真实
    #   chat_id) 查行恒 not_found；传 0 占位 → 被 normalize_chat_id 拒）。
    def rename_table(chat_id:, old_name:, new_name:, scope: SCOPE_PRIVATE)
      from = normalize_name(old_name)
      to = normalize_name(new_name)
      return MutationResult.invalid_argument if from.nil? || to.nil?

      return MutationResult.invalid_argument if from == to # 旧名与新名相同

      sc = normalize_scope(scope)
      return MutationResult.invalid_argument if sc.nil?

      # 公共行的 chat_id 是 0 占位（不来自入参）；私有行才做 chat_id 守卫
      chat = sc == SCOPE_PUBLIC ? PUBLIC_CHAT_ID : normalize_chat_id(chat_id)
      return MutationResult.invalid_argument if chat.nil?

      outcome = nil
      # 块内绝不 return：sqlite3 的 transaction 在 ensure 里 commit，块内 return
      # 走正常路径 → 半截改动会被提交。故块内只赋值 outcome。
      begin
        conn.transaction(:immediate) do
          row = fetch_row(sc, chat, from)
          if row.nil?
            outcome = MutationResult.not_found
          elsif fetch_row(sc, chat, to)
            outcome = MutationResult.already_exists
          else
            begin
              conn.execute(
                "UPDATE #{TABLE} SET name = ?, updated_at = datetime('now') " \
                "WHERE scope = ? AND chat_id = ? AND name = ?",
                [to, sc, chat, from]
              )
              outcome = MutationResult.ok(fetch_row_to_table(sc, chat, to))
            rescue SQLite3::ConstraintException
              outcome = MutationResult.already_exists
            end
          end
        end
      rescue SQLite3::Exception => e
        warn_line("[custom_tables] 改名失败：#{e.class}")
        return MutationResult.error(e.class)
      end

      outcome
    end

    # ==================================================================
    # 操作 3：改骰型（天狗 updateDice，db_wrapper.js:73）
    # ==================================================================
    #
    # 天狗 `_updateTableNode(…, "dice", diceName, diceString)` 是一次
    # setData({table:{dice:{key:value}}}) 的**深合并**——只动那一个键。
    # 本层：事务内读 spec → 改那一个键 → 整体写回（合并规则显式化，§4.2）。
    def update_dice(chat_id:, name:, dice_name:, dice_string:, scope: SCOPE_PRIVATE)
      key = normalize_key(dice_name)
      value = dice_string.to_s
      return MutationResult.invalid_argument if key.nil? || value.empty?

      edit_row(chat_id: chat_id, name: name, scope: scope) do |table, draft|
        spec = spec_draft(table)
        dice = spec["dice"].dup
        dice[key] = value
        spec["dice"] = dice
        draft[:spec] = spec
        [MutationResult::OK, true]
      end
    end

    # ==================================================================
    # 操作 4：改条目（天狗 updateData，db_wrapper.js:77）
    # ==================================================================
    #
    # 出目键按天狗 `String(array[2])` 存成**字符串数字**（Firestore 的 map key
    # 本来就是字符串；本项目 JSON object 的键同样是字符串）。
    def update_data(chat_id:, name:, data_index:, data_string:, scope: SCOPE_PRIVATE)
      key = normalize_data_index(data_index)
      return MutationResult.invalid_argument if key.nil?

      text = data_string.to_s
      edit_row(chat_id: chat_id, name: name, scope: scope) do |table, draft|
        spec = spec_draft(table)
        data = spec["data"].dup
        data[key] = text
        spec["data"] = data
        draft[:spec] = spec
        [MutationResult::OK, true]
      end
    end

    # ==================================================================
    # 操作 5：改范围钳（天狗 updateAddition，db_wrapper.js:81）
    # ==================================================================
    #
    # 天狗签名 `updateAddition(channelID, tableName, isUseFlag,
    #                            max = MAX_SAFE_INTEGER, min = MIN_SAFE_INTEGER)`
    # ——不给上下限就是「回到不设限」。本层同款：max/min 默认 nil = 不设限。
    #
    # ⚠️ 天狗**不做** max>=min 校验（datatable 传来的都是 data 键的 min/max，
    #   天然有序）。本层加这条校验是实现级决策：handler 可能算错，而一个
    #   倒挂的钳制会让所有出目都判失败却毫无提示——宁可建表时就拒。
    def set_datarange(chat_id:, name:, is_use: false, max: nil, min: nil,
                      scope: SCOPE_PRIVATE)
      range = DataRange.new(is_use: is_use, max: max, min: min)
      return MutationResult.invalid_argument if range.invalid_bounds?

      edit_row(chat_id: chat_id, name: name, scope: scope) do |_table, draft|
        draft[:datarange] = range
        [MutationResult::OK, true]
      end
    end

    # ==================================================================
    # 操作 6：改权限（天狗 updatePermission，db_wrapper.js:105）
    # ==================================================================
    #
    # 天狗是**整体替换**数组（addPermission / deletePermission 都是先在本地把
    # 数组 push/splice 好，再 updatePermission 写回整份）。本层同款，
    # 不内置「不许删前三位」那条限制（那是命令层的事，ct_command/deletePermission.js）。
    #
    # ⚠️ **位置语义**：第 0~2 位是 admin 位（CustomTable#admins / #admin?）。
    #   传进来的顺序即层级，故 handler 在拼数组时必须保持天狗的顺序。
    def set_permissions(chat_id:, name:, permissions:, scope: SCOPE_PRIVATE)
      perms = normalize_user_ids(permissions)
      return MutationResult.invalid_argument if perms.nil? || perms.empty?

      edit_row(chat_id: chat_id, name: name, scope: scope) do |_table, draft|
        draft[:permissions] = perms
        [MutationResult::OK, true]
      end
    end

    # ==================================================================
    # 操作 7：发布到公共（天狗 publishTable，db_wrapper.js:65 + ct_command）
    # ==================================================================
    #
    # 天狗（ct_command/publishTable.js:8-27 run 主体）的四步：
    #   ① 私有表查不到 → 「テーブルがありません。」
    #   ② 公共同名 → 「同名のテーブルがpublicに公開されています。…」
    #   ③ 数据完整性校验（**命令层**，本 db 层不做——见文件头部）
    #   ④ 写公共 + 删私有（**是「移」不是「复制一份留着」**）
    # 本层把 ①②④ 合进一个 :immediate 事务：任何一步失败，私有表原样不动，
    # 公共侧也不会留下半份。
    #
    # 复制的是**整行**（骰型/条目/权限/范围钳/author_id 全部带过去），
    # 唯二改动：scope → public、chat_id → 0（占位，UNIQUE 得以生效）。
    #
    # @return [MutationResult] table = 发布后的公共行
    def publish_table(chat_id:, name:)
      chat = normalize_chat_id(chat_id)
      key = normalize_name(name)
      return MutationResult.invalid_argument if chat.nil? || key.nil?

      published = nil
      outcome = nil
      begin
        conn.transaction(:immediate) do
          row = fetch_row(SCOPE_PRIVATE, chat, key)
          if row.nil?
            outcome = MutationResult.not_found
          elsif fetch_row(SCOPE_PUBLIC, PUBLIC_CHAT_ID, key)
            outcome = MutationResult.already_exists
          else
            begin
              conn.execute(
                "INSERT INTO #{TABLE} (scope, chat_id, name, spec, permissions, " \
                "datarange, author_id, updated_at) " \
                "SELECT ?, ?, name, spec, permissions, datarange, author_id, " \
                "datetime('now') FROM #{TABLE} " \
                "WHERE scope = ? AND chat_id = ? AND name = ?",
                [SCOPE_PUBLIC, PUBLIC_CHAT_ID, SCOPE_PRIVATE, chat, key]
              )
              conn.execute(
                "DELETE FROM #{TABLE} WHERE scope = ? AND chat_id = ? AND name = ?",
                [SCOPE_PRIVATE, chat, key]
              )
              published = fetch_row_to_table(SCOPE_PUBLIC, PUBLIC_CHAT_ID, key)
              outcome = MutationResult.ok(published)
            rescue SQLite3::ConstraintException
              # UNIQUE 兜底（并发或异常路径）：公共重名 → 整笔回滚，私有表不动
              outcome = MutationResult.already_exists
            end
          end
        end
      rescue SQLite3::Exception => e
        warn_line("[custom_tables] 发布失败：#{e.class}")
        return MutationResult.error(e.class)
      end

      outcome
    end

    # ==================================================================
    # 操作 8：删骰型（天狗 deleteDice，db_wrapper.js:114）
    # ==================================================================
    #
    # 天狗 `_deleteTableNode` 用 `FieldValue.delete()` 哨兵删 map 里的一个键。
    # 本层 = JSON 键删除（§4.2「JSON 键删除」）。删不存在的快捷名：Firestore
    # 的哨兵删一个不存在的键不报错 → 本层回 OK、changed? = false（幂等）。
    def delete_dice(chat_id:, name:, dice_name:, scope: SCOPE_PRIVATE)
      key = normalize_key(dice_name)
      return MutationResult.invalid_argument if key.nil?

      edit_row(chat_id: chat_id, name: name, scope: scope) do |table, draft|
        if table.dice.key?(key)
          spec = spec_draft(table)
          dice = spec["dice"].dup
          dice.delete(key)
          spec["dice"] = dice
          draft[:spec] = spec
          [MutationResult::OK, true]
        else
          [MutationResult::OK, false]
        end
      end
    end

    # ==================================================================
    # 操作 9：删条目（天狗 deleteData，db_wrapper.js:117）
    # ==================================================================
    #
    # ⚠️ 天狗语义**分两支**（ct_command/deleteData.js:17-18）：
    #   ① 出目本来就没有 → `{result: true, message:「入力した番号のデータは存在しません。」}`
    #      ——**成功**，不是错误；
    #   ② 出目存在 → FieldValue.delete 哨兵删掉。
    # 本层①回 DATA_MISSING（success? 为真，handler 据此选文案），②回 OK。
    def delete_data(chat_id:, name:, data_index:, scope: SCOPE_PRIVATE)
      key = normalize_data_index(data_index)
      return MutationResult.invalid_argument if key.nil?

      edit_row(chat_id: chat_id, name: name, scope: scope) do |table, draft|
        if table.data.key?(key)
          spec = spec_draft(table)
          data = spec["data"].dup
          data.delete(key)
          spec["data"] = data
          draft[:spec] = spec
          [MutationResult::OK, true]
        else
          [MutationResult::DATA_MISSING, false]
        end
      end
    end

    # ==================================================================
    # 操作 10：删表（天狗 deleteTable，db_wrapper.js:132）
    # ==================================================================
    #
    # 删不存在的表 = 成功（Firestore 删不存在的 field 也返回 true），故回 OK
    # 且 changed? = false。
    #
    # @param scope [Symbol, String] :public 删公共行（chat_id 恒为 0）
    def delete_table(chat_id:, name:, scope: SCOPE_PRIVATE)
      key = normalize_name(name)
      return MutationResult.invalid_argument if key.nil?

      sc = normalize_scope(scope)
      return MutationResult.invalid_argument if sc.nil?

      chat = sc == SCOPE_PUBLIC ? PUBLIC_CHAT_ID : normalize_chat_id(chat_id)
      return MutationResult.invalid_argument if chat.nil?

      begin
        conn.execute(
          "DELETE FROM #{TABLE} WHERE scope = ? AND chat_id = ? AND name = ?",
          [sc, chat, key]
        )
      rescue SQLite3::Exception => e
        # 存储层故障回 error 态（与 edit 系同一契约，kimi T3.3 评审提案 #4）
        warn_line("[custom_tables] 删表失败：#{e.class}")
        return MutationResult.error(e.class)
      end
      changed = conn.changes.positive?

      MutationResult.ok(nil, changed: changed)
    end

    # ==================================================================
    # 操作 11：按频道查全部（天狗 getAllTable，db_wrapper.js:21）
    # ==================================================================
    #
    # 天狗并发取 public（固定 doc '99'）与 private（channel doc）两份再合并，
    # 返回 `{public: …, private: …}`。本层同形状：两个 scope 分别查、分别成数组
    # （**SQLite 里「一篇文档一张 map」天然就分成两段**，不需要像 Firestore 那样
    # 先读出一大坨再拆）。公共侧**不带 chat_id 过滤**（它是全局的）。
    #
    # @return [Hash{String=>Array<CustomTable>}] 键 "public" / "private"
    def all_for_chat(chat_id:)
      chat = normalize_chat_id(chat_id)
      return { "public" => [], "private" => [] } if chat.nil?

      {
        "public" => list(scope: SCOPE_PUBLIC, chat_id: PUBLIC_CHAT_ID),
        "private" => list(scope: SCOPE_PRIVATE, chat_id: chat)
      }
    end

    # 某一 scope 下的全部表（按名称升序；all_for_chat 的实现单元，也供诊断用）
    #
    # @return [Array<CustomTable>]
    def list(scope: SCOPE_PRIVATE, chat_id: nil)
      sc = normalize_scope(scope)
      return [] if sc.nil?

      chat = sc == SCOPE_PUBLIC ? PUBLIC_CHAT_ID : normalize_chat_id(chat_id)
      return [] if chat.nil?

      conn.execute_query(
        "SELECT #{COLUMNS} FROM #{TABLE} WHERE scope = ? AND chat_id = ? " \
        "ORDER BY name ASC",
        [sc, chat]
      ).map { |row| to_table(row_to_hash(row)) }
    end

    # ==================================================================
    # 操作 12：查单表（天狗 getUserTable + SearchTableDiceroll 的查找顺序）
    # ==================================================================
    #
    # 直查**单一** scope 的一行（命令层「看这张表」用；不套查找顺序——
    # 天狗的 getUserTable 也是指定 channelID / public 的直查）。
    #
    # @return [CustomTable, nil]
    def fetch(chat_id:, name:, scope: SCOPE_PRIVATE)
      key = normalize_name(name)
      return nil if key.nil?

      sc = normalize_scope(scope)
      return nil if sc.nil?

      chat = sc == SCOPE_PUBLIC ? PUBLIC_CHAT_ID : normalize_chat_id(chat_id)
      return nil if chat.nil?

      fetch_row_to_table(sc, chat, key)
    end

    # 按 **default → private → public** 顺序查（SearchTableDiceroll.js:13-24）
    #
    #     async getTableData(tableName) {
    #         //default -> private -> publicで検索。
    #         let checkDataTable = this.datatable.dataTable[tableName.toLowerCase()];
    #         if (!checkDataTable)
    #             checkDataTable = await DB.db.getUserTable(this.channelID, tableName);
    #         if (!checkDataTable)
    #             checkDataTable = await DB.db.getUserTable(null, tableName);
    #         return checkDataTable;
    #     }
    #
    # 逐条对应：① 内置（注入源，键 downcase）② 频道私有 ③ 公共。
    #
    # @param name [String] 表名
    # @param chat_id [Integer, nil] nil = 不查私有级（天狗传 null 时同理）
    # @param builtin [Hash, #call, nil] 内置表来源：**调用方注入**（引擎侧
    #   nd_datatable 的等价物）。Hash → 按 downcase 键取；可调用对象 → 传入
    #   downcase 后的表名。nil = 本环境没有内置表（DB 层零引擎依赖）。
    # @return [Resolution] found? 为假时 source 恒为最末一级（:public），
    #   table 与 builtin 皆 nil——handler 用 found? 分支即可。
    def resolve_table(name:, chat_id: nil, builtin: nil)
      key = normalize_name(name)
      return Resolution.new(source: :public) if key.nil?

      # ① default（代码内置）
      hit = lookup_builtin(builtin, key)
      return Resolution.new(source: :builtin, builtin: hit) unless hit.nil?

      # ② 频道私有
      chat = normalize_chat_id(chat_id)
      unless chat.nil?
        row = fetch_row_to_table(SCOPE_PRIVATE, chat, key)
        return Resolution.new(source: :private, table: row) unless row.nil?
      end

      # ③ 公共
      Resolution.new(source: :public,
                     table: fetch_row_to_table(SCOPE_PUBLIC, PUBLIC_CHAT_ID, key))
    end

    # 该 chat（+scope）下有几行（诊断/测试用）
    def count_for(chat_id:, scope: SCOPE_PRIVATE)
      sc = normalize_scope(scope)
      return 0 if sc.nil?

      chat = sc == SCOPE_PUBLIC ? PUBLIC_CHAT_ID : normalize_chat_id(chat_id)
      return 0 if chat.nil?

      conn.get_first_value(
        "SELECT count(*) FROM #{TABLE} WHERE scope = ? AND chat_id = ?",
        [sc, chat]
      ).to_i
    end

    private

    attr_reader :conn

    # ------------------------------------------------------------------
    # 事务内的「读行 → 改 → 写回」通用骨架
    # ------------------------------------------------------------------
    #
    # spec / permissions / datarange 三列的改动都走这里：读改写必须在同一个
    # :immediate 事务里（防「读→改→写」竞态，同 db/bank.rb 纪律）。
    #
    # 块收到 [CustomTable, draft]，draft 里放要改的列（未放的列不动），
    # 返回 [状态, 是否真的变了]。状态非 OK 时**不写库**（事务空转提交）。
    def edit_row(chat_id:, name:, scope:)
      sc = normalize_scope(scope)
      key = normalize_name(name)
      return MutationResult.invalid_argument if key.nil? || sc.nil?

      # 公共行的 chat_id 是 0 占位（不来自入参）——scope 覆盖必须在 chat_id
      # nil 判**之前**（与 rename_table/delete_table 同款）：否则 public +
      # chat_id 0/nil 会被误判 invalid_argument，6 个 edit 系操作在 flag t
      # 路径全灭（kimi T3.3 评审提案 #1：审计修了 rename_table，这里残留孪生）
      chat = sc == SCOPE_PUBLIC ? PUBLIC_CHAT_ID : normalize_chat_id(chat_id)
      return MutationResult.invalid_argument if chat.nil?

      outcome = nil
      begin
        conn.transaction(:immediate) do
          row = fetch_row(sc, chat, key)
          if row.nil?
            outcome = MutationResult.not_found
          else
            table = to_table(row)
            draft = {}
            status, changed = yield(table, draft)

            if status != MutationResult::OK
              outcome = MutationResult.new(status, table: table, changed: false)
            else
              # changed=false（幂等未命中）时不写库——否则「没动数据」却拨动
              # updated_at，自相矛盾（kimi T3.3 评审提案 #2，已实证）
              write_columns(sc, chat, key, table, draft) if changed
              outcome = MutationResult.ok(fetch_row_to_table(sc, chat, key),
                                          changed: changed)
            end
          end
        end
      rescue SQLite3::Exception => e
        warn_line("[custom_tables] 写入失败：#{e.class}")
        return MutationResult.error(e.class)
      end

      outcome
    end

    def write_columns(scope_name, chat, key, table, draft)
      spec = draft.key?(:spec) ? draft[:spec] : spec_draft(table)
      perms = draft.key?(:permissions) ? draft[:permissions] : table.permissions
      range = draft.key?(:datarange) ? draft[:datarange] : table.datarange

      begin
        conn.execute(
          "UPDATE #{TABLE} SET spec = ?, permissions = ?, datarange = ?, " \
          "updated_at = datetime('now') " \
          "WHERE scope = ? AND chat_id = ? AND name = ?",
          [JSON.generate(spec), JSON.generate(perms), JSON.generate(range.to_h),
           scope_name, chat, key]
        )
      rescue SQLite3::ConstraintException
        # spec/permissions/datarange 三列都不在 UNIQUE 键里，走到这里说明
        # 有别的约束（理论上不该发生）；原样上抛给外层 rescue 成 :error。
        raise
      end
    end

    def fetch_row(scope_name, chat, key)
      return nil if scope_name.nil? || chat.nil? || key.nil?

      conn.get_first_hash(
        "SELECT #{COLUMNS} FROM #{TABLE} WHERE scope = ? AND chat_id = ? AND name = ?",
        [scope_name, chat, key]
      )
    end

    def fetch_row_to_table(scope_name, chat, key)
      row = fetch_row(scope_name, chat, key)
      row.nil? ? nil : to_table(row)
    end

    # execute_query（results_as_hash 关闭态）返的是**数组的数组**，
    # 按 COLUMNS 的列序映射回 Hash 交给 to_table。
    def row_to_hash(row)
      return row if row.is_a?(Hash)

      COLUMNS.split(", ").each_with_index.to_h { |col, idx| [col, row[idx]] }
    end

    def to_table(row)
      spec = parse_object(row["spec"]) # **只解析一次**：解析两次会让坏 JSON 的
                                        # warn 重复两条（测试已钉住这个计数）
      CustomTable.new(
        id: row["id"],
        scope: row["scope"],
        chat_id: row["chat_id"],
        name: row["name"],
        dice: spec[SPEC_DICE],
        data: spec[SPEC_DATA],
        permissions: parse_ids(row["permissions"]),
        datarange: parse_datarange(row["datarange"]),
        author_id: row["author_id"],
        created_at: row["created_at"],
        updated_at: row["updated_at"]
      )
    end

    # ------------------------------------------------------------------
    # 归一（与 db/bank.rb 的 id_of / normalize_chat_id 同款纪律）
    # ------------------------------------------------------------------

    # 私有表的 chat_id：nil / 空串 / 0 一律拒绝（Ruby 里 0 为真，
    # 不拦会写进 chat_id=0 黑洞，而那是**公共表的占位**——会撞 UNIQUE 语义）。
    def normalize_chat_id(chat_id)
      return nil if chat_id.nil?
      return nil if chat_id.is_a?(String) && chat_id.strip.empty?

      id = chat_id.to_i
      return nil if id.zero?
      # int64 界守卫（kimi T3.3 评审提案 #6）：SQLite INTEGER 列是动态类型，
      # 超界值会被静默存成 REAL、精度损失（含 INT64_MIN 闭区间，db/bank.rb 同款）
      return nil unless id.between?(INT64_MIN, INT64_MAX)

      id
    end

    def normalize_name(name)
      return nil if name.nil?

      text = name.to_s
      text.strip.empty? ? nil : text
    end

    def normalize_scope(scope)
      return SCOPE_PRIVATE if scope.nil?

      value = scope.to_s.downcase
      SCOPES.include?(value) ? value : nil
    end

    # 快捷名/条目键都不能是空串（否则会造出 `` : value 这种打不出来的键）
    def normalize_key(key)
      return nil if key.nil?

      text = key.to_s
      text.empty? ? nil : text
    end

    # 出目键：整数 3 与字符串 "3" 等价（天狗 `String(array[2])`）
    def normalize_data_index(index)
      return nil if index.nil?
      return index.to_s if index.is_a?(Integer)

      text = index.to_s
      text.empty? ? nil : text
    end

    # 权限数组：全转整数、丢掉空的与非数字的；全被丢掉时返回 nil
    def normalize_user_ids(values)
      return nil if values.nil?

      list = values.is_a?(Array) ? values : [values]
      ids = list.filter_map do |v|
        next nil if v.nil?
        next nil if v.is_a?(String) && v.strip.empty?

        int = v.is_a?(Integer) ? v : Integer(v.to_s, exception: false)
        next nil if int.nil? || int.zero?
        next nil unless int.between?(INT64_MIN, INT64_MAX) # int64 界守卫（同 normalize_chat_id）

        int
      end
      ids.empty? ? nil : ids
    end

    def coerce_datarange(value)
      case value
      when DataRange then value
      when nil then DataRange.unbounded
      when Hash then DataRange.new(is_use: value[DataRange::KEY_IS_USE],
                                   max: value[DataRange::KEY_MAX],
                                   min: value[DataRange::KEY_MIN])
      else DataRange.unbounded
      end
    end

    # 内置表源：Hash（downcase 键）或可调用对象。两种都拿不到就 nil。
    #
    # 天狗内层用的是 `datatable.dataTable[tableName.toLowerCase()]`——键是
    # downcase 的表名，故这里对**内置源**一律 downcase 再取。
    # callable 内置源（引擎桥）抛异常不裸传给 handler：按未命中处理 + warn
    # （kimi T3.3 评审提案 #11）。
    def lookup_builtin(source, name)
      key = name.downcase
      case source
      when nil then nil
      when Hash then source[key]
      else
        source.respond_to?(:call) ? source.call(key) : nil
      end
    rescue StandardError => e
      warn_line("[custom_tables] 内置表查找失败，按未命中处理：#{e.class}")
      nil
    end

    SPEC_DICE = "dice"
    SPEC_DATA = "data"

    def stringify_map(source)
      return DEFAULT_DICE.dup unless source.is_a?(Hash)

      source.each_with_object({}) { |(k, v), acc| acc[k.to_s] = v.to_s }
    end

    # spec 的可写副本（读出来的那份已 freeze，必须 dup 出可改副本）
    def spec_draft(table)
      { SPEC_DICE => table.dice.dup, SPEC_DATA => table.data.dup }
    end

    # ------------------------------------------------------------------
    # JSON 列解析：**容错**（坏 JSON 不当致命，参照 db/bank.rb parse_array）
    # ------------------------------------------------------------------

    # spec 解析：不是 Hash 就退化成 {"dice"=>{}, "data"=>{}}
    #（空表比炸掉整张表有用——handler 仍能列出「这张表没有骰型」）
    def parse_object(raw)
      text = raw.to_s
      return { SPEC_DICE => {}, SPEC_DATA => {} } if text.empty?

      parsed = JSON.parse(text)
      return { SPEC_DICE => {}, SPEC_DATA => {} } unless parsed.is_a?(Hash)

      {
        SPEC_DICE => parsed[SPEC_DICE].is_a?(Hash) ? parsed[SPEC_DICE] : {},
        SPEC_DATA => parsed[SPEC_DATA].is_a?(Hash) ? parsed[SPEC_DATA] : {}
      }
    rescue JSON::ParserError
      warn_line("[custom_tables] spec 列不是合法 JSON，按空表处理")
      { SPEC_DICE => {}, SPEC_DATA => {} }
    end

    def parse_datarange(raw)
      text = raw.to_s
      return DataRange.unbounded if text.empty?

      parsed = JSON.parse(text)
      unless parsed.is_a?(Hash)
        warn_line("[custom_tables] datarange 列不是 JSON 对象，按不设限处理")
        return DataRange.unbounded
      end

      DataRange.new(is_use: parsed[DataRange::KEY_IS_USE],
                    max: parsed[DataRange::KEY_MAX],
                    min: parsed[DataRange::KEY_MIN])
    rescue JSON::ParserError
      warn_line("[custom_tables] datarange 列不是合法 JSON，按不设限处理")
      DataRange.unbounded
    end

    def parse_ids(raw)
      text = raw.to_s
      return [] if text.empty?

      parsed = JSON.parse(text)
      return [] unless parsed.is_a?(Array)

      normalize_user_ids(parsed) || []
    rescue JSON::ParserError
      warn_line("[custom_tables] permissions 列不是合法 JSON，按空数组处理")
      []
    end

    def warn_line(message)
      @logger.warn(message)
    rescue StandardError
      nil # logger 坏了也不能让读写失败（参照 db/bank.rb）
    end
  end
end
