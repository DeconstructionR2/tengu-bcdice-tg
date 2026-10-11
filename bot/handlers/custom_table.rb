# frozen_string_literal: true

require "logger"

# ============================================================================
# bot/handlers/custom_table.rb — 天狗 CT 自定义表 /ct（T3.4，计划 §5 / §6 / §8 T3.4）
#
# 语义母本（**只读**，逐条对照；命令层判定全部在此落地）：
#   references/src/TenguDiceBot/TenguDiceBot/ct_command/*.js（15 文件）
#   references/src/TenguDiceBot/TenguDiceBot/classes/SearchTableDiceroll.js
#     （表名查找顺序 + `+x` 可変数解析）
#   references/src/TenguDiceBot/TenguDiceBot/tengu_dice/NJDiscordReply.js
#     （掷表与 datarange 钳制：addTableOutput:75-105）
#   references/src/TenguDiceBot/TenguDiceBot/DB/db_wrapper.js
#     （存储语义已在 T3.3 落 db/custom_tables.rb；本文件只做命令层）
#
# ── /ct 子命令 → 天狗命令映射（全部 ASCII；详见 docs/t3.4-report.md §2）────
#
#   | /ct 子命令                              | 天狗 ct_command      | db 操作        |
#   |-----------------------------------------|----------------------|----------------|
#   | create <名>                              | createTable          | create_table   |
#   | rename <旧> <新> [t]                     | updateTableName      | rename_table   |
#   | dice set <表> <快捷名> <骰式> [t]        | updateDice           | update_dice    |
#   | dice del <表> <快捷名> [t]               | deleteDice           | delete_dice    |
#   | data set <表> <出目> [t] <文本>          | updateData           | update_data    |
#   | data del <表> <出目> [t]                 | deleteData           | delete_data    |
#   | range <表> <最小> <最大> [t] / <表> off  | （母本无命令层入口） | set_datarange  |
#   | perm add <表> <用户ID> [t]               | addPermission        | set_permissions|
#   | perm del <表> <用户ID> [t]               | deletePermission     | set_permissions|
#   | publish <表>                             | publishTable         | publish_table  |
#   | delete <表> [t]                          | deleteTable          | delete_table   |
#   | show <表> [t]                            | checkTableData       | fetch          |
#   | list                                     | checkTableList       | all_for_chat   |
#   | roll <表> [快捷名] [補正]                | SearchTableDiceroll  | resolve_table  |
#   | help [子命令]                            | help                 | —              |
#
#   `[t]` = 天狗 flag（`data.flag ? null : ids.channelId`）——t/T=公共表、f/F=本群表，
#   位置与解析规则见下「flag 解析」。天狗的 `,` 分隔参数在本项目改为**空白分隔**，
#   故 flag 一律是**独立 token**（不做内容猜测），位置规则：
#     - 定长命令：最后一个 token；
#     - `data set`（尾部是自由文本）：出目号之后**紧邻**的 token 若恰为 t/T/f/F，
#       即视为 flag（自由文本随之写在其后；flag 之后没写文本则报错）。
#
# ── 命令层判定（t3.3-report §6.1 待办清单逐条落点）────────────────────────
#
#   ① 表名合法性：母本 checkInvalidChar 禁「半角英数字 + 特殊符号」并要求全角 4 字以上
#      ——那是为「日文表名直打」（表名本身是掷骰触发词）设计的，本项目表名只作为
#      `/ct` 参数出现（无此歧义），且内置表名是 ASCII（SBX/KRS…），**禁 ASCII 会让
#      「内置表撞名」检查变成死代码**（验收钉要求该检查可触发）。故适配为：
#      非空、无空白/控制字符、长度 1..32（CJK/ASCII 均可）。见报告 §4 决策 1。
#   ② 骰式合法性：母本 updateDice.js:55 正则**逐字照搬**
#      （`^(?:\d+|\d+[dD]\d+)(?:[+-](?:\d+|\d+[dD]\d+))*(?:\+x)?$`）。
#   ③ diceName/diceString **小写归一**（母本 adjust 的 toLowerCase()；校验发生在
#      小写化**之前**——`1D6+X` 因正则里的 `\+x` 只认小写而被拒，与母本一致）。
#   ④ dataIndex 必须 `^\d+$`（母本 updateData.js:44 / deleteData.js:48）。
#   ⑤ 权限：逐操作对照母本（见「权限模型」），并叠加计划 §5 的 Telegram 化
#      「群管理员可改」（Admin 助手 getChatMember，fail-closed）。
#   ⑥ publish 前 dataVerification（母本 publishTable.js:45-91）：
#      出目区间 vs 登记数据数；datarange.isUse 时跳过（母本 :18），
#      且骰式含 `+x` 时跳过（母本 help 原文：「判定できないため…スキップ」）。
#   ⑦ 建表/发布前**查内置表撞名**（createTable.js:10-11、publishTable.js:13-14）：
#      两路都拦——不拦则「建了等于没建」（掷表查找内置优先，用户的表永远不可达）。
#      母本**改名不查内置表**（updateTableName.js 无 datatable 引用）→ 本项目同款，
#      即改名可以改出「被内置阴影」的名字（登记为已知面，见报告 §7 风险）。
#   ⑧ 建表撞名两路：先内置、再本群同名（createTable.js:10-13）。
#
# ── 权限模型（母本逐操作判据 + Telegram 化叠加）──────────────────────────
#
#   母本各命令的权限判据（**位置即层级**，permission 前三位是 admin 位）：
#     · 全体 permission 列表：updateDice / updateData / deleteDice / deleteData
#     · 前三位（admin 位）：updateTableName / addPermission / deletePermission /
#       deleteTable（私有分支）
#     · 仅第 0 位：deleteTable 的 **public 分支**（deleteTable.js:13-16
#       「publicの削除はくりーむのみ」，只认 permission[0]）
#     · publishTable 母本**代码无权限检查**（其 help 却承诺「bot管理者/サーバー
#       管理者/テーブル作成者」）→ 本项目按计划 §5「改表权限=建表者或群管理员」
#       落到**前三位**规则（help 承诺的正是这三个 admin 位），登记为补检查。
#   Telegram 化叠加：以上任一不通过时，**本群管理员**仍可通过（Admin#admin?,
#   getChatMember, fail-closed；私聊由 Admin 内部豁免——私聊是用户自己的对话）。
#   ⚠️ 群管理员旁路**只对本群私有表**生效：公共行（scope=public）没有「本群」，
#      若让任意群管理员改公共表，等于把全服公共表的编辑权发给每个群的管理员
#      （实施级决策，见报告 §4 决策 4；母本对公共行同样只认表自身的权限数组）。
#
#   「不许删权限前三位」是命令层规则（deletePermission.js:17-20 管理範囲チェック）
#   → perm del 拦截；db 层 set_permissions 是整体替换，不内置该限制（T3.3 纪律）。
#
# ── 范围钳（datarange）的两层 -------------------------------------------------
#
#   存放层（T3.3）：{isUse, max, min}，null = 不设限。
#   命令层（本文件，逐条对照母本）：
#     A. **自动维护**（updateDice.js:23-45 / deleteDice.js:17-26 /
#        updateData.js:22-34 / deleteData.js:20-33）：
#        - dice set 的骰式含 `+x` 且 isUse=false → 按当前 data 键域
#          {min..max} 开钳（空 data → isUse=true、上下限 null）。
#        - dice set 的骰式不含 `+x` 且其余骰型也无 `+x` → 关钳（不设限）。
#        - dice del 后其余骰型无 `+x` 且 isUse 开着 → 关钳。
#        - data set 且 isUse 开着 → 按（data 键域 ∪ 新出目）重算上下限。
#        - data del 且删的是端点（max/min）且存在 `+x` 骰型 → 按剩余 data 重算
#          （isUse 原样）。
#        （母本的 MAX/MIN_SAFE_INTEGER 哨兵 → 本项目的 null，语义等价。）
#     B. **掷表时的钳制**（NJDiscordReply.addTableOutput:91-95，本项目在 roll）：
#        仅当本次掷的骰式**含 `+x`**（isTableAdditionValue）且钳制有界时生效：
#        出目 > max → 取 data[max]；< min → 取 data[min]；否则 data[出目]。
#        天狗是**静默**取端点；本项目按 T1.4 的「钳制发生时明示」约定加标注
#        （任务验收词「超钳报错」的落点=钳制必须显式报给用户，见报告 §4 决策 3）。
#     C. `range <表> <最小> <最大> [t]` / `range <表> off [t]`：母本**没有**这条
#        命令（钳制纯粹由 A 维护）；本项目为把 T3.3 的 set_datarange（12 操作之
#        「改范围钳」）暴露到聊天层而新增，登记为超越母本项。
#    ⚠️ 自动维护会覆盖手动 range（母本语义：范围由 data 键域推导）。
#
# ── 内置表桥（resolve_table 的 default 级）────────────────────────────────
#
#   查找顺序 default→private→public（SearchTableDiceroll.js:14 注释原文）由 db 层
#   resolve_table 实现，default 级（内置表）**由调用方注入**（db 层零引擎依赖）。
#   本文件做桥：BuiltinTables 读引擎侧 i18n（i18n/NinjaSlayer2Ex|NinjaSlayerEx 的
#   `table.*`，经 lib/engine_bootstrap.rb 注入 load_path 后才可取到），把每张内置表
#   折成与 CustomTable 同形的读取面（dice_string / data_entry / datarange）。
#   · 键 = ASCII 表名 downcase（母本 `dataTable[tableName.toLowerCase()]` 同款）；
#   · 骰型 = yml 的 `type`（= 默认骰型 a；母本多骰型 a~d 与 `+x` 補正走引擎命令，
#     不经本桥——`/ct roll` 对内置表只按 a 掷）；
#   · data 键偏移 = 默认骰型的最小出目（1d6→1、2d6→2），母本 data[出目] 原样。
#   内置表的撞名检查与掷表都走同一来源（同一 hash 的 key/call 两种形态都支持）。
#
# ── flag 解析 --------------------------------------------------------------
#
#   母本每个命令的 flag 都过 checkFlagString（`/^[tTfF]$/`，updateDice.js:58 等），
#   非 t/T/f/F 一律拒；t/T = 公共（`flag ? null : channelId`）、f/F = 本群。
#   本项目同款：flag token 必须恰为 t/T/f/F，其余 → 报错（不做「忽略」）。
#
# ── 输出与错误文案 ---------------------------------------------------------
#
#   天狗文案是日文、Discord Markdown。本项目按既有 handler 惯例出**纯文本中文**
#   （§13 第 7 项：第一版纯文本；Markdown 装饰不搬），逐条语义对照见报告 §2。
#   超长由 TelegramApi 的 Chunker 切段（handler 只给字符串——同 dice.rb 纪律；
#   母本 checkTableData 的 1900 字手工切段是 Discord 侧产物，不搬）。
#
# ── 依赖注入 ---------------------------------------------------------------
#   custom_tables : TenguDB::CustomTables（默认单连接）
#   admin         : #admin?(chat_id, user_id, chat_type:)（**群内未注入 = 群管理员
#                   路径一律拒绝**，fail-closed——同 settings handler 纪律；
#                   main.rb 注入与 /settings 共用的同一 Admin 实例）
#   builtin       : 内置表源 Hash（downcase 键）或 callable；默认 BuiltinTables.source
#   randomizer    : 掷表随机源。respond_to?(:roll_sum) 的对象直接用；respond_to?(:call)
#                   的当作**工厂**（每次掷骰取一个新的——BCDice::Randomizer 会累积
#                   rand_results，长驻进程共享一个会撞 UPPER_LIMIT_RANDS）。
#                   测试注入固定骰序（test/randomizer_mock.rb 同款思路）。
#
# 只读红线：本文件不修改 vendor/bundle/** 与 references/src/**。
# ============================================================================

require_relative "../admin"
require_relative "../../db/custom_tables"
require "bcdice/randomizer"

module TelegramBot
  module Handlers
    # ------------------------------------------------------------------------
    # BuiltinTables：引擎侧内置表 → resolve_table 的内置源（default 级）
    # ------------------------------------------------------------------------
    #
    # 数据源：i18n/NinjaSlayer2Ex/ja_jp.yml 与 i18n/NinjaSlayerEx/ja_jp.yml 的
    # `table.*`（引擎扩展表本体；T1.2 管线从 nd_datatable.js 机器生成）。
    # ⚠️ I18n 返回的是 **Symbol 键**的 Hash（BCDice Translate 的 symbolize 行为，
    #    T1.5 报告已实证）——取值必须两态兼容。
    # ⚠️ 读取时机：必须在 EngineBootstrap.bootstrap! 之后（load_path 注入 +
    #    backend reload! 完成），否则 namespace 缺失 → 空表 + warn（不抛）。
    #    桥自身懒构建并缓存；测试可 reset!。
    module BuiltinTables
      # 引擎侧命名空间（内置表所在；顺序即构建顺序，仅影响 hash 顺序）
      TABLE_NAMESPACES = %w[NinjaSlayer2Ex NinjaSlayerEx].freeze

      # 排除名单：T1.1 spike 的占位表（未注册命令、不可触发，不是真正可用的内置表；
      # 排除对撞名检查与查找顺序**同时**生效——两者读同一张 map，不会出现
      # 「查得到掷不出」/「拦住却查不到」的错位）。与 ledger 的 23 张已映射表对齐。
      EXCLUDED_KEYS = %w[SPIKE_DUMMY].freeze

      # 与 CustomTable 同形的读取面（roll/show 的公共路径只认这三个方法）
      class Table
        attr_reader :name, :dice, :data

        def initialize(name:, dice:, data:)
          @name = name.to_s
          @dice = dice.freeze
          @data = data.freeze
          freeze
        end

        # 母本 datatable 的 dice 表：快捷名 → 骰式
        def dice_string(dice_name)
          @dice[dice_name.to_s]
        end

        # 母本 datatable 的 data：出目（字符串数字）→ 结果文本
        def data_entry(index)
          @data[index.to_s]
        end

        # 内置表在本桥里**不携带钳制**（yml 无 datarange；多骰型/`+x` 走引擎命令）
        # —— unbounded 让 roll 的钳制分支自然跳过。
        def datarange
          TenguDB::DataRange.unbounded
        end
      end

      @logger = ::Logger.new($stderr)
      @map = nil

      class << self
        attr_accessor :logger

        # resolve_table 的内置源：callable（传入的键已由 db 层 downcase，这里再兜一次）
        def source
          ->(key) { map[key.to_s.downcase] }
        end

        # {downcased 表名 => BuiltinTables::Table}（懒构建 + 缓存）
        def map
          @map ||= build
        end

        # 全部内置表名（downcase）。撞名检查与 list/提示文案用。
        def names
          map.keys
        end

        # 测试用：丢弃缓存（换进程/换 I18n 状态后重新构建）
        def reset!
          @map = nil
        end

        def build
          acc = {}
          TABLE_NAMESPACES.each do |ns|
            fetch_namespace(ns).each do |key, spec|
              next if EXCLUDED_KEYS.include?(key.to_s.upcase)

              table = build_table(key, spec)
              next if table.nil?

              acc[key.to_s.downcase] = table
            end
          end
          acc
        end

        # 读一个命名空间的 table 子树；缺失/异常 → 空 + 结构性 warn
        # （raise: true 是仓库纪律：默认占位串会把「缺翻译」误判成正常）
        def fetch_namespace(namespace)
          data = I18n.t("#{namespace}.table", raise: true)
          data.is_a?(Hash) ? data : {}
        rescue StandardError => e
          warn_line("[builtin_tables] #{namespace}.table 读取失败（按空表处理）：#{e.class}")
          {}
        end

        def build_table(key, spec)
          return nil unless spec.is_a?(Hash)

          type = fetch(spec, :type).to_s.downcase
          items = fetch(spec, :items)
          return nil unless items.is_a?(Array) && !items.empty?
          # 骰型必须是「个数 d 面数」形态（本桥只认默认骰型；多骰型走引擎命令）
          return nil unless /\A\d+[dD]\d+\z/.match?(type)

          offset = min_sum(type)
          data = {}
          items.each_with_index { |text, i| data[(offset + i).to_s] = text.to_s }

          Table.new(name: fetch(spec, :name).to_s, dice: { "a" => type }, data: data)
        end

        # 表达式可达最小出目（= data 键的下限；如 2d6 → 2、1d6 → 1）
        def min_sum(expr)
          expr.gsub("-", "+-").split("+").sum do |term|
            term.include?("d") ? term.split("d", 2).first.to_i : term.to_i
          end
        end

        private

        # I18n 的 Hash 键可能是 Symbol（实测）也可能 String（防御）
        def fetch(hash, key)
          hash[key.to_s] || hash[key.to_sym]
        end

        def warn_line(message)
          @logger.warn(message)
        rescue StandardError
          nil
        end
      end
    end

    # ------------------------------------------------------------------------
    # CustomTableHandler
    # ------------------------------------------------------------------------
    class CustomTableHandler
      # 无参 /ct 与 /ct help 的用法表
      USAGE = <<~USAGE.chomp
        天狗自定义表（每个群一份，群内所有话题共享）
        /ct create <表名> — 建表（初始骰型 a : 1d6）
        /ct rename <旧名> <新名> [t] — 改名
        /ct dice set <表> <快捷名> <骰式> [t] — 设骰型，例：/ct dice set 暗殺表 b 2d6
        /ct dice del <表> <快捷名> [t] — 删骰型（快捷名 a 不可删）
        /ct data set <表> <出目> [t] <结果文本> — 录入出目结果，例：/ct data set 暗殺表 7 被暗杀
        /ct data del <表> <出目> [t] — 删出目结果
        /ct range <表> <最小> <最大> [t] — 开范围钳；/ct range <表> off [t] — 关（不设限）
        /ct perm add <表> <用户ID> [t] — 加编辑权限；/ct perm del <表> <用户ID> [t] — 删
        /ct publish <表> — 发布为公共表（全部群可用，原表移走）
        /ct delete <表> [t] — 删表
        /ct show <表> [t] — 查看表内容；/ct list — 本群表与公共表一览
        /ct roll <表> [快捷名] [補正] — 掷表，例：/ct roll 暗殺表 b 2
        [t] = 操作公共表（t/T）；不写或 f 表示本群表
      USAGE

      # /ct help <子命令> 的分题帮助（母本 help.js 的 topic 结构，文案改中文）
      TOPIC_HELP = {
        "create" => "/ct create <表名>\n建一张本群使用的表；初始只有骰型 a : 1d6。\n表名不能与内置表（SBX、KRS 等）同名。",
        "rename" => "/ct rename <旧名> <新名> [t]\n改表名；新名已被占用时会拒绝。",
        "dice" => "/ct dice set <表> <快捷名> <骰式> [t]\n/ct dice del <表> <快捷名> [t]\n骰式形如 1d6、2d6+3、3d6+x（+x = 掷表时可用補正微调）。快捷名 a 是默认骰型，不能删。",
        "data" => "/ct data set <表> <出目> [t] <结果文本>\n/ct data del <表> <出目> [t]\n出目号是半角数字；结果文本可含空格（写在出目号之后）。",
        "range" => "/ct range <表> <最小> <最大> [t]\n/ct range <表> off [t]\n开/关范围钳：掷带 +x 的骰型时出目超界会取端点数据。数据录入会自动维护范围。",
        "perm" => "/ct perm add <表> <用户ID> [t]\n/ct perm del <表> <用户ID> [t]\n权限前三位是管理位（改名/权限/删表只认它们），删前三位会被拒绝。用户ID 是 Telegram 数字 ID。",
        "publish" => "/ct publish <表>\n把表公开给全部群（原表移入公共）；发布前会校验出目数据是否齐全（有 +x 骰型或已开范围钳时跳过校验）。",
        "delete" => "/ct delete <表> [t]\n删表（本群表需管理位或本群管理员；公共表需第一位权限者）。",
        "show" => "/ct show <表> [t]\n显示表的骰型、范围钳与全部出目数据。",
        "list" => "/ct list\n显示本群表与公共表（内置表不在此列；内置表直接 /ct roll 或引擎命令掷）。",
        "roll" => "/ct roll <表> [快捷名] [補正]\n掷表：查找顺序 内置 → 本群 → 公共。带 +x 的骰型可用補正（如 2、-1）；出目超出范围钳时取端点数据并明示。",
        "help" => "/ct help [子命令]\n不带参数看总用法；带子命令名看分题帮助。"
      }.freeze

      # ---- 命令层判定常量（母本 updateDice.js:55 正则逐字照搬）-------------
      DICE_EXPR_PATTERN = /\A(?:\d+|\d+[dD]\d+)(?:[+-](?:\d+|\d+[dD]\d+))*(?:\+x)?\z/
      # 母本 command_utility.js:8-11 checkInvalidCharForDice（快捷名禁用字符集）
      DICE_NAME_FORBIDDEN = /[#\[\]()'`",.\\\/\s\u3000]/
      # 母本 updateData.js:44 / deleteData.js:48 / addPermission.js:34
      DIGITS_PATTERN = /\A\d+\z/
      # range 子命令的整数（可带正负号；上下界守卫在解析后做）
      DIGITS_WITH_SIGN_PATTERN = /\A[+-]?\d+\z/
      # flag token（母本 checkFlagString `/^[tTfF]$/`）
      FLAG_TOKENS = { "t" => :public, "f" => :private }.freeze

      # 表名规则（适配版，见文件头 ①与报告 §4 决策 1）
      NAME_MAX_LENGTH = 32

      # 初始/默认骰型名（母本 `temp[1] ? temp[1] : "a"`）
      DEFAULT_DICE_NAME = "a"
      # 默认骰型 a 不可删（母本 deleteDice.js:42 `/^[aA]$/`）
      PROTECTED_DICE_NAMES = %w[a A].freeze

      # ---- 文案 ------------------------------------------------------------
      UNKNOWN_SUBCOMMAND = "未知子命令。用 /ct help 查看用法。"
      BAD_ARGS = "参数个数不对。用 /ct help <子命令> 查看用法。"
      BAD_FLAG = "末尾标记只能是 t（公共表）或 f（本群表）。"
      BAD_TABLE_NAME = "表名无效：不能含空白或控制字符，长度 1..#{NAME_MAX_LENGTH} 个字符。"
      BAD_DICE_EXPR = "骰式格式错误。用 1d6、2d6+3、3d6+x 这类写法（支持 + - 与 +x 结尾）。"
      BAD_DICE_NAME = "快捷名不能含空白、#、[、]、(、)、'、`、\"、,、.、\\、/ 这些字符。"
      BAD_INDEX = "出目号必须是半角数字（如 3、12）。"
      BAD_USER_ID = "用户 ID 必须是半角数字。"
      BAD_RANGE = "范围钳参数无效：需要「最小 最大」两个整数（可带负号），或 off。"
      RANGE_INVERTED = "范围钳无效：最小不能大于最大。"
      NOT_ADMIN_FULL = "你没有操作表「%s」的权限（需要该表权限名单中的用户或本群管理员）。"
      NOT_ADMIN_BITS = "这项操作只允许表权限前三位（管理位）的用户或本群管理员执行。"
      NOT_ADMIN_FIRST = "公共表只能由该表的第一位权限用户删除。"
      CALLER_UNKNOWN = "识别不了发起人（缺 user_id），操作已拒绝。"
      STORAGE_ERROR = "存储层出错，操作未完成，请稍后再试。"
      BUILTIN_NAME_TAKEN = "不能用与内置表相同的名称「%s」。内置表直接掷即可（/ct roll %s 或引擎命令）。"
      DUPLICATE_PRIVATE = "本群已有同名表「%s」。"
      DUPLICATE_PUBLIC = "公共表里已有同名表「%s」，先改名再发布。"
      DUPLICATE_RENAME = "新表名「%s」已被占用。"
      DICE_MISSING = "表「%s」没有快捷名「%s」的骰型。"
      DATA_MISSING = "表「%s」本来就没有出目 %s 的数据（无需删除）。"
      EMPTY_TEXT = "结果文本为空。写在出目号后面（可用 /ct data set 表 出目 [t] 文本）。"
      RANGE_SYNC_FAILED = "骰型/数据已更新，但范围钳同步失败（存储层出错），请再改动一次以修正。"

      # 注入项（custom_tables / randomizer 是懒加载方法，见下）
      attr_reader :admin, :builtin

      # @param custom_tables [TenguDB::CustomTables, nil] nil = 用单连接新建
      # @param admin [#admin?, nil] 群管理员判定（**未注入 = 群内一律拒**，fail-closed）
      # @param builtin [Hash, #call, nil] 内置表源；nil → BuiltinTables.source
      # @param randomizer [#roll_sum, #call, nil] 掷表随机源（对象或工厂）
      # @param logger [#warn, nil] 日志器（只记结构性信息，绝不记用户正文/表名）
      def initialize(custom_tables: nil, admin: nil, builtin: nil,
                     randomizer: nil, logger: ::Logger.new($stderr))
        @custom_tables = custom_tables
        @admin = admin
        @builtin = builtin
        @randomizer = randomizer || -> { BCDice::Randomizer.new }
        @logger = logger
      end

      # 懒加载（注入了假身/内存库的用例完全不碰真实单连接）
      def custom_tables
        @custom_tables ||= TenguDB::CustomTables.new
      end

      def builtin_source
        @builtin || BuiltinTables.source
      end

      # 注册表（bot/main.rb 调一次即可）
      def self.registry(handler = new)
        { ct: handler }
      end

      # ------------------------------------------------------------------
      # 入口：按 kind/命令名分发（T3.1 教训：单键也要显式判 kind）
      # ------------------------------------------------------------------
      def call(context)
        return nil unless context[:name].to_s == "ct"

        kind = context[:kind]
        return nil unless kind.nil? || kind == :slash # 只接 slash 主轨

        chat_id = context[:chat_id].to_i
        return nil if chat_id.zero? # 拿不到 chat → 无处可落（不该发生）

        dispatch(context, context[:args].to_s.strip)
      rescue StandardError => e
        # handler 抛异常会被 router 静默吞掉（用户只看到没反应），故兜底回话。
        warn_line("[custom_table] 未捕获异常：#{e.class}")
        STORAGE_ERROR
      end

      def dispatch(context, args)
        return USAGE if args.empty?

        verb, rest = args.split(/\s+/, 2)
        verb = verb.to_s.downcase
        rest = rest.to_s

        case verb
        when "create" then sub_create(context, rest)
        when "rename" then sub_rename(context, rest)
        when "dice" then sub_dice(context, rest)
        when "data" then sub_data(context, rest)
        when "range" then sub_range(context, rest)
        when "perm" then sub_perm(context, rest)
        when "publish" then sub_publish(context, rest)
        when "delete" then sub_delete(context, rest)
        when "show" then sub_show(context, rest)
        when "list" then sub_list(context, rest)
        when "roll" then sub_roll(context, rest)
        when "help" then sub_help(rest)
        else UNKNOWN_SUBCOMMAND
        end
      end

      private

      # ==================================================================
      # create（母本 ct_command/createTable.js）
      # ==================================================================
      def sub_create(context, rest)
        tokens = tokens(rest)
        return BAD_ARGS unless tokens.size == 1
        return CALLER_UNKNOWN unless caller_id(context)

        name = tokens[0]
        return BAD_TABLE_NAME unless valid_table_name?(name)

        # 母本 createTable.js:10-13：**先查内置表、再查本群同名**（两路都要拦）
        return format(BUILTIN_NAME_TAKEN, name, name) if builtin_table?(name)

        result = custom_tables.create_table(
          chat_id: context[:chat_id].to_i, name: name, author_id: caller_id(context)
        )
        return format(DUPLICATE_PRIVATE, name) if result.already_exists?
        return BAD_TABLE_NAME if result.invalid_argument?
        return STORAGE_ERROR if result.error?

        "已在本群建表「#{name}」。用 /ct dice set 加骰型、/ct data set 录出目。"
      end

      # ==================================================================
      # rename（母本 ct_command/updateTableName.js）
      # ==================================================================
      def sub_rename(context, rest)
        parsed = take_flag(tokens(rest), 2, 3)
        return BAD_ARGS if parsed == :bad_args
        return BAD_FLAG if parsed == :bad_flag
        return CALLER_UNKNOWN unless caller_id(context)

        (old_name, new_name), flag = parsed
        # 母本 check 顺序：旧==新 先于 名字合法性（updateTableName.js:39-42）
        return "旧表名与新表名相同。" if old_name == new_name
        return BAD_TABLE_NAME unless valid_table_name?(old_name) && valid_table_name?(new_name)

        scope = scope_of(flag)
        table = fetch_table(context, old_name, scope)
        return not_found(old_name, scope) if table.nil?
        return format(NOT_ADMIN_BITS) unless write_allowed?(table, context, :admin_bits)

        # 母本 :11-12：新名在本 scope 已被占用 → 拒
        return format(DUPLICATE_RENAME, new_name) unless fetch_table(context, new_name, scope).nil?

        result = custom_tables.rename_table(
          chat_id: context[:chat_id].to_i, old_name: old_name, new_name: new_name, scope: scope
        )
        return not_found(old_name, scope) if result.not_found? # 竞态兜底
        return format(DUPLICATE_RENAME, new_name) if result.already_exists?
        return STORAGE_ERROR if result.error?

        "表名已更新：「#{old_name}」→「#{new_name}」。"
      end

      # ==================================================================
      # dice set / dice del（母本 ct_command/updateDice.js、deleteDice.js）
      # ==================================================================
      def sub_dice(context, rest)
        action, rest2 = rest.to_s.split(/\s+/, 2)
        case action.to_s.downcase
        when "set" then sub_dice_set(context, rest2.to_s)
        when "del" then sub_dice_del(context, rest2.to_s)
        else "用法：/ct dice set <表> <快捷名> <骰式> [t]；/ct dice del <表> <快捷名> [t]。"
        end
      end

      def sub_dice_set(context, rest)
        parsed = take_flag(tokens(rest), 3, 4)
        return BAD_ARGS if parsed == :bad_args
        return BAD_FLAG if parsed == :bad_flag
        return CALLER_UNKNOWN unless caller_id(context)

        (name, dice_name, expr), flag = parsed
        return BAD_TABLE_NAME unless valid_table_name?(name)
        # 母本 check：骰式正则先于小写化判定（1D6+X 会被拒，同母本）
        return BAD_DICE_EXPR unless DICE_EXPR_PATTERN.match?(expr)
        return BAD_DICE_NAME if DICE_NAME_FORBIDDEN.match?(dice_name)

        scope = scope_of(flag)
        table = fetch_table(context, name, scope)
        return not_found(name, scope) if table.nil?
        # 母本 updateDice.js:13-15：**全体** permission 列表
        return format(NOT_ADMIN_FULL, name) unless write_allowed?(table, context, :permitted)

        # 小写归一（母本 adjust 的 toLowerCase()）
        dice_name = dice_name.downcase
        expr = expr.downcase
        result = custom_tables.update_dice(
          chat_id: context[:chat_id].to_i, name: name,
          dice_name: dice_name, dice_string: expr, scope: scope
        )
        return STORAGE_ERROR if result.error?
        return not_found(name, scope) if result.not_found?

        # 范围钳自动维护（母本 updateDice.js:23-45；语义见文件头 A）
        sync = sync_range_after_dice_set(context, table, name, dice_name, expr, scope)
        return RANGE_SYNC_FAILED if sync == :error

        "表「#{name}」的骰型已更新：#{dice_name} : #{expr}。"
      end

      def sub_dice_del(context, rest)
        parsed = take_flag(tokens(rest), 2, 3)
        return BAD_ARGS if parsed == :bad_args
        return BAD_FLAG if parsed == :bad_flag
        return CALLER_UNKNOWN unless caller_id(context)

        (name, dice_name), flag = parsed
        return BAD_TABLE_NAME unless valid_table_name?(name)
        # 母本 deleteDice.js:42：a（默认骰型）不可删；判定在小写化之前（aA 都拒）
        return "快捷名「a」（默认骰型）不能删；要改请用 /ct dice set。" if PROTECTED_DICE_NAMES.include?(dice_name)
        return BAD_DICE_NAME if DICE_NAME_FORBIDDEN.match?(dice_name)

        scope = scope_of(flag)
        table = fetch_table(context, name, scope)
        return not_found(name, scope) if table.nil?
        return format(NOT_ADMIN_FULL, name) unless write_allowed?(table, context, :permitted)

        dice_name = dice_name.downcase
        existed = table.dice.key?(dice_name)

        # 母本 deleteDice.js:17-26：其余骰型都没有 +x 且钳制开着 → 关钳
        # （先算、后删——排除被删的那个快捷名）
        if table.datarange.is_use && !other_addition_dice?(table.dice, exclude: dice_name)
          sync = apply_range(context, name, scope, is_use: false, min: nil, max: nil)
          return RANGE_SYNC_FAILED if sync == :error
        end

        result = custom_tables.delete_dice(
          chat_id: context[:chat_id].to_i, name: name, dice_name: dice_name, scope: scope
        )
        return STORAGE_ERROR if result.error?
        return not_found(name, scope) if result.not_found?
        return "表「#{name}」本来就没有快捷名「#{dice_name}」（未改动）。" unless existed

        "表「#{name}」的骰型「#{dice_name}」已删除。"
      end

      # ==================================================================
      # data set / data del（母本 ct_command/updateData.js、deleteData.js）
      # ==================================================================
      def sub_data(context, rest)
        action, rest2 = rest.to_s.split(/\s+/, 2)
        case action.to_s.downcase
        when "set" then sub_data_set(context, rest2.to_s)
        when "del" then sub_data_del(context, rest2.to_s)
        else "用法：/ct data set <表> <出目> [t] <结果文本>；/ct data del <表> <出目> [t]。"
        end
      end

      # `data set` 的尾部是自由文本，flag 位置特殊：出目号之后的**紧邻 token**——
      # 若它恰为 t/T/f/F 则整条视为 flag（其后的全部内容为文本；没写文本 → 报错）；
      # 否则一律当文本（不做内容猜测）。规则见文件头「flag 解析」。
      def sub_data_set(context, rest)
        head = rest.match(/\A(\S+)\s+(\S+)\s+(.*)\z/m)
        return BAD_ARGS if head.nil?
        return CALLER_UNKNOWN unless caller_id(context)

        name = head[1]
        index = head[2]
        tail = head[3]
        return BAD_TABLE_NAME unless valid_table_name?(name)
        # 母本 updateData.js:44：出目必须是半角数字（放行字符串数字键语义由 db 层管）
        return BAD_INDEX unless DIGITS_PATTERN.match?(index)

        flag = nil
        text = tail
        with_flag = tail.match(/\A([tTfF])(?:\s+(.*))?\z/m)
        if with_flag
          flag = with_flag[1].downcase
          text = with_flag[2].to_s
        end
        text = text.strip
        return EMPTY_TEXT if text.empty?

        scope = scope_of(flag)
        table = fetch_table(context, name, scope)
        return not_found(name, scope) if table.nil?
        # 母本 updateData.js:13-15：**全体** permission 列表
        return format(NOT_ADMIN_FULL, name) unless write_allowed?(table, context, :permitted)

        result = custom_tables.update_data(
          chat_id: context[:chat_id].to_i, name: name,
          data_index: index, data_string: text, scope: scope
        )
        return STORAGE_ERROR if result.error?
        return not_found(name, scope) if result.not_found?

        # 范围钳自动维护（母本 updateData.js:22-34：开钳时按 data 键域 ∪ 新出目重算）
        sync = sync_range_after_data_set(context, table, name, index, scope)
        return RANGE_SYNC_FAILED if sync == :error

        "表「#{name}」的出目 #{index} 结果已录入。"
      end

      def sub_data_del(context, rest)
        parsed = take_flag(tokens(rest), 2, 3)
        return BAD_ARGS if parsed == :bad_args
        return BAD_FLAG if parsed == :bad_flag
        return CALLER_UNKNOWN unless caller_id(context)

        (name, index), flag = parsed
        return BAD_TABLE_NAME unless valid_table_name?(name)
        return BAD_INDEX unless DIGITS_PATTERN.match?(index)

        scope = scope_of(flag)
        table = fetch_table(context, name, scope)
        return not_found(name, scope) if table.nil?
        return format(NOT_ADMIN_FULL, name) unless write_allowed?(table, context, :permitted)

        # 母本 deleteData.js:17-18：本来就没有 → **成功语义**提前返回（且不动钳制）
        return format(DATA_MISSING, name, index) if table.data_entry(index).nil?

        # 母本 :20-33：存在 +x 骰型且删的是端点 → 按剩余 data 重算（isUse 原样）
        sync = sync_range_after_data_del(context, table, name, index, scope)
        return RANGE_SYNC_FAILED if sync == :error

        result = custom_tables.delete_data(
          chat_id: context[:chat_id].to_i, name: name, data_index: index, scope: scope
        )
        return STORAGE_ERROR if result.error?
        return not_found(name, scope) if result.not_found?
        return format(DATA_MISSING, name, index) if result.data_missing?

        "表「#{name}」的出目 #{index} 数据已删除。"
      end

      # ==================================================================
      # range（母本无命令层入口——T3.3 的 set_datarange 暴露到聊天层；
      #       登记为超越母本项，见文件头 C）
      # ==================================================================
      #
      # 两种形态：`range <表> <最小> <最大> [t]` 与 `range <表> off [t]`。
      # 形态判定按**位置**（不做内容猜测）：
      #   4 个 token → 末位必为 flag；3 个 token 且第 2 位是 off → 第 3 位是 flag；
      #   其余 2/3 个 token 无 flag。
      def sub_range(context, rest)
        argv = tokens(rest)
        return BAD_ARGS if argv.size < 2 || argv.size > 4
        return CALLER_UNKNOWN unless caller_id(context)

        flag = nil
        if argv.size == 4
          return BAD_FLAG unless FLAG_TOKENS.key?(argv.last.to_s.downcase)

          flag = argv.last.to_s.downcase
          argv = argv[0..-2]
        elsif argv.size == 3 && argv[1].to_s.casecmp?("off")
          return BAD_FLAG unless FLAG_TOKENS.key?(argv[2].to_s.downcase)

          flag = argv[2].to_s.downcase
          argv = argv[0..1]
        end

        name = argv[0]
        return BAD_TABLE_NAME unless valid_table_name?(name)

        scope = scope_of(flag)
        table = fetch_table(context, name, scope)
        return not_found(name, scope) if table.nil?
        # 范围钳与骰型/数据同族 → 用全体 permission 判据
        return format(NOT_ADMIN_FULL, name) unless write_allowed?(table, context, :permitted)

        if argv.size == 2 && argv[1].to_s.casecmp?("off")
          return RANGE_SYNC_FAILED if apply_range(context, name, scope,
                                                   is_use: false, min: nil, max: nil) == :error

          return "表「#{name}」的范围钳已关闭（不设限）。"
        end

        return BAD_RANGE unless argv.size == 3
        return BAD_RANGE unless DIGITS_WITH_SIGN_PATTERN.match?(argv[1]) &&
                               DIGITS_WITH_SIGN_PATTERN.match?(argv[2])

        min = argv[1].to_i
        max = argv[2].to_i
        return BAD_RANGE if min.abs > TenguDB::INT64_MAX || max.abs > TenguDB::INT64_MAX
        return RANGE_INVERTED if min > max

        return RANGE_SYNC_FAILED if apply_range(context, name, scope,
                                                 is_use: true, min: min, max: max) == :error

        "表「#{name}」的范围钳已开启：#{min}..#{max}。"
      end

      # ==================================================================
      # perm add / perm del（母本 ct_command/addPermission.js、deletePermission.js）
      # ==================================================================
      def sub_perm(context, rest)
        action, rest2 = rest.to_s.split(/\s+/, 2)
        case action.to_s.downcase
        when "add" then sub_perm_add(context, rest2.to_s)
        when "del" then sub_perm_del(context, rest2.to_s)
        else "用法：/ct perm add <表> <用户ID> [t]；/ct perm del <表> <用户ID> [t]。"
        end
      end

      def sub_perm_add(context, rest)
        parsed = take_flag(tokens(rest), 2, 3)
        return BAD_ARGS if parsed == :bad_args
        return BAD_FLAG if parsed == :bad_flag
        return CALLER_UNKNOWN unless caller_id(context)

        (name, uid), flag = parsed
        return BAD_TABLE_NAME unless valid_table_name?(name)
        return BAD_USER_ID unless DIGITS_PATTERN.match?(uid)

        scope = scope_of(flag)
        table = fetch_table(context, name, scope)
        return not_found(name, scope) if table.nil?
        # 母本 addPermission.js:11-15：**前三位**（admin 位）
        return NOT_ADMIN_BITS unless write_allowed?(table, context, :admin_bits)

        user_id = uid.to_i
        # 母本 :16-18：查全表权限数组（不止前三位）
        return "该用户（#{user_id}）已在权限名单里。" if table.permitted?(user_id)

        result = custom_tables.set_permissions(
          chat_id: context[:chat_id].to_i, name: name,
          permissions: table.permissions + [user_id], scope: scope
        )
        return STORAGE_ERROR if result.error?
        return not_found(name, scope) if result.not_found?

        "已给表「#{name}」添加权限：#{user_id}（可改骰型与出目数据）。"
      end

      def sub_perm_del(context, rest)
        parsed = take_flag(tokens(rest), 2, 3)
        return BAD_ARGS if parsed == :bad_args
        return BAD_FLAG if parsed == :bad_flag
        return CALLER_UNKNOWN unless caller_id(context)

        (name, uid), flag = parsed
        return BAD_TABLE_NAME unless valid_table_name?(name)
        return BAD_USER_ID unless DIGITS_PATTERN.match?(uid)

        scope = scope_of(flag)
        table = fetch_table(context, name, scope)
        return not_found(name, scope) if table.nil?
        # 母本 deletePermission.js:11-15：**前三位**（admin 位）
        return NOT_ADMIN_BITS unless write_allowed?(table, context, :admin_bits)

        user_id = uid.to_i
        admins = table.permissions.first(3)
        # 母本 :17-20 管理範囲チェック：前三位不许删（含建表者本人）
        return "不能删除权限前三位（管理位）的用户：#{user_id}。" if admins.include?(user_id)

        limited = table.permissions[3..] || []
        # 母本 :22-25：不在可删除范围 → 拒
        return "该用户（#{user_id}）不在可删除的权限位（第 4 位起）。" unless limited.include?(user_id)

        remaining = admins + (limited - [user_id])
        result = custom_tables.set_permissions(
          chat_id: context[:chat_id].to_i, name: name,
          permissions: remaining, scope: scope
        )
        return STORAGE_ERROR if result.error?
        return not_found(name, scope) if result.not_found?

        "已从表「#{name}」删除权限：#{user_id}。"
      end

      # ==================================================================
      # publish（母本 ct_command/publishTable.js）
      # ==================================================================
      def sub_publish(context, rest)
        tokens = tokens(rest)
        return BAD_ARGS unless tokens.size == 1
        return CALLER_UNKNOWN unless caller_id(context)

        name = tokens[0]
        return BAD_TABLE_NAME unless valid_table_name?(name)

        table = fetch_table(context, name, :private)
        return not_found(name, :private) if table.nil?
        # 母本代码**无**权限检查（其 help 却承诺 bot管理者/サーバー管理者/建表者）
        # → 本项目按计划 §5 落到前三位（admin 位）判据；见文件头「权限模型」。
        return NOT_ADMIN_BITS unless write_allowed?(table, context, :admin_bits)

        # 母本 :12-16：内置表撞名 + 公共同名，两路都拦
        return format(BUILTIN_NAME_TAKEN, name, name) if builtin_table?(name)
        return format(DUPLICATE_PUBLIC, name) unless custom_tables.fetch(
          chat_id: 0, name: name, scope: :public
        ).nil?

        # 母本 :17-21：数据完整性校验（isUse 或含 +x 时跳过——见文件头 ⑥）
        verify = data_verification(table)
        return verify unless verify.nil?

        result = custom_tables.publish_table(chat_id: context[:chat_id].to_i, name: name)
        return format(DUPLICATE_PUBLIC, name) if result.already_exists? # 竞态兜底
        return not_found(name, :private) if result.not_found?
        return STORAGE_ERROR if result.error?

        "「#{name}」已发布为公共表（全部群可用；原表已从本群移走）。"
      end

      # ==================================================================
      # delete（母本 ct_command/deleteTable.js）
      # ==================================================================
      def sub_delete(context, rest)
        parsed = take_flag(tokens(rest), 1, 2)
        return BAD_ARGS if parsed == :bad_args
        return BAD_FLAG if parsed == :bad_flag
        return CALLER_UNKNOWN unless caller_id(context)

        (name,), flag = parsed
        return BAD_TABLE_NAME unless valid_table_name?(name)

        scope = scope_of(flag)
        table = fetch_table(context, name, scope)
        return not_found(name, scope) if table.nil?

        # 母本 deleteTable.js:11-22：**public 分支只认 permission[0]**，
        # 私有分支认前三位（私有再叠加群管理员旁路；公共行没有「本群」）。
        if scope == :public
          return NOT_ADMIN_FIRST unless tengu_allowed?(table, context, :first_permission)
        else
          return format(NOT_ADMIN_BITS) unless write_allowed?(table, context, :admin_bits)
        end

        result = custom_tables.delete_table(
          chat_id: context[:chat_id].to_i, name: name, scope: scope
        )
        return STORAGE_ERROR if result.error?

        "表「#{name}」已删除。"
      end

      # ==================================================================
      # show / list（母本 ct_command/checkTableData.js、checkTableList.js）
      # ==================================================================
      def sub_show(context, rest)
        parsed = take_flag(tokens(rest), 1, 2)
        return BAD_ARGS if parsed == :bad_args
        return BAD_FLAG if parsed == :bad_flag

        (name,), flag = parsed
        return BAD_TABLE_NAME unless valid_table_name?(name)

        scope = scope_of(flag)
        table = fetch_table(context, name, scope)
        # 母本 checkTableData 直查单一 scope（不套查找顺序）→ 内置表不在其中；
        # 但撞名是验收关注点，给一句指路（超越母本的小提示，见报告 §4 决策 5）。
        if table.nil?
          return builtin_table?(name) ? builtin_hint(name) : not_found(name, scope)
        end

        render_table_detail(name, table)
      end

      def sub_list(context, rest)
        return BAD_ARGS unless tokens(rest).empty?

        all = custom_tables.all_for_chat(chat_id: context[:chat_id].to_i)
        lines = ["◆自定义表一览◆", "用法：/ct roll <表名> 掷表；/ct show <表名> 看详情。"]
        lines.concat(render_table_section("本群表", all["private"]))
        lines.concat(render_table_section("公共表", all["public"]))
        lines.join("\n")
      end

      # ==================================================================
      # roll（母本 SearchTableDiceroll.js + NJDiscordReply.addTableOutput）
      # ==================================================================
      def sub_roll(context, rest)
        tokens = tokens(rest)
        return BAD_ARGS if tokens.empty? || tokens.size > 3

        name = tokens[0]
        # 快捷名省略时按 a（母本 `diceKind = temp[1] ? temp[1] : "a"`），并 downcase
        kind = (tokens[1] || DEFAULT_DICE_NAME).to_s.downcase
        adjust = tokens[2]

        # 查找顺序 default→private→public（SearchTableDiceroll.js:13-24，db 层实现）
        resolution = custom_tables.resolve_table(
          name: name, chat_id: context[:chat_id].to_i, builtin: builtin_source
        )
        unless resolution.found?
          return "找不到表「#{name}」（内置表、本群表、公共表里都没有）。"
        end

        table = resolution.builtin || resolution.table
        expr = table.dice_string(kind)
        return format(DICE_MISSING, name, kind) if expr.nil? || expr.empty?

        # `+x` 可変数（SearchTableDiceroll.js:55-77）：含 +x 时才处理補正值；
        # 補正值非数字 → 视同未给（天狗原文「数字ではない値を与えられた場合は無視」）。
        has_addition = expr.include?("+x")
        rolled_expr = substitute_addition(expr, adjust, has_addition)
        return "表「#{name}」的骰式「#{expr}」无法解析（可能被手工改动）。" unless DICE_EXPR_PATTERN.match?(rollable(rolled_expr))

        raw = roll_expression(rollable(rolled_expr))
        return "表「#{name}」的骰式「#{expr}」无法解析（可能被手工改动）。" if raw.nil?

        # datarange 钳制（NJDiscordReply.js:91-95）：仅 +x 掷时、且钳制有界时生效
        clamped = raw
        range = table.datarange
        if has_addition && range && !range.unbounded?
          if !range.max.nil? && raw > range.max then clamped = range.max
          elsif !range.min.nil? && raw < range.min then clamped = range.min
          end
        end

        render_roll(resolution, name, kind, rolled_expr, raw, clamped, table)
      end

      # ==================================================================
      # help（母本 ct_command/help.js）
      # ==================================================================
      def sub_help(rest)
        topic = tokens(rest).first.to_s.downcase
        return USAGE if topic.empty?

        text = TOPIC_HELP[topic]
        return text if text

        "#{USAGE}\n（没有「#{topic}」这个子命令——看上面的清单。）"
      end

      # ==================================================================
      # 权限（母本逐操作判据 + Telegram 化群管理员旁路）
      # ==================================================================
      #
      # @param rule [Symbol] :permitted（全体列表）/ :admin_bits（前三）/ :first_permission
      def write_allowed?(table, context, rule)
        return true if tengu_allowed?(table, context, rule)
        # 公共行没有「本群」可言 → 不做群管理员查询（也省一次 getChatMember）
        return false if table.public?

        group_admin?(context)
      end

      def tengu_allowed?(table, context, rule)
        user_id = caller_id(context)
        return false if user_id.nil?

        case rule
        when :permitted then table.permitted?(user_id)
        when :admin_bits then table.admin?(user_id)
        when :first_permission then !table.permissions.first.nil? && table.permissions.first == user_id
        else false
        end
      end

      # 群管理员判定（Admin 助手：getChatMember，fail-closed；私聊豁免在 Admin 内部）
      # **未注入 admin → 群内一律拒**（fail-closed；同 settings handler 纪律）
      def group_admin?(context)
        return false if @admin.nil?

        @admin.admin?(context[:chat_id], context[:user_id], chat_type: context[:chat_type])
      rescue StandardError => e
        warn_line("[custom_table] 管理员判定异常，按拒绝处理：#{e.class}")
        false
      end

      def caller_id(context)
        uid = context[:user_id].to_i
        uid.zero? ? nil : uid
      end

      # ==================================================================
      # 范围钳自动维护（母本四处的命令层逻辑，见文件头 A）
      # ==================================================================

      # 母本 updateDice.js:23-45
      def sync_range_after_dice_set(context, table, name, dice_name, expr, scope)
        if expr.include?("+x")
          return :skip if table.datarange.is_use # 已开钳 → 母本不动

          bounds = data_bounds(table)
          apply_range(context, name, scope, is_use: true, min: bounds[:min], max: bounds[:max])
        else
          return :skip if other_addition_dice?(table.dice, exclude: dice_name)

          apply_range(context, name, scope, is_use: false, min: nil, max: nil)
        end
      end

      # 母本 updateData.js:22-34（开钳时按 data 键域 ∪ 新出目重算）
      def sync_range_after_data_set(context, table, name, index, scope)
        return :skip unless table.datarange.is_use

        bounds = data_bounds(table, extra: index.to_i)
        apply_range(context, name, scope, is_use: true, min: bounds[:min], max: bounds[:max])
      end

      # 母本 deleteData.js:20-33（删端点且存在 +x 骰型 → 按剩余 data 重算，isUse 原样）
      def sync_range_after_data_del(context, table, name, index, scope)
        return :skip unless addition_dice?(table.dice)

        range = table.datarange
        idx = index.to_i
        return :skip unless range.max == idx || range.min == idx

        remaining = table.data.reject { |k, _| k.to_s == index.to_s }
        bounds = bounds_of_keys(remaining.keys)
        apply_range(context, name, scope, is_use: range.is_use,
                                           min: bounds[:min], max: bounds[:max])
      end

      def apply_range(context, name, scope, is_use:, min:, max:)
        result = custom_tables.set_datarange(
          chat_id: context[:chat_id].to_i, name: name,
          is_use: is_use, max: max, min: min, scope: scope
        )
        return :error if result.error?

        :ok
      end

      # data 键域（整数）∪ extra；空 → {min: nil, max: nil}（母本哨兵 → null）
      def data_bounds(table, extra: nil)
        bounds_of_keys(table.data.keys, extra: extra)
      end

      def bounds_of_keys(keys, extra: nil)
        values = keys.filter_map { |k| Integer(k.to_s, exception: false) }
        values << extra unless extra.nil?
        return { min: nil, max: nil } if values.empty?

        { min: values.min, max: values.max }
      end

      def addition_dice?(dice)
        dice.any? { |_k, v| v.to_s.include?("+x") }
      end

      # 母本 isExistOtherAdditionDice（updateDice.js:71-81 / deleteDice.js:56-67）
      def other_addition_dice?(dice, exclude:)
        dice.any? { |k, v| k.to_s != exclude.to_s && v.to_s.include?("+x") }
      end

      # ==================================================================
      # 数据完整性校验（母本 publishTable.js:45-91）
      # ==================================================================
      #
      # 返回 nil = 通过；否则是给用户看的错误文案。
      # ⚠️ 与母本的两处差异（登记，见报告 §4 决策 6）：
      #   ① 母本的算式累计有 JS 字符串拼接 quirk（常量项逐字拼成字符串），本实现按
      #      **整数语义**计算（母本 quirk 只在畸形输入上出现，且结果是垃圾）。
      #   ② 母本只跳过 isUse=true；**骰式含 +x 时**（其 help 明示「判定できないから
      #      スキップ」）本实现同样跳过——两条并列。
      def data_verification(table)
        return nil if table.datarange.is_use
        return nil if addition_dice?(table.dice)
        return "表没有骰型，无法发布。" if table.dice.empty?

        ranges = table.dice.values.filter_map { |expr| dice_bounds(expr) }
        return "表没有可解析的骰式，无法发布。" if ranges.empty?

        min = ranges.map { |r| r[:min] }.min
        max = ranges.map { |r| r[:max] }.max

        missing = (min..max).reject { |i| table.data.key?(i.to_s) }
        unless missing.empty?
          return "出目 #{missing.join(',')} 没有登记数据，请先用 /ct data set 补齐。"
        end

        keys = table.data.keys
        if keys.size != max - min + 1
          return "数据数与可能出目不一致（登记数据数:#{keys.size}，出目范围:#{min}~#{max}）；" \
                 "多余的出目请用 /ct data del 删掉（/ct show 表名 可查看）。"
        end

        nil
      end

      # 一条骰式的 [min, max]（母本 :49-73 的整数语义版）
      def dice_bounds(expr)
        min = 0
        max = 0
        expr.to_s.gsub("-", "+-").split("+").each do |term|
          term = term.strip
          next if term.empty?

          if term.include?("d")
            times, sides = term.split("d", 2)
            t = times.to_i
            min += t
            max += t * sides.to_i
          else
            min += term.to_i
            max += term.to_i
          end
        end
        { min: min, max: max }
      end

      # ==================================================================
      # 掷表（母本 SearchTableDiceroll.checkTable 的 `+x` 替换 + 骰式求值）
      # ==================================================================

      # `+x` 替换（SearchTableDiceroll.js:57-77 逐条）：
      #   给了数字補正（Number + Math.floor，含负数/小数）→ "+x" 替换为该值；
      #   未给或非数字 → 替换为空串（等价 +0）。
      def substitute_addition(expr, adjust, has_addition)
        return expr unless has_addition

        value = parse_adjustment(adjust)
        if value.nil?
          expr.sub("+x", "")
        elsif value.negative?
          expr.sub("+x", value.to_s)
        else
          expr.sub("+x", "+#{value}")
        end
      end

      def parse_adjustment(raw)
        return nil if raw.nil?

        text = raw.to_s
        return nil unless /\A[+-]?\d+(?:\.\d+)?\z/.match?(text)

        text.to_f.floor
      end

      # 剥掉残留的 +x（理论上已被 substitute_addition 处理；防御手工数据）
      def rollable(expr)
        expr.to_s.sub("+x", "")
      end

      # 求值：TERM([+-]TERM)*，TERM = \d+ 或 \d+d\d+（命令层正则已限定形态）
      def roll_expression(expr)
        total = 0
        groups = expr.to_s.scan(/([+-]?)(\d+)(?:[dD](\d+))?/)
        return nil if groups.empty?

        # 全量消费校验：重建的串必须与原文逐字一致（防手改过的怪式被部分解析）
        consumed = groups.map { |sign, times, sides| "#{sign}#{times}#{sides ? "d#{sides}" : ''}" }.join
        return nil unless consumed == expr.to_s

        groups.each do |sign, times, sides|
          value = sides.nil? ? times.to_i : randomizer.roll_sum(times.to_i, sides.to_i)
          total += sign == "-" ? -value : value
        end
        total
      end

      # 随机源：对象直接用；callable 当工厂（每次掷骰取新的，见文件头「依赖注入」）
      def randomizer
        r = @randomizer
        r.respond_to?(:call) ? r.call : r
      end

      # ==================================================================
      # 渲染
      # ==================================================================

      def render_roll(resolution, name, kind, expr, raw, clamped, table)
        head = "#{source_label(resolution)}「#{name}」(#{kind})：#{expr} ＞ #{raw}"
        head += clamp_note(raw, clamped, table.datarange) if clamped != raw
        body = table.data_entry(clamped)
        body = "（出目 #{clamped} 没有登记数据）" if body.nil?
        "#{head}\n#{body}"
      end

      # 钳制标注（T1.4 的「钳制发生时明示」约定；天狗静默取端点）
      def clamp_note(raw, clamped, range)
        lo = range.min.nil? ? "-∞" : range.min.to_s
        hi = range.max.nil? ? "+∞" : range.max.to_s
        "（出目 #{raw} 超出钳制范围 #{lo}..#{hi}，按钳制取 #{clamped}）"
      end

      def source_label(resolution)
        case resolution.source
        when :builtin then "内置表"
        when :private then "本群表"
        else "公共表"
        end
      end

      def render_table_detail(name, table)
        scope = table.public? ? "公共表" : "本群表"
        lines = ["表「#{name}」（#{scope}）", "建表者：#{table.author_id}"]
        dice_part = table.dice.map { |k, v| "#{k} : #{v}" }.join(" , ")
        lines << "快捷骰：#{dice_part.empty? ? '（无）' : dice_part}"
        lines << "范围钳：#{range_text(table.datarange)}"
        lines << "权限（前三位=管理位）：#{table.permissions.empty? ? '（无）' : table.permissions.join(' , ')}"
        lines << "数据："
        if table.data.empty?
          lines << "（无）"
        else
          table.data.sort_by { |k, _| k.to_s.to_i }.each do |k, v|
            lines << "#{k}：#{v}"
          end
        end
        lines.join("\n")
      end

      def range_text(range)
        return "未设限" if range.unbounded? && !range.is_use

        lo = range.min.nil? ? "-∞" : range.min.to_s
        hi = range.max.nil? ? "+∞" : range.max.to_s
        "#{range.is_use ? '开启' : '关闭'} #{lo}..#{hi}"
      end

      def render_table_section(title, tables)
        lines = ["【#{title}】"]
        if tables.nil? || tables.empty?
          lines << "（无）"
        else
          tables.each do |t|
            dice_part = t.dice.map { |k, v| "#{k} : #{v}" }.join(" , ")
            lines << "#{t.name} — #{dice_part}"
          end
        end
        lines
      end

      def not_found(name, scope)
        if scope == :public
          "找不到公共表「#{name}」。"
        else
          "找不到表「#{name}」（本群没有这张表；用 /ct list 看本群与公共表）。"
        end
      end

      def builtin_hint(name)
        "「#{name}」是内置表（引擎内置），不在本群/公共表之列；掷它用 /ct roll #{name} 或引擎命令（如 /nd #{name}）。"
      end

      # ==================================================================
      # 工具
      # ==================================================================

      def tokens(rest)
        rest.to_s.strip.split(/\s+/)
      end

      # 定长命令的 flag 解析：`<固定参数...> [t|f]`——最大 arity 时最后一个 token
      # 是 flag（必须是 t/T/f/F，否则报错，不做内容猜测）。
      # @return [Array, Symbol] [ [args, flag_string_or_nil], ...] 或 :bad_args / :bad_flag
      def take_flag(argv, min, max)
        return :bad_args unless (min..max).cover?(argv.size)

        flag = nil
        if argv.size == max
          last = argv.last.to_s
          return :bad_flag unless FLAG_TOKENS.key?(last.downcase)

          flag = last.downcase
          argv = argv[0..-2]
        end
        [argv, flag]
      end

      def scope_of(flag)
        FLAG_TOKENS.fetch(flag.to_s, :private)
      end

      def valid_table_name?(name)
        text = name.to_s
        return false if text.empty? || text.length > NAME_MAX_LENGTH
        return false if /\s/.match?(text) || /\u3000/.match?(text)
        return false if /[\x00-\x1f\x7f]/.match?(text)

        true
      end

      def fetch_table(context, name, scope)
        custom_tables.fetch(chat_id: context[:chat_id].to_i, name: name, scope: scope)
      end

      # 内置表撞名（与 db 层 lookup_builtin 同一口径：键 downcase；源异常按未命中
      # + warn——fail-open 与查找侧对称：查不到内置表时也不会发生阴影）
      def builtin_table?(name)
        source = builtin_source
        return false if source.nil?

        key = name.to_s.downcase
        hit =
          case source
          when Hash then source[key]
          else source.respond_to?(:call) ? source.call(key) : nil
          end
        !hit.nil?
      rescue StandardError => e
        warn_line("[custom_table] 内置表撞名检查失败，按未命中处理：#{e.class}")
        false
      end

      def warn_line(message)
        @logger.warn(message)
      rescue StandardError
        nil # logger 坏了也不能让操作崩掉
      end
    end
  end
end
