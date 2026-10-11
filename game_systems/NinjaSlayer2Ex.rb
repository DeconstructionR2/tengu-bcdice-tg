# frozen_string_literal: true

# ============================================================================
# NinjaSlayer2 外部扩展类：NSRS 発狂表 + 天狗呈现版 SBX/WSX（T1.3）、
#                          カルマロンダリング ×5 派阀（T1.4）
# （#1版动作见姊妹文件 NinjaSlayerEx.rb）
#
# 目的：
#   1. 移植天狗ダイス忍杀的 NSRS 発狂表（BCDice 缺失项）—— 4 骰型命令族。
#      **语义=忠实天狗纯表查询**：天狗 `/nd NSRS発狂[,{A|B|C|D}]` 只掷骰查表，
#      **没有** 前置的 NRS 克服判定（父类 `NRS` 命令才有 `nB6>=难度` 那一步）。
#      用户 2026-10-11 拍板：不镜像父类的前置判定。
#   2. 移植天狗呈现版的 サツバツ / wasshoiエントリー 两张表为 SBX / WSX
#      （拍板 D1-A1=B：父类 SB / WSE 的纯文本版与天狗版并存，父类行为零改动）。
#   3. 覆写 NAME / SORT_KEY / HELP_MESSAGE（kimi-code T1.1 评审 P5）：
#      Ex 类不能裸继承父类的 NAME（bot 侧列举游戏系统时会与父类撞名）。
#   4. T1.4：移植天狗 カルマロンダリング ×5 派阀（KRS/KRZ/KRA/KRO/KRY）——
#      5 表 × 4 骰型（a~d）+ `@±x` 補正 + datarange 钳制。
#      **钳制先于索引**（天狗 NJDiscordReply.js:93-95 原文语义），
#      越界不是「不响应」而是取 datarange 端点项——与 NSRS 的 nil 守卫相反。
#
# 参考：
#   - 上游 lib/bcdice/base.rb:22-29    register_prefix / register_prefix_from_super_class
#   - 上游 lib/bcdice/base.rb:35-47    prefixes_pattern 冻结行为
#   - 上游 lib/bcdice/preprocessor.rb  三关前处理（空白/括号/implicit-D）
#   - 上游 lib/bcdice/dice_table/table.rb  Table#choice 的 index 语义
#   - 上游 lib/bcdice/game_system/NinjaSlayer2.rb  父类 NRS / SB / WSE 的输出形态
#   - references/src/TenguDiceBot/TenguDiceBot/tengu_dice/NJDiscordReply.js:93-95
#       钳制原文（超 max 取 data[max]、低于 min 取 data[min]）
#   - references/src/TenguDiceBot/TenguDiceBot/classes/SearchTableDiceroll.js
#       +x 解析原文（Number() + Math.floor，负数走 else 分支替换）
#   - references/src/TenguDiceBot/TenguDiceBot/classes/dice.js
#       d3+3+x 的真实掷法（split(/\+/)：无補正时 ["d3","3"]，有補正时 ["d3","3","x"]）
#   - docs/spike-t1.1-report.md         四机制实证与坑点
#   - docs/t1.2-coverage-audit.md §5.1  天狗绝对索引 vs BCDice 相对索引
#   - references/extracted/i18n_key_ledger.yml  NSRS/SBX/WSX/KR* 逐表登记
#   - docs/t1.4-karmarond-report.md    本任务实绩报告（含 Preprocessor 三关实测）
#   - 计划 §5 移植矩阵 / §8 T1.3·T1.4 / §12 R3
# ============================================================================

require "bcdice"
require "bcdice/game_system"
require "bcdice/game_system/NinjaSlayer2"

module BCDice
  module GameSystem
    class NinjaSlayer2Ex < NinjaSlayer2
      ID = "NinjaSlayer2Ex"

      # ゲームシステム名（kimi-code T1.1 评审 P5：加「拡張」后缀避免与父类撞名）
      NAME = "ニンジャスレイヤーTRPG 2版 拡張"

      # ゲームシステム名の読みがな
      # 上游惯例（bcdice-api dicebots.rb 按 SORT_KEY 升序列出系统）：
      # 变体类在父类 SORT_KEY 之后追加读音即可排到父类正下方；
      # 「…TRPG2」< 「…TRPG2かちょう」，且 1版「…TRPG」自然排在其前。
      SORT_KEY = "にんしやすれいやあTRPG2かちょう"

      # ダイスボットの使い方
      #
      # ⚠ **必须含父类的 HELP_MESSAGE 全文**（不是只写扩展部分）：
      #   HELP_MESSAGE 是**常量覆写**——Ex 类一旦自己定义，
      #   父类那段（K{x} 成功判定 / 追加判定 / SB / WS / WSE / NRS 的说明）
      #   就**整个消失**，bot 侧 /help 只会显示扩展命令，
      #   而 2版玩家最常用的 `K6` 成功判定反而没有说明。
      #   初版正是这个形态（T1.1 遗留；与 docs/t1.2-manual-diff.md B8
      #   记录的「天狗 tablehelp 漏列」是同一类失败）。
      #   1版 NinjaSlayerEx 已在 T1.7 改成 `parent_help + extension_help`，
      #   本类 T1.8 跟进。
      #
      # 为什么用 `NinjaSlayer2::HELP_MESSAGE` 拼接而不是**抄一份**：
      #   抄第二份 = 上游日后增补说明时 ours 不动 → 悄悄漂移。
      #   拼接则父类增补自动跟着走（本项目「父类规则唯一真源」口径，
      #   kimi-code T1.7 评审 Q5）。
      #
      # 父类 HELP 全文会一并保留——本扩展**不改变**父类任何命令的行为，
      # 那段说明对 Ex 类仍然准确（T1.3~T1.6 的 toml 孪生对拍是这条声明的守卫）。
      parent_help = NinjaSlayer2::HELP_MESSAGE

      HELP_MESSAGE = begin
        extension_help = <<~TEXT

        --- 天狗ダイス版 追加コマンド ---
        本システム（ニンジャスレイヤーTRPG 2版 拡張）は、天狗ダイス忍杀の独自表を
        移植しているため、親クラスのコマンドに加えて以下のコマンドが使用できます。

        --- 天狗独自表：NSRS発狂 ---
        - NSRS or NSRS_A
        1D3を振り、NSRS（ニンジャ・リアリティ・ショック）発症時の反応を決定します。

        - NSRS_B
        1D6を振り、NSRS_A と同じ表を参照します。

        - NSRS_C
        1D6+1を振り、NSRS_A と同じ表を参照します。

        - NSRS_D
        1D3+1を振り、NSRS_A と同じ表を参照します。

        ※ NSRS 発狂表は「発症後の反応決定」だけの表で、前段の NRS 判定
        （`{dice}B6>={難易度}`）は行いません。NRS 判定には親クラスの NRS コマンドを併用してください。
        ※ 未知の枝（例：`NSRS_X`）は応答しません。

        --- 天狗呈現版 定型表 ---
        - SBX
        1D6を振り、サツバツ表（天狗呈現版・効果サマリー付き）を返します。

        - WSX
        1D6を振り、Wasshoi!エントリー決定表（天狗呈現版）を返します。

        ※ 親クラスの SB / WSE は純テキスト版（SATSUBATSU / WASSHOI 表による出力）のままで、
        親クラスの行為は一切変更していません。

        --- カルマロンダリング（5 派閥）---
        5 派閥とも同じ形です。`@補正値` を付ける場合は `_A`〜`_D` の
        ショートカットを省略できません（天狗の仕様どおり）。

        - KRS        （ソウカイヤ派）
        - KRZ        （ザイバツ派）
        - KRA        （アマクダリ派）
        - KRO        （オムラ派）
        - KRY        （ヨロシサン派）

        記法：
        - 素の `KRS` は `KRS_A` と同じ（ショートカット省略時は A とみなします）。
        - `_A` / `_B` / `_C` / `_D` でダイス型を選びます。
        - `@+n` / `@-n` で補正値を選びます（負の値も指定できます）。
          小数は向下取整（`@1.9` → +1。天狗の `Number()+Math.floor` と同じ意味）。

        ダイス型：
        - KRS（ソウカイヤ）：A…1D3、B…1D6、C…1D6+1、D…2D6
        - KRZ / KRA / KRO / KRY：  A…1D3、B…1D3+1、C…2D3、D…1D3+3

        各表の収録範囲（補正を足した出目が範囲外になった場合のクランプ先）：
        - KRS        1〜12
        - KRZ        1〜6
        - KRA        1〜6
        - KRO        1〜6
        - KRY        1〜6

        例：
        - KRS_C         → 1D6+1 を振ってソウカイヤの表を引く
        - KRS_C@2       → 補正 +2
        - KRZ_D@-1      → 補正 -1（負の補正値）
        - KRO_D         → 1D3+3（補正なし）

        ※ 補正値を足した出目が表の収録範囲をこえた場合、
        範囲のうち最も近い値の項目を参照します
        （上のとおり、ソウカイヤ＝1〜12、その他 4 派閥＝1〜6。天狗と同じクランプ）。
        ※ 補正値には**必ず** `_A`〜`_D` を明示してください
        （`KRS@-1` は応答しません。天狗の仕様どおり）。
        ※ 未知の派閥（例：`KRB`）や未知のダイス型（例：`KRS_E`）は応答しません。

        --- キャラメイク 6 表 ---
        キャラクターシート作成時に引く表です。
        6 表とも **補正なし・クランプなしの純查表** です
        （天狗側に datarange が無く、出目が表の収録範囲を外れる概念がありません）。

        - NJI        初期ジツ系統        （1D6）
        - NJS        初期スキル          （1D6）
        - NJN        初期アイテム        （1D6）
        - NJK        初期知識スキル      （1D36）
        - NJC        初期サイバネ        （1D6）
        - NJB        生い立ち            （1D36）

        定値表示（`@出目`）:
        dice を振らずに、指定した出目の項目だけを表示します。
        - NJI@3       → 初期ジツ系統 の 3 番
        - NJK@25      → 初期知識スキル の 25 番
        - NJB@11      → 生い立ち の 11 番

        各表の収録範囲（`@出目` が応答する範囲）：
        - NJI / NJS / NJN / NJC   1〜6
        - NJK / NJB               1〜36

        例：
        - NJI         → 1D6 を振って初期ジツ系統表を引く
        - NJK@25      → 振らずに初期知識スキル表の 25 番を表示
        - NJI@6       → 出目 6（＝「1〜5 から選べ」の一文）を表示

        ※ `@出目` は**上の収録範囲内**だけ応答します。
        範囲外（例：`NJI@0` / `NJI@7` / `NJK@37`）は応答しません。
        ※ 先頭の 0 は範囲外として扱います（例：`NJI@03` は応答しません）。
        ※ **注意（同じ `@` でも意味が表により異なります）**：
          本 6 表の `@n` は「**定値表示**」（dice を振らない）、カルマロンダリング
          5 派閥の `@±n` は「**補正値**」（dice に足してから引く）です。
          見分け方は表名で判断してください。

        --- 聖戦判定 ---
        - SEISEN{DKK}
        2D6 を振り、合計が DKK 以下のとき成功します。
        天狗の wasshoi.js seisen と同じ判定式（合計 <= DKK）です。

        例：
        - SEISEN9      → 2D6 を振り、合計が 9 以下なら成功
        - SEISEN7      → 2D6 を振り、合計が 7 以下なら成功

        ※ `SEISEN`（数字なし）は応答しません。
        ※ 2D6 の合計は 2〜12 なので、DKK が 12 以上なら必ず成功、
        DKK が 1 以下なら必ず失敗になります（仕様どおり）。
        ※ `SEISEN 9`（空白区切り）は応答しません。エンジンが最初の空白で
        コマンドを切り `SEISEN` にするためで、全ゲームシステム共通の挙動です。

        --- 追加判定の拡張（T1.6）---
        親クラスのコマンド `K{x}[追加判定]` の後ろに、以下の2形態が使えます。
        （親クラスの追加判定の全文は上の親クラスメッセージにあります）

        - [{判定}]{y}*{倍率}    ※ 例：`[>=5*2]`（ヘンゲ『肉体破壊』用）
        追加判定の**命中数に倍率を掛けます**。`8d6>=4[>=5*2]` で 5以上（=5,6）が
        3 個出れば、表示は `追加判定[>=5]:6` になります（3×2）。倍率は小数も
        指定できます（`[>=5*2.5]` → 命中 3 個なら 7.5）。
        ※ 判定は `[>=]` `[>]` `[<=]` `[<]` `[=]` `[!=]` すべて指定可能です。
        ※ 素の `{y}` は倍率 1 と同じ意味です（親クラスと同じ `[>=5]` が使える）。
        ※ 素の `*`（`[>=5*]`）は倍率 0、`*0` も倍率 0 になります（天狗と同じ）。

        - [J]      出目 1 の数（ジツ暴走）をカウントします
        - [L]      出目 6 の数（LAN直結出目6数）をカウントします
        記憶符は天狗ダイスの短縮記法です。中身は `[=1]` / `[=6]` と**完全に
        同じ判定**で、違うのは表示ラベルだけです（`ジツ暴走[=1]:1[1]` と表示されます）。
        ※ 1 コマンドに複数指定できます：`K6[J][L]` / `K6[J][>=5*2]`
        ※ 天狗の `[C]`（コッポ判定＝出目4数）は**対応しません**。
        親の `[C]` は「クリティカル判定」の意味なので混乱を避けるため
        そのまま残しています。コッポ判定には `[=4]` を使ってください。
        ※ 倍率に数字以外（`[>=5*x]`）を書くと**応答しません**
        （天狗では倍率 1 にフォールバックしますが、書き間違いに気づけないため
        本拡張では整条を応答しない方針です）。
        ※ 倍率の上限は 100 です（`[>=5*101]` は応答しません）。

        ※ 親クラスの追加判定（`[=6]` / `[S5]` / `[C]` / `[>=665+]` など）は
        **一切変更していません**。

        --- 1版拡張とのコマンド名の重複について ---
        ※ `WS` / `WSE` は本システムでは**親クラスの2版コマンド**です
        （`WS{x}`＝Wasshoi!判定、`WSE`＝死神のエントリー決定表）。
        『ニンジャスレイヤーTRPG 1版 拡張』の `WS` は**別の表**
        （1版 wasshoiエントリー_1、収録範囲 1〜6）です。
        同じ `WS` がシステムによって別の表を指すので、群のシステム設定を
        切り替えたときは `WS` の意味が変わる点にご注意ください。
        TEXT

        parent_help + extension_help
      end

      # T1.1①：先继承超类全部前缀（UH/[KENHU]/SB/WS/WSE/NRS）。
      # T1.3：再用 register_prefix 追加本扩展的三个新前缀。
      # T1.4：追加カルマロンダリング 5 派阀前缀（KRS/KRZ/KRA/KRO/KRY）。
      # T1.5：追加キャラメイク 6 表前缀 + 聖戦判定前缀（SEISEN）。
      #
      # ⚠ 时序铁律（spike-t1.1-report.md §5.7 / 上游 base.rb:35-47）：
      # prefixes 在首次 eval / command_pattern / prefixes_pattern 调用时冻结，
      # 此后任何 register_prefix 都会 FrozenError。**全部注册必须在类体内完成**。
      register_prefix_from_super_class()
      register_prefix(
        "NSRS",
        "SBX",
        "WSX",
        "KRS",
        "KRZ",
        "KRA",
        "KRO",
        "KRY",
        # T1.5：キャラメイク 6 表。**前缀注册顺序无功能含义**，
        # 只影响 command_pattern 的正则顺序；这 6 个前缀两两不互为前缀
        # （NS/NJ 开头各自独立），不存在遮蔽问题（已由 toml 异常系用例钉住）。
        # 注意与父类前缀的潜在歧义：父类注册了 "NRS"，本批 NJ* 不与之重叠。
        "NJI",
        "NJS",
        "NJN",
        "NJK",
        "NJC",
        "NJB",
        # T1.5：聖戦判定。
        "SEISEN"
      )

      # 本扩展表命令的正则。
      #
      # NSRS 发狂表：裸 NSRS == NSRS_A（天狗省略快捷键时按 a 处理，
      # 见 tengu_dice/tablehelp.js「ショートカット英字が省略された場合はAを指定したものとみなします」）。
      RE_EX_NSRS = /^NSRS(?:_([ABCD]))?$/i.freeze

      # NSRS 発狂表的 4 个骰型。
      # 数据源：tengu_dice/nd_datatable.js:275-291 的 `dice: {a,b,c,d}`
      # （i18n_key_ledger.yml 的 NSRS 条目同源登记）。
      #
      # ⚠ yml 里的 `type: 1D3` **只表达默认骰型 a**（ledger roll_note），
      #   因此 DiceTable::Table.from_i18n 对本表不适用：
      #     - Table#choice 用 `value - @times` 算 index，是相对索引；
      #     - 天狗是绝对索引 `data[sum]`，含 +1 骰型时两者错位一格
      #       （coverage-audit §5.1）。
      #   故本表手写 roll + 显式 min_index 索引。
      NSRS_DICE_TYPES = {
        "A" => { expr: "1D3", times: 1, sides: 3, bonus: 0 },
        "B" => { expr: "1D6", times: 1, sides: 6, bonus: 0 },
        "C" => { expr: "1D6+1", times: 1, sides: 6, bonus: 1 },
        "D" => { expr: "1D3+1", times: 1, sides: 3, bonus: 1 }
      }.freeze

      # NSRS 発狂表的索引下限：天狗 data[1..7]，yml 已摊平为 0 基数组 → items[sum - 1]。
      NSRS_TABLE_MIN_INDEX = 1

      # 本扩展的两张 1d6 单骰型表（ledger: 单骰型表 type 与 data_index 全域一致，
      # 可直接用 DiceTable::Table）。
      EX_SIMPLE_TABLES = {
        "SBX" => "NinjaSlayer2Ex.table.SBX",
        "WSX" => "NinjaSlayer2Ex.table.WSX"
      }.freeze

      RE_EX_SIMPLE_TABLE = /^(SBX|WSX)$/i.freeze

      # ======================================================================
      # T1.4：カルマロンダリング ×5 派阀
      # ======================================================================
      #
      # 语义铁律（源码实测值，逐条对应 kimi-code T1.3 评审预警）：
      #
      # ① 钳制先于索引（tengu_dice/NJDiscordReply.js:93-95 原文）：
      #      if (datarange.max < sumall) table = data[datarange.max];
      #      else if (datarange.min > sumall) table = data[datarange.min];
      #      else table = data[sumall];
      #    → 越界**不是**「不响应」，而是取 datarange 端点项。
      #    → T1.3 NSRS 的 `return nil if body.nil?` 守卫**在此不适用**，
      #      复用其骨架时必须改掉（见下方 proc_karmarond）。
      #
      # ② +x 解析（classes/SearchTableDiceroll.js:checkTable 原文）：
      #      Math.floor(Number(additionValue))；负数走 else 分支替换
      #      （diceStr.replace("+x", Math.floor(...)) → "1d3-2"）。
      #    → floor 语义、负数合法；省略/非数字 → 天狗替换为 "" 即 0。
      #    → 天狗 tablehelp.js：「補正値を指定するときにはショートカットを
      #      省略できません」→ ASCII 形态 KRS@-1 **不响应**，
      #      必须显式 KRS_A@-1（见 RE_KARMAROND）。
      #
      # ③ 索引恒为 items[clamp(sum) - min_index]，五表 min_index 均 = 1。
      #
      # ④ `d3+3+x`（4 派阀的 D 骰型）不是 1 颗 3 面 + 3，而是
      #      1 颗 3 面 **再加常量 3**（dice.js: 字符串按 '+' 拆分，
      #      纯数字段走 NUMBER_ONLY 分支计入 sum；末位空串不掷也不计）。
      #    → 语义等价于 ledger 登记的 `d3+3+x`，本次改写为 times=1/sides=3/bonus=3。
      #
      # ⑤ BCDice Preprocessor 三关与本语法的交互（**实测**，见
      #      docs/t1.4-karmarond-report.md §3）：
      #      - trim_after_whitespace：`KRS_C@2 foo` → `KRS_C@2`（正常，取空白前）
      #      - replace_parentheses：本语法规避 '(' ')'，永不改写
      #      - replace_implicit_d / `(\d+)D([^\w]|$)`：本类命令**不含 nD**
      #        （`@` 補正是纯数字，不触发），无副作用
      #    → 结论：ASCII `@±x` 形态与三关无冲突，无需 change_text 覆写。

      # 5 派阀 → 4 骰型规格。
      # 数据源同源：tengu_dice/nd_datatable.js:112-217 的 `dice: {a,b,c,d}`
      # + references/extracted/i18n_key_ledger.yml 的 dice_ranges 逐条登记。
      #
      # expr = 展示用骰型标记（含常量项，如 "1D6+1" / "1D3+3"）；
      # times/sides 是实际掷的骰；bonus 是常量（先计入 sum，再钳制、再索引）。
      KARMAROND_DICE_TYPES = {
        # ソウカイヤ派：1d3+x / 1d6+x / 1d6+1+x / 2d6+x（datarange 1..12）
        "KRS" => {
          "A" => { expr: "1D3", times: 1, sides: 3, bonus: 0 },
          "B" => { expr: "1D6", times: 1, sides: 6, bonus: 0 },
          "C" => { expr: "1D6+1", times: 1, sides: 6, bonus: 1 },
          "D" => { expr: "2D6", times: 2, sides: 6, bonus: 0 }
        }.freeze,
        # ザイバツ派：1d3+x / 1d3+1+x / 2d3+x / d3+3+x（datarange 1..6）
        "KRZ" => {
          "A" => { expr: "1D3", times: 1, sides: 3, bonus: 0 },
          "B" => { expr: "1D3+1", times: 1, sides: 3, bonus: 1 },
          "C" => { expr: "2D3", times: 2, sides: 3, bonus: 0 },
          "D" => { expr: "1D3+3", times: 1, sides: 3, bonus: 3 }
        }.freeze,
        # アマクダリ派：同上（1d3+x / 1d3+1+x / 2d3+x / d3+3+x）
        "KRA" => {
          "A" => { expr: "1D3", times: 1, sides: 3, bonus: 0 },
          "B" => { expr: "1D3+1", times: 1, sides: 3, bonus: 1 },
          "C" => { expr: "2D3", times: 2, sides: 3, bonus: 0 },
          "D" => { expr: "1D3+3", times: 1, sides: 3, bonus: 3 }
        }.freeze,
        # オムラ派：同上
        "KRO" => {
          "A" => { expr: "1D3", times: 1, sides: 3, bonus: 0 },
          "B" => { expr: "1D3+1", times: 1, sides: 3, bonus: 1 },
          "C" => { expr: "2D3", times: 2, sides: 3, bonus: 0 },
          "D" => { expr: "1D3+3", times: 1, sides: 3, bonus: 3 }
        }.freeze,
        # ヨロシサン派：同上
        "KRY" => {
          "A" => { expr: "1D3", times: 1, sides: 3, bonus: 0 },
          "B" => { expr: "1D3+1", times: 1, sides: 3, bonus: 1 },
          "C" => { expr: "2D3", times: 2, sides: 3, bonus: 0 },
          "D" => { expr: "1D3+3", times: 1, sides: 3, bonus: 3 }
        }.freeze
      }.freeze

      # 各表的 datarange（钳制边界）。来源：nd_datatable.js 各表的
      # `datarange: {max, min}`，ledger 同源登记（datarange 字段）。
      # 与 ledger dice_ranges 独立编码（此处刻意重复登记，gen_table_toml.rb
      # 会做 ledger ↔ 代码 的一致性交叉校验，见该脚本 §4）。
      KARMAROND_DATARANGE = {
        "KRS" => { min: 1, max: 12 }.freeze,
        "KRZ" => { min: 1, max: 6 }.freeze,
        "KRA" => { min: 1, max: 6 }.freeze,
        "KRO" => { min: 1, max: 6 }.freeze,
        "KRY" => { min: 1, max: 6 }.freeze
      }.freeze

      # 五表的索引下限恒为 1（ledger min_index 逐表登记 = 1）。
      KARMAROND_TABLE_MIN_INDEX = 1

      # カルマロンダリング命令的正则。
      #
      # 天狗原文法 `,C,-1`（表名,ショートカット,補正値）ASCII 化为
      # `{派阀}_{骰型}@{±補正}`。要点：
      #   - 裸 `{派阀}` == `{派阀}_A`（天狗「ショートカット英字が省略された
      #     場合はAを指定したものとみなします」，tablehelp.js:2 節）。
      #   - **带 @ 補正时必须显式 `_X`**（天狗「補正値を指定するときには
      #     ショートカットを省略できません」）→ `KRS@-1` 不匹配 → 不响应。
      #     故正则写成两个互斥分支而不是 `(...)?(?:@...)?` 的可省略嵌套：
      #     后者会让「省略 _X 仍带 @」意外通过（2026-10-11 实测踩中）。
      #   - `@` 后天狗是 Number(x) + Math.floor → 接受小数取下整
      #     （`KRS_A@1.9` → +1，`KRS_A@-1.5` → -2）。ASCII 侧保留 floor 语义。
      #   - 正负号皆可（`@+2` / `@-2`）；计划 §6 写的是 `@±x`。
      #     天狗原文法 `,C,2` 无符号，但 `Number("+2") === 2`，
      #     ASCII 侧显式允许正号属无损放宽（不改变任何既有语义）。
      #     负数合法（tablehelp 例 `/nd ソウカイヤカルマロンダリング,C,-1`）。
      #
      # 分组：1=派阀 / 2=骰型(带@时) / 3=補正值(带@时) / 4=骰型(不带@时)
      RE_KARMAROND = /^(KRS|KRZ|KRA|KRO|KRY)(?:_([ABCD])@([+-]?\d+(?:\.\d+)?)|(?:_([ABCD]))?)$/i.freeze

      # ======================================================================
      # T1.5：キャラメイク 6 表 + 定値表示 `@n` + 聖戦判定
      # ======================================================================
      #
      # 语义铁律（逐条对应 kimi-code T1.5 评审预警，四项全落实）：
      #
      # ① **绝不钳制**（预警 1）。
      #    天狗 NJDiscordReply.js:91-97 的钳制分支挂在
      #    `if (diceroll.isTableAdditionValue)` 之下，而 isTableAdditionValue
      #    只在 `/\+x/.test(diceStr)` 为真时被置位（SearchTableDiceroll.js:56-77）。
      #    本批 6 表的 dice 字面量是 "1d6" / "1d36"——**不含 "+x"**，
      #    故走 else 分支 `tableString = data[diceroll.sumall]`，
      #    即 ledger 里 6 表 datarange = null 的登记。
      #    → 因此本批**不得**复用 proc_karmarond 的钳制骨架；
      #      也不设 DATARANGE 常量（没有可钳的边界，凭空造一个反而是假信息）。
      #    → 越界语义同天狗：索引越界 → data[出目] 为 undefined → 天狗 addString 为空；
      #      ASCII 侧取「不响应」（proc_chara_make 显式守卫）。
      #
      # ② **d36 = 单颗 36 面**（预警 2，已实证，见 docs/t1.5-report.md §2）。
      #    天狗 Dice('1d36') 实测：resArray.length 恒 = 1，5000 次掷骰 sum ∈ [1,36]，
      #    非 D66 的 6×6=36 组合表；6 表里也**没有一张**带 d66Option 字段
      #    （nd_datatable.js 无此键，全仓 d66Option 仅 NJDiscordReply.js:83 一处判断）。
      #    → `NJK` / `NJB` 直接掷 1 颗 36 面骰，索引 items[sum - 1]，
      #      **不存在** D66 式 11..66 → 1..36 的映射。
      #
      # ③ **定値表示 `@n` 的越界与前导零**（与天狗 /fnd 逐条对齐，实测同 §2）：
      #    天狗 discord_command/fnd.js → NJDiscordReply.receiveFixedMessage:115
      #      `data[stringArray[1]] != null` —— 用**字符串原键**查表。
      #    → data 的键是 "1".."6" / "1".."36"，故 "03" / "0036" 查不到 → 不响应。
      #    → 正则写 `[1-9]\d*`（不含 0 开头）+ 显式范围守卫，两者缺一不可：
      #      只靠正则会漏掉上界（NJI@7 / NJK@37），
      #      只靠 to_i 会把 "07" 误当合法（`"07".to_i == 7`）。
      #
      # ④ **同字符两语义**（任务书要求）：本 6 表 `@n` = 定値显示（不掷骰）；
      #    T1.4 的 5 派阀 `@±n` = 補正值（掷骰后相加）。两者互不影响——
      #    正则分支互斥（`NJI@3` 只可能进 CHARAMAKE 分支，`KRS_C@2` 只进 KARMAROND）。
      #    HELP_MESSAGE 已明写边界。
      #
      # ⑤ **聖戦判定**（wassohoi.js:42-44 实测语义）：
      #    2D6，`dice.sum <= Number(dkk)` 成功。
      #    输出骨架 `<判定名>! = (a+b) = sum<=dkk  判定成功!<successMessage>`
      #    / `... 判定失敗`（success_word 用于成功分支，failure_word 用于失败）。
      #    天狗 KIND.SEISEN 的正则 `/^seisen(\d+)$/i` **不含** `!` / `！`
      #    （对比 WASSHOI 的 `/^wasshoi[!！]?(\d+)$/i`），故 ASCII 侧同样不收 `!`。
      #    数字无上下界（天狗 `seisen0` 合法、恒失败；`seisen99` 合法、恒成功），
      #    ASCII 侧忠实照搬，不自行加 DKK 范围限制。
      #    ⚠ 空白：BCDice Preprocessor.trim_after_whitespace 会把 "SEISEN 9"
      #      截成 "SEISEN"（不响应），天狗侧是 DiceRoll 构造函数先剥空白再匹配（响应）。
      #      这是 BCDice 引擎层的既有行为、**对全部游戏系统一致**，
      #      不在本扩展内 change_text 覆写（改它会偏离引擎统一语义）。已在 HELP 与
      #      toml 异常系中显式记录。

      # 6 张表 → 骰型规格。数据源同源：nd_datatable.js 各表的 `dice: { a: "1d6" }`
      # / `{ a: "1d36" }`，ledger dice_ranges 逐条登记。
      #
      # times/sides 是实际掷的骰；无 bonus（本批无带常量的骰型）。
      # sides=36 即上文铁律②的实证结论（单颗 36 面）。
      CHARAMAKE_DICE_TYPES = {
        "NJI" => { expr: "1D6", times: 1, sides: 6 },
        "NJS" => { expr: "1D6", times: 1, sides: 6 },
        "NJN" => { expr: "1D6", times: 1, sides: 6 },
        "NJK" => { expr: "1D36", times: 1, sides: 36 },
        "NJC" => { expr: "1D6", times: 1, sides: 6 },
        "NJB" => { expr: "1D36", times: 1, sides: 36 }
      }.freeze

      # 6 表的索引下限恒为 1（ledger min_index 逐表登记 = 1）。
      CHARAMAKE_TABLE_MIN_INDEX = 1

      # キャラメイク表的命令正则（裸掷骰 与 定値显示 两分支互斥）。
      #
      # `([1-9]\d*)` 而非 `(\d+)`：天狗 /fnd 是**字符串键**直查
      # （NJDiscordReply.js:115），data 的键为 "1".."6"，
      # 故 "03" 查不到 → 不响应（铁律③）。
      # 上界（1D6→6、1D36→36）不在正则里写死，由 proc_chara_make 读 items.length 守卫，
      # 这样 yml 条目数与命令上界**恒等**，items 被手改时不会出现"表有 6 条但允许 @9"。
      #
      # ⚠ 不可写成 `^(...)(?:@(\d+))?$` 的可省略嵌套——虽然功能上等价，
      #   但会把「不掷骰的定値」与「掷骰」在一条分支里混起来，
      #   读代码时容易误以为裸命令会走 @n 路径。分成两组捕获更清晰。
      RE_CHARAMAKE = /^(NJI|NJS|NJN|NJK|NJC|NJB)(?:@([1-9]\d{0,5}))?$/i.freeze

      # 聖戦判定的命令正则。
      #
      # 天狗 KIND.SEISEN.kindRegExp = /^seisen(\d+)$/i（wasshoi.js:58）：
      #   - 无 `!` / `！`（那是 WASSHOI 分支才有的）；
      #   - 数字无正负、无上界（`\d+`）。
      # ASCII 侧忠实照搬。
      RE_SEISEN = /^SEISEN(\d+)$/i.freeze

      # 聖戦判定的骰型（wasshoi.js:40 硬编码 `new Dice('2d6')`）。
      #
      # 拆成两个常量而非散在方法体里，是为了让 gen_table_toml.rb / 
      # ledger_consistency_test.rb 能把它当「代码侧规格」来交叉校验
      # （与 KARMAROND_DICE_TYPES 同样的读法）。
      SEISEN_DICE_TIMES = 2
      SEISEN_DICE_SIDES = 6

      # 聖戦判定的判定式：合計 <= DKK（wasshoi.js:43 `dice.sum <= Number(dkk)`）。
      # 落成常量供测试断言，方法里真的用它做比较，避免"文档写了 <= 代码写了 <"。
      SEISEN_CMP = :<=

      # ------------------------------------------------------------------
      # T1.6：追加判定扩展 —— 倍率 `[>=5*2]` + 记忆符 `[J]`/`[L]`
      # ------------------------------------------------------------------
      #
      # 语义铁律（全部来自**真函数实测**，非源码推断，见 docs/t1.6-report.md §2）：
      #
      # ① **倍率 = 命中数 × 倍率**（classes/Appendix.js:19 + classes/dice.js:158-162）
      #      Appendix 构造：`string.split(/([<>!]=?|=|\*)/)` → [前, op, border, "*", 倍率串]
      #      `bairitsu = (strArray[4] != null && !isNaN(strArray[4])) ? Number(strArray[4]) : 1`
      #      dice.js 二次计数：`appSum += app[k].bairitsu`（**逐个命中累加**）
      #      → 实测 `8d6>=4[>=5*2]` 命中 3 颗 → 追加カウント = 6（非 3）。
      #      形态 `[>=y*N]`：**只对比较型追加判定生效**（天狗 Appendix 强制
      #      option ∈ {<,<=,=,==,!=,>=,>}，倍率是 option+border 之后的第三段）。
      #
      # ② **记忆符是「标签化的 [=y]」**，不是新判定逻辑
      #      （tengu_dice/NJShortcutTranslator.js:124 appTransration 实测）：
      #        [J] → '=1/ジツ暴走'            → 计数逻辑 == [=1]，只换标签
      #        [L] → '=6/LAN直結出目6数'      → 计数逻辑 == [=6]，只换标签
      #      且**是单条骰式内的追加计数器**（createAppendix 按 ',' 切分，
      #      元素落在同一条 Dice 上），无跨消息状态 → 落引擎层安全。
      #
      # ③ **合计値的不对称（有意偏离，见报告 §5）**
      #      天狗 `this.sum += appSum`（dice.js:170）把倍率后的命中数**并入合计**；
      #      BCDice 父类的追加判定**从不并入成功数**（proc_dice_2nd 只把
      #      `roll_result.success_num` 累进 total_success_num）。
      #      → 本扩展沿用父类模型：倍率只放大**追加カウント的显示值**，
      #        不并入成功数/達成値。理由：父类的成功数是判定成败的输入，
      #        一旦并入倍率项，`K6[>=5*2]` 的成败就会随倍率改变，
      #        而天狗那边成功数与追加カウント 是两个独立呈现的口径。
      #        玩家要合计值时用 `calc` 自行相加（T1.9 备查）。
      #
      # ④ **异常倍率按天狗语义（默认 1）**，实测四条（报告 §2.2）：
      #      `[>=5*x]` → isNaN → **倍率 1**（不拒答！天狗照常输出，只是倍率没生效）
      #      `[>=5*]`  → split 出空串 → Number('')===0 → **倍率 0**
      #      `[>=5*0]` → **倍率 0**（合法，命中数×0=0）
      #      `[>=5*2.5]` → **倍率 2.5**（小数合法！dice.js 逐颗累加可出 .5）
      #      → 三条铁律：**默认值照抄天狗（含 0 / 1 的怪异分支）**、
      #        **小数倍率合法且不取整**、**倍率非数字不拒答（降级为 1）**。
      #      唯一新增的收口是天狗没有的：`bairitsu_max` 上界（i18n
      #      judge.APPENDIX_EX.bairitsu_max）—— 报告 §5 申报为有意偏离。
      #
      # ⑤ **`[C]` 不搬**（计划 §5 拍板）：BCDice 上游 `[C]` 已是
      #      クリティカル判定（父类 RE_COUNT_CRITICAL），天狗 `[C]` 是
      #      コッポ判定（出目4数カウント）。同名不同义 → 保上游，
      #      コッポ改用 `[=4]`（**父类已原生支持**）。结构守卫钉死这一点。
      #
      # ⑥ **Preprocessor 三关实测**（报告 §1，逐条跑过）：
      #      - trim_after_whitespace：`K6[J] 备注` 被截成 `K6[J]`（仍响应）；
      #                       `K6 [J]` 被截成 `K6`（**追加判定丢失**，不响应预期外的成功）
      #                       → 天狗侧是 `2d6>=4 [=1]` **抛异常**（dice.js CHECK_APPENDIX_SINTAX），
      #                       两者都不接受「骰式与追加判定之间有空格」，行为一致。
      #      - replace_parentheses：`[(3*2)]` 被算成 `[6]`（父类 appendix 不含
      #                       括号，故本扩展的 appendix 也一律不含 → 无需回避）
      #      - replace_implicit_d：`2D6>=4[...]` 里的 `2D6` 会被 implicit_d
      #                       规则改写吗？**实测不会**（`(\d+)D([^\w]|$)` 要求 D 后
      #                       是非单词字符，`2D6` 的 D 后是数字 6 → 不触发）；
      #                       但 `2D+...` 形态会触发，本语法不含之。
      #      - upcase：`@enabled_upcase_input` 在 **Preprocessor 之后**
      #                       （base.rb:247 在 dice_command 内）执行 → `[j]`/`[l]`
      #                       到达 proc_ex_appendix 时恒为大写 J/L，大小写天然等价；
      #                       同时**它只 upcase 整条命令**，不单独处理 appendix 内容
      #                       → 倍率串/数字不受影响（实测 `[>=5*2]` 原样）。
      #
      # ⑦ **与父类追加判定的共存形态**（钉版 toml 证据）：
      #      `[J]` / `[L]` / `[>=5*2]` 是**父类正则不接受的新 appendix 形态**，
      #      所以本扩展自带一条更宽的 dice 部正则（RE_EX_DICEROLL）先行，
      #      命中后交给 proc_ex_appendix；未命中一律 `super`（父类原路径，
      #      `[=6]`/`[S5]`/`[C]` 等**零改动**，由 toml 孪生对拍钉死）。

      # 天狗的记忆符 → (判定符, 出目, 标签)。**标签不进代码**：
      # 标签与出目都从 i18n 读（judge.APPENDIX_EX.{J,L}.{label,border}），
      # 逐字来源 = tengu_tables.json $.shortcut.appendix[].expands_to
      # （= '3d6>=4[=1/ジツ暴走]' 的注释段），由 scripts/json_to_i18n.rb 生成期搬运。
      # 这里只登记「记忆符字母 → 天狗判定符」的映射（判定符是语法，不是文案）。
      APPENDIX_MEMO_OPERATOR = "=".freeze

      # 无记忆符时的默认标签（父类 proc_appendix 的输出文案，逐字沿用）。
      #
      # 为什么写死在代码里而不在 yml：它**不是**天狗的数据——天狗那边的
      # 默认 comment 是硬编码的 `'追加カウント'`（Appendix.js:11），
      # 且**日文不同**（カウント vs 判定）。本扩展沿用父类 BCDice 的
      # 「追加判定」以保证同一条命令里 `K6[J][>=5*2]` 两段风格统一，
      # 也在 NinjaSlayer2.toml 孪生对拍里天然对齐。故它是**有意的分歧**，
      # 不进 yml（进 yml 会让人误以为能逐字回读天狗）。报告 §5 申报。
      APPENDIX_DEFAULT_LABEL = "追加判定".freeze

      # 天狗记忆符 → i18n 键名。字母表是**封闭**的（注册在类定义期完成，
      # 见 register_prefix 时序铁律注释），不存在运行期动态扩展。
      APPENDIX_MEMO_KEYS = %w[J L].freeze

      # 倍率上界。天狗无上界（`[>=5*999999]` 合法，Appendix.js:19 只判 isNaN）。
      # 本扩展自定上界，超出即整条命令不响应——理由与数值都在 yml
      # （judge.APPENDIX_EX.bairitsu_max，生成期写死 100），
      # 代码只读不写，改上界请改 json_to_i18n.rb 的生成值。
      def self.appendix_bairitsu_max
        I18n.t("NinjaSlayer2Ex.judge.APPENDIX_EX.bairitsu_max", locale: :ja_jp)
      end

      # 倍率的「合法数字串」形态。天狗是 `Number(x)` + `isNaN` 兜底（实测 §2.2）：
      #   - `Number('')` === 0        → 裸 `*` 给出 0
      #   - `isNaN('x')` → true      → `*x` 落到默认 1
      #   - `Number('2.5')` === 2.5  → 小数合法
      # 故 ASCII 侧只需一个宽松数字串 `\d*\.?\d*` 即可复刻前三条分支：
      # 空串 → 0（天狗同）、纯数字 → 原值、小数 → 原值。
      #
      # ⚠ `*x`（非数字）**故意不收**：天狗会降级成倍率 1 并照常输出，
      #   ASCII 侧让整条命令不响应——玩家打 `[>=5*x]` 时多半是把倍率写错了，
      #   静默按 1 输出比不响应更危险（他以为生效了）。报告 §5 申报为有意收紧。
      # （注：倍率数字串的权威形态定义在 APPENDIX_ONE_FRAGMENT 内联，
      #   初版的 RE_APPENDIX_BAIRITSU 死常量已删除——kimi P3c。）

      # 追加判定（appendix）单条形态的**无锚点片段**。
      #
      #   判定符 = `(=|!=|>=|>|<=|<)` —— 与父类 RE_COUNT_JUDGE 的
      #            分组 1 **逐字同源**（结构守卫直接比对源码常量）。
      #   y      = 只收单值 `[1-6]`，与父类单值分支同源。
      #            ⚠ **不收集合判定 `665+`**：天狗那边 appendix 的 border 走
      #            `Number(strArray[2])`（Appendix.js:18），`665+` → NaN →
      #            checkAppendix 抛错，即天狗**根本不支持**集合判定。
      #            BCDice 父类支持，但那走的是父类路径（super），
      #            不该被倍率形态顺手接管——否则 `[>=665+*2]` 会在这里
      #            静默生效，与天狗相反。
      #   倍率   = 可选 `*` + 数字串（T1.6 新增；空串 = 天狗的 Number('')===0）
      #   记忆符 = J / L（T1.6 新增）
      #
      # ⚠ 外层**必须**是非捕获组 `(?:…)`：写成捕获组 `((…)|([JL]))` 会让
      #   交替的 `|` 落在这个组的**内部**（交替优先级低于分组），
      #   于是组 1 匹配的是整个比较形态 `">=5*2"` 而非判定符 `">="`，
      #   组号整体错位。这是本任务实现期真实踩到的坑（`K6[>=5*2]` 静默不响应）。
      #
      # 分组：1 判定符、2 y、3 倍率串（可缺省：无 `*` 段 → nil）、4 记忆符字母。
      APPENDIX_ONE_FRAGMENT = "(?:(=|!=|>=|>|<=|<)([1-6])(?:\\*([\\d]*\\.?[\\d]*))?|([JL]))".freeze

      # 单条 appendix 的完整正则 = 片段 + 锚点。
      # 与 RE_EX_DICEROLL 用**同一个**片段常量拼装 → 两者同源是构造保证，
      # 不是靠人工同步（结构守卫仍会复核，但漂移已无处可藏）。
      #
      # proc_ex_appendix 按「分组4 非 nil → 记忆符」分流。
      RE_EX_APPENDIX_ONE = Regexp.new("\\A#{APPENDIX_ONE_FRAGMENT}\\z", Regexp::IGNORECASE).freeze

      # 天狗的追加判定分隔符是 `,`（dice.js:182-196：`string.replace(/\]\[/g, ',')`
      # 后按 ',' 切），即 `[J,L]` 与 `[J][L]` **完全等价**（实测同结果）。
      # BCDice 父类只用 `][`，故本扩展同样只用 `][`——不引入第三种分隔符，
      # 免得同一类命令出现两种多段写法。报告 §5 申报（`[J,L]` 在 ASCII 侧不响应）。
      #
      # dice 部 `((?:(?:UH|[KENHU])?\d+,?)+)` 与父类 RE_JUDGE_DICEROLL 的
      # 分组 1 **逐字同源**，结构守卫逐字对比。
      RE_EX_DICEROLL = Regexp.new(
        "\\A((?:(?:UH|[KENHU])?\\d+,?)+)\\[(#{APPENDIX_ONE_FRAGMENT}" \
        "(?:\\]\\[#{APPENDIX_ONE_FRAGMENT})*)\\]\\z",
        Regexp::IGNORECASE
      ).freeze

      # ------------------------------------------------------------------
      # prefixes_pattern 覆写（T1.5 引入 / T1.6 泛化）—— **S 前缀与引擎暗骰标记冲突**
      # ------------------------------------------------------------------
      #
      # 故障现象（T1.5 实测）：`SEISEN9` 完全不响应，但直接调用
      # eval_game_system_specific_command("SEISEN9") 一切正常。
      #
      # 根因（逐步实证，docs/t1.5-report.md §3）：
      #   上游 base.rb:47 把前缀数组**原样拼进正则**：
      #     /^(S)?(UH|[KENHU]|SB|WS|WSE|NRS|NSRS|...|SEISEN)/i
      #   ① 可选的 `(S)?` 是 BCDice 的**暗骰标记**；命中即把命令首字符 S 剥掉
      #      （base.rb:254-255 `command = command[1..-1] if secret`）。
      #   ② 正则回溯优先让 `(S)?` 匹配掉 "SEISEN9" 的 S，剩下 "EISEN9"
      #      交给前缀组——而 `[KENHU]` 这个字面量被当成**字符类**
      #      （上游 register_prefix("[KENHU]") 的既有语义），其 `E` 匹配首字母 E。
      #   → 命令变成 "EISEN9"，本类正则全部失配 → 不响应。
      #
      # ⚠ **T1.6 泛化（本任务的 kimi 评审预警 2）**：
      #   T1.5 的覆写只把 **SEISEN 一个**前缀写进保护分支，是**打补丁**形态：
      #   每注册一个 S 开头的前缀都得记得再改这里，漏一个就复现同款 bug。
      #   T1.6 改为**自动保护所有 S/s 开头的已注册前缀**：
      #     S_PROTECTED_PREFIXES 在**首次调用 prefixes_pattern 时**从
      #     self.prefixes 动态收集。此时全部 register_prefix 已在类体内完成
      #     （时序铁律：注册必须全部在类体内），冻结后列表**恒定封闭**，
      #     不存在运行期漂移。
      #
      #   为什么要**按长度降序**排列：正则交替是「先到先得」，
      #   `SB|SBX` 会让 `SBX` 命中 `SB` 分支后剩 `X`（正是原 bug 的形态）。
      #   降序保证最长前缀先试。实测 SEISEN|SBX|SB 全部命中正确（§3 探针）。
      #
      #   副作用审计（逐条跑过，toml + engine_structure_test 结构断言）：
      #   - 只影响**以 S/s 开头**的前缀（T1.6 时 = SEISEN / SBX / SB）。
      #   - 这些前缀的**裸命令**行为不变（T1.5 探针已证明 SBX / SB 本来就
      #     正常——它们的正则组在 `(S)?` 回溯失败后仍能命中）。
      #   - `SS<任意 S 前缀>` 仍是合法暗骰命令（第二个 S 被 `(S)?` 吃掉）。
      #   - 非 S 前缀的暗骰形态（`SWSX`/`SNJI@3`/`SK6`）**完全不受影响**
      #     ——保护分支只加不加不减，回溯顺序对它们不变。
      #   - `[KENHU]` 字符类怪癖是上游既有行为（父类单独跑也如此），原样保留。
      #
      # 为什么不用 change_text（上游 NinjaSlayer.rb:82 的惯用法）？
      #   change_text 的输出会**再经 upcase**，且必须自己把命令改写成能通过
      #   prefixes_pattern 的形状；为一个前缀写字符串级手术，
      #   风险高于直接修正前缀正则本身。此处选择更小的作用面。
      #
      # 实现注意：父类 @prefixes_pattern 是**实例变量**而非类变量字典，
      #   但 Ruby 的类实例变量沿继承链各自独立，故这里直接重设本类的
      #   @prefixes_pattern 即可（父类的缓存不受影响）。
      #
      # R1 升级守卫：test/engine_structure_test.rb 断言本覆写的结构形态
      #   （通式而非硬编码前缀名），上游改 prefixes_pattern 签名/语义时当场红。
      def self.s_protected_prefixes
        # 首次调用即冻结（与上游 prefixes_pattern 同一时序铁律）。
        @s_protected_prefixes ||= prefixes.grep(/\A[Ss]/).sort_by { |p| [-p.length, p] }.freeze
      end

      def self.prefixes_pattern
        @prefixes_pattern ||= Regexp.new(
          "\\A(?:#{s_protected_prefixes.join('|')}|#{super.source})",
          Regexp::IGNORECASE
        ).freeze
      end

      # 父类实现的入口覆写（T1.1 / 计划 §15.5 V4 同形写法）。
      #
      # 先匹配本类新命令；未命中一律交给 `super`——父类实现内建
      # rescue→nil（语法错误即不响应），**不要复制父类方法体**。
      #
      # @param command [String]
      # @return [Result, String, nil]
      def eval_game_system_specific_command(command)
        result = proc_ex_command(command)
        return result unless result.nil?

        return super
      end

      private

      # 本扩展命令的分发。未命中返回 nil（交由 super 处理）。
      # 本方法自身不抛异常：出目越界的处理**逐命令不同**——
      # NSRS/SBX 越界当不响应（NSRS 无 datarange，理论上不可达）；
      # カルマロンダリング越界**钳制到 datarange 端点**（天狗语义，见
      # proc_karmarond 与铁律①）。任何一条都不允许 nil 文本漏进输出。
      # @param command [String]
      # @return [String, nil]
      def proc_ex_command(command)
        case command
        when RE_EX_NSRS
          return proc_nsrs(Regexp.last_match[1] || "A")
        when RE_EX_SIMPLE_TABLE
          return proc_ex_simple_table(EX_SIMPLE_TABLES.fetch(Regexp.last_match[1].upcase))
        when RE_KARMAROND
          # 两个互斥分支：带 @ 的用分组 2/3，不带 @ 的用分组 4（nil → "A"）
          return proc_karmarond(
            Regexp.last_match[1].upcase,
            (Regexp.last_match[2] || Regexp.last_match[4] || "A"),
            Regexp.last_match[3]
          )
        when RE_CHARAMAKE
          # 分组 2 非 nil = 定値表示（不掷骰）；nil = 裸命令（掷骰查表）
          return proc_chara_make(Regexp.last_match[1].upcase, Regexp.last_match[2])
        when RE_SEISEN
          return proc_seisen(Regexp.last_match[1].to_i)
        when RE_EX_DICEROLL
          # T1.6：倍率 / 记忆符形态的追加判定（父类正则不接受这些形态）
          return proc_ex_diceroll(Regexp.last_match)
        end

        return nil
      end

      # T1.6：倍率 / 记忆符形态的成功判定（`K6[J]` / `2B6>=4[>=5*2]` …）
      #
      # 与父类 proc_dice_2nd 的关系：**刻意不调用**。
      #   - 父类的 proc_dice_2nd 会调 proc_appendix，而 proc_appendix 的
      #     case 分支只认父类形态（S / C / 比较符），`[>=5*2]` 会被
      #     RE_COUNT_JUDGE 的 `([1-6]+\+?|[1-6])` 部分匹配后**整条落空**
      #     （无 else 分支 → 返回空串，追加判定静默消失）。
      #   - 父类的 RE_JUDGE_DICEROLL 根本匹配不到倍率/记忆符形态，
      #     所以它们压根到不了 proc_dice_2nd。
      #   → 故这里自带一份 dice 部循环，**只**处理本扩展的 appendix 形态，
      #     掷骰/成功数/输出骨架逐字照抄父类，保证玩家看到的格式不变。
      #
      # 输出格式与父类逐字同构：
      #   `(6B6>=2) ＞ 1,2,3,4,5,6 ＞ 成功数:5, ジツ暴走[=1]:1[1] \n`
      # 差异**只有** 追加计数那一项：倍率后的值 + 记忆符标签（见铁律③）。
      #
      # @param match [MatchData] RE_EX_DICEROLL 的匹配结果
      # @return [String, nil] 输出文本；倍率越界等非法形态返回 nil（不响应）
      def proc_ex_diceroll(match)
        dice_part = match[1]
        appendix_part = match[2]

        # ⚠ **先全量校验，后掷骰**：倍率越界 / 判定符非法这类形态必须
        #   在**消耗随机数之前**就判定为不响应。否则 `K6[>=5*101]` 会先掷 6 颗
        #   骰、再返回 nil——对玩家无害（结果被丢弃），但 toml 的异常系用例
        #   只能写空 rands，于是 runner 拿 1 颗骰喂一个要 6 颗的命令而抛
        #   "@rands is empty!"。且白掷骰是纯粹的资源浪费。
        #   （这是实测踩到的：异常系用例在 toml runner 里报 Error 而非 Assertion。）
        specs = appendix_part.split("][").map { |ap| parse_ex_appendix(ap) }
        return nil if specs.any?(&:nil?)

        output_text = ''
        total_success_num = 0

        # kimi P1：难度初始化在循环**外**、段内只升级不重置——与父类
        # proc_dice_2nd 逐字对齐（NinjaSlayer2.rb:247-253）。
        # （初版在循环内重置 → `K6,6[J]` 第二段退化成 6B6>=0 全员成功）
        difficulty = 0
        dice_part.split(",").each do |sub_command|
          /^(UH|[KENHU])?(\d+)$/i.match(sub_command)
          unless Regexp.last_match[1].nil?
            difficulty = DIFFICULTY_SYMBOL_TO_INTEGER.fetch(Regexp.last_match[1])
          end
          dice_num = Regexp.last_match[2].to_i

          # D6バラバラロール（与父类同一条命令字符串）
          roll_command = "#{dice_num}B6>=#{difficulty}"
          roll_result = BCDice::CommonCommand::BarabaraDice.eval(roll_command, self, @randomizer)

          output_text += "(#{roll_command}) ＞ #{roll_result.last_dice_list.join(',')} ＞ 成功数:#{roll_result.success_num}"

          specs.each do |spec|
            output_text += proc_ex_appendix(roll_result, spec)
          end
          output_text += " \n"

          total_success_num += roll_result.success_num
        end

        return Result.success(output_text) if total_success_num > 0

        return Result.failure(output_text)
      end

      # T1.6：单条追加判定的**解析 + 校验**（不掷骰、不需要 roll_result）
      #
      # 抽出来单独一层的原因见 proc_ex_diceroll 的「先全量校验」注释：
      # 判定合法性只需要语法与倍率上界，与骰子结果无关；而计数需要骰子。
      # 两层分开后，「非法即不响应且不掷骰」变成构造上的必然，而非靠调用顺序凑巧。
      #
      # @param ap_command [String] 单条 appendix（不含外层方括号）
      # @return [Hash, nil] 规范化后的 spec；形态非法返回 nil
      #   { op:, border:, cmp_op:, label:, op_label:, bairitsu:}
      def parse_ex_appendix(ap_command)
        m = RE_EX_APPENDIX_ONE.match(ap_command)
        return nil if m.nil?

        if (memo = m[4])
          # 记忆符：等价改写为 [=border]（标签不同，计数逻辑逐字相同）。
          # 任务书要求的「优先走等价改写」在此落地：没有第二套计数实现，
          # 只有一条边界 + 一个标签来源。
          #
          # border 从 i18n 读出来是 **Integer**，而比较分支的 y 是 **String**。
          # 两条路径必须统一成 String 之后才能共用 to_i，
          # 故此处显式 to_s（第一版漏了这一步 → NoMethodError on Integer）。
          # kimi P3d：RE_EX_APPENDIX_ONE 带 IGNORECASE，直调路径小写 memo（j/l）
          # 会撞 translate 的 raise:true → upcase 一行防御。
          memo_i18n = appendix_ex_memo(memo.upcase)
          border = memo_i18n.fetch(:border).to_s
          label = memo_i18n.fetch(:label)
          op = APPENDIX_MEMO_OPERATOR
          bairitsu = 1
        else
          op = m[1]
          label = nil
          border = m[2]
          # 倍率三分支逐字对齐天狗 Appendix.js:19（`strArray[4] != null && !isNaN(...)`）：
          #   无 `*` 段（nil）        → undefined → 默认 1（kimi P2：[=6] 等老形态）
          #   `*` 后空串             → Number('')===0 → 0（天狗同源）
          #   合法数字（含 1. / .5）  → to_f
          #   其余（如裸 `.`）        → isNaN → 默认 1（kimi P3a）
          raw_bairitsu = m[3]
          bairitsu = if raw_bairitsu.nil?
                       1
                     elsif raw_bairitsu.empty?
                       0
                     elsif raw_bairitsu.match?(/\A(?:\d+\.?\d*|\.\d+)\z/)
                       raw_bairitsu.to_f
                     else
                       1
                     end
          return nil if bairitsu > self.class.appendix_bairitsu_max
        end

        cmp_op = Normalize.comparison_operator(op)
        return nil if cmp_op.nil?

        op_label = appendix_ex_op_label(op)
        return nil if op_label.nil?

        {
          op: op,
          border: border,
          cmp_op: cmp_op,
          label: label.nil? ? APPENDIX_DEFAULT_LABEL : label,
          op_label: op_label,
          bairitsu: bairitsu
        }
      end

      # T1.6：单条追加判定的计数与输出（需要掷骰结果）
      #
      # @param roll_result [BCDice::CommonCommand::BarabaraDice::Node] 掷骰结果
      # @param spec [Hash] parse_ex_appendix 的产物
      # @return [String] 追加文本片段
      def proc_ex_appendix(roll_result, spec)
        # 计数（父类 proc_appendix 的单值分支逐字同构）：
        # 命中 = 满足条件的骰子集合。倍率形态只支持单值 y（正则已限定），
        # 集合判定 `665+` 仍走父类路径（super），天狗那边也不支持它。
        success_dice = roll_result.last_dice_list.select do |v|
          v.send(spec[:cmp_op], spec[:border].to_i)
        end

        # 天狗 dice.js:158-162：逐个命中累加倍率 → appSum = 命中数 × 倍率。
        # 用浮点累加以支持小数倍率（2.5 命中 2 颗 = 5，与天狗实测一致）。
        app_sum = 0.0
        success_dice.size.times { app_sum += spec[:bairitsu] }

        result = ", #{spec[:label]}[#{spec[:op_label]}#{spec[:border]}]:#{format_bairitsu(app_sum)}"
        result += "[#{success_dice.sort.reverse.join(',')}]" unless success_dice.empty?
        result
      end

      # 记忆符 → i18n 段（judge.APPENDIX_EX.{J,L}）
      #
      # 每次调用都重取（不缓存成类常量）：i18n 走 translate，受 @locale 影响，
      # 而 locale 是**实例**属性。常量在类定义期求值会锁死第一个 locale。
      #
      # ⚠ translate 返回的是 **Symbol 键**的 Hash（BCDice 的 Translate 把
      #   YAML 载入后 symbolize，见 translate.rb），不是 String 键。
      #   用 fetch("border") 会 KeyError —— 这是本方法第一版的真实翻车点。
      #
      # @param memo [String] "J" / "L"
      # @return [Hash] {border: Integer, label: String}
      def appendix_ex_memo(memo)
        translate("NinjaSlayer2Ex.judge.APPENDIX_EX.#{memo}")
      end

      # 天狗判定符 → 显示符号。
      #
      # 天狗 Appendix.js:17 把 `=` 规范成 `==`，输出前再 `replace(/==/g, '=')`
      # （dice.js:178）→ 统一显示 `=`。此处从 i18n 读映射表，
      # 而不是硬编码，保证 yml 里的表与实现同源（i18n_guard 会验）。
      #
      # @param op [String] "=" / ">=" / …
      # @return [String, nil] 显示符号；未登记的符号返回 nil
      def appendix_ex_op_label(op)
        normalized = op == "=" ? "==" : op
        translate("NinjaSlayer2Ex.judge.APPENDIX_EX.op_labels.#{normalized}")
      rescue StandardError
        nil
      end

      # 倍率后的计数值 → 输出字符串。
      #
      # 天狗那边是 JS 浮点（`appSum += 2.5` 得 7.5，`String(7.5)` → "7.5"）。
      # Ruby 侧同形：整数去小数点（7.0 → "7"），小数按 JS String 语义原样
      # （2.25 → "2.25"，5.5 → "5.5"）——先 round(4) 消除 0.1+0.2 类浮点噪声。
      # （kimi P3f：初版注释误写「小数保留恰好一位」，与 2.25 行为不符。）
      # 不能用 `app_sum.round.to_s`（会把 7.5 打成 8，与天狗不一致）。
      # 也不能用裸 `to_s`（浮点噪声），故 round(4) + truncate 判定。
      #
      # @param value [Float]
      # @return [String]
      def format_bairitsu(value)
        rounded = value.round(4)
        rounded == rounded.truncate ? rounded.to_i.to_s : rounded.to_s
      end

      # キャラメイク表を振る（6 表 + `@n` 定値表示）
      #
      # 两条互斥路径（见 T1.5 铁律③④）：
      #   ① fixed_n 非 nil → **定値表示**：不掷骰，直接 items[fixed_n - min_index]。
      #      天狗 `/fnd <表名>#<出目>`（discord_command/fnd.js）就是这条路，
      #      消息体只有正文（receiveFixedMessage 只 return '\n\n' + data[n]）。
      #      ASCII 侧本命令**必须**在正文前自报家门——天狗那条路径不带表名，
      #      Telegram 侧看到的是裸文本；本扩展输出 `<表名>(<出目>) ＞ <正文>`
      #      （与 SB@n / proc_nsrs 的呈现风格一致），便于在群里辨认是哪张表。
      #   ② fixed_n 为 nil → **掷骰查表**：roll_sum(times, sides)，
      #      items[sum - min_index]。
      #
      # 两者共用同一段 items 查找，故「越界 → 不响应」只写一次：
      #   - 掷骰路径理论不可达（1D6∈[1,6]、1D36∈[1,36]，与 items 长度恒等），
      #     仍保留守卫：yml 若被手工改短，守卫会让它安静地不响应，而不是
      #     产出 nil 文本或 IndexError 冒泡（父类 eval 有 rescue，但会吞成
      #     「语法错误」，掩盖真因）。
      #   - 定値路径可达（用户可打 @99），这才是守卫的主战场。
      #
      # ⚠ 与 proc_karmarond 的**故意**不同（评审预警 1）：
      #   不钳制、不显示（raw→clamped）标记——本批无 datarange（铁律①）。
      #
      # @param key [String] "NJI"/"NJS"/"NJN"/"NJK"/"NJC"/"NJB"
      # @param fixed_s [String, nil] 定値表示的出目原始串（nil = 掷骰）
      # @return [String, nil]
      def proc_chara_make(key, fixed_s)
        items = translate("NinjaSlayer2Ex.table.#{key}.items")

        if fixed_s.nil?
          spec = CHARAMAKE_DICE_TYPES[key]
          return nil if spec.nil?

          sum = @randomizer.roll_sum(spec[:times], spec[:sides])
          body = items[sum - CHARAMAKE_TABLE_MIN_INDEX]
          return nil if body.nil?

          return "#{chara_make_table_label(key)}(#{spec[:expr]}) ＞ (#{sum}) ＞ #{body}"
        end

        # 定値表示。天狗用字符串键直查（NJDiscordReply.js:115），此处已由
        # 正则挡掉前导零（铁律③），再补上界守卫：`@7`（1D6 表）/ `@37`（1D36 表）
        # 越界 → 不响应。
        index = fixed_s.to_i - CHARAMAKE_TABLE_MIN_INDEX
        body = items[index]
        return nil if body.nil?

        "#{chara_make_table_label(key)}(#{fixed_s.to_i}) ＞ #{body}"
      end

      # 聖戦判定を実行する（2D6、合計 <= DKK で成功）
      #
      # 天狗 wasshoi.js WasshoiDiceRoll#receiveDiceRoll:40-44 的忠实移植：
      #   const dice = new Dice('2d6'); dice.diceRoll();
      #   returnString = kind.judgeName + '!' + ' = ' + dice.toString()
      #                + ' = ' + dice.sum + '<=' + dkk + '  判定'
      #                + (dice.sum <= Number(dkk)) ? '成功！' + successMessage : '失敗';
      #   注意 `dice.toString()` 是 dice.js:109 的 `'(a+b)'` 形式（2 颗骰相加）。
      #
      # 返回 Result.success / Result.failure 让 bot 侧能按判定成败做提示；
      # 天狗侧只是纯字符串（无成败标志），本扩展是**无损放宽**——
      # 文本逐字一致，额外提供 success/failure 语义。
      #
      # @param dkk [Integer] DKK 难度数（正则保证为纯数字，无上界）
      # @return [Result]
      def proc_seisen(dkk)
        dice = @randomizer.roll_barabara(SEISEN_DICE_TIMES, SEISEN_DICE_SIDES)
        total = dice.sum()

        judge_name = translate("NinjaSlayer2Ex.judge.SEISEN.judge_name")
        success_message = translate("NinjaSlayer2Ex.judge.SEISEN.success_message")
        failure_word = translate("NinjaSlayer2Ex.judge.SEISEN.failure_word")

        # 成功语（`成功！`）来自 JSON 的 wasshoi.success_word，成功/失败二选一后
        # 只在成功分支追加 —— 对齐天狗 `'成功！' + successMessage` 的拼接顺序。
        success_word = translate("NinjaSlayer2Ex.judge.SEISEN.success_word")

        head = "#{judge_name}! = (#{dice.join('+')}) = #{total}<=#{dkk}  判定"
        if total <= dkk
          Result.success("#{head}#{success_word}#{success_message}")
        else
          Result.failure("#{head}#{failure_word}")
        end
      end

      # キャラメイク表的标签（不带骰型标记）。
      #
      # yml 的 name 形如 `初期ジツ系統(1D6) ＞ `，其中 `(1D6)` 是 DiceTable 的
      # 类型标记。与 nsrs_table_label / karmarond_table_label 同解：
      # 按第一个 '(' 截断，日文表名逐字来自 yml，不在代码里手写。
      #
      # @param key [String]
      # @return [String]
      def chara_make_table_label(key)
        translate("NinjaSlayer2Ex.table.#{key}.name")[/\A[^(]*/]
      end

      # カルマロンダリングを振る（5 派阀 × 4 骰型 + `@±x` 補正 + datarange 钳制）
      #
      # 忠实天狗 `,C,-1` → ASCII `_C@-1` 的语义链（SearchTableDiceroll.js
      # checkTable → diceroll.js → NJDiscordReply.js addTableOutput）：
      #   1. 掷骰（times/sides），加上骰型常量 bonus，再加用户補正；
      #   2. 钳制到 datarange（**先钳制**）；
      #   3. 按绝对出目索引 items[出目 - min_index]（min_index = 1）。
      #
      # ⚠ 与 proc_nsrs 的三处**故意**不同（kimi-code T1.3 评审预警逐条对应）：
      #   - 越界不返回 nil，而是取端点项（铁律①）；
      #   - 補正可以是负数（铁律②）；
      #   - 不需要「body.nil? 守卫」：钳制后索引必然落在 items 内。
      #
      # @param school [String] "KRS"/"KRZ"/"KRA"/"KRO"/"KRY"
      # @param dice_type_s [String] "A"/"B"/"C"/"D"
      # @param addition_s [String, nil] 補正值原始串（nil = 未指定 = 0）
      # @return [String, nil]
      def proc_karmarond(school, dice_type_s, addition_s)
        spec = KARMAROND_DICE_TYPES[school][dice_type_s]
        return nil if spec.nil?

        # 天狗 Math.floor(Number(x))：floor 语义、负数合法。
        # 未指定（nil）→ 0。天狗对非数字同样当 0，但我们的正则已限定
        # `@` 后必须是数字串，非数字形态直接不匹配 → 不响应（比天狗严格，
        # 避免把 `KRS_A@abc` 当成裸 KRS_A 静默掷骰）。
        # kimi P1-1：超长数字串 to_f → ±Infinity——**先**做有限性守卫再 floor
        # （Infinity.floor 本身抛 FloatDomainError，守卫放 floor 后则来不及）。
        # 非有限值按符号饱和到 ±10**6（语义等价于直接钳到 datarange 端点）。
        addition = 0
        if addition_s
          f = addition_s.to_f
          addition = f.finite? ? f.floor : (f.negative? ? -(10**6) : 10**6)
        end

        # 骰型常量 + 用户補正 一并计入绝对出目（天狗 diceStr 字符串拼接的等价物）
        sum = @randomizer.roll_sum(spec[:times], spec[:sides]) + spec[:bonus] + addition

        range = KARMAROND_DATARANGE[school]
        clamped = sum.clamp(range[:min], range[:max])
        # 钳制发生时明示：出目旁标注「(raw→clamped)（クランプ）」。
        # 天狗的钳制是**静默**的（NJDiscordReply.js 只取端点项、不提示）；
        # 本任务要求钳制可见，故加标注——语义不变，只是多告诉玩家一眼。
        # 同时把钳制后的实际索引值一并显示，便于对照 yml 逐条核验。
        face_mark = clamped == sum ? "(#{sum})" : "(#{sum}→#{clamped})（クランプ）"

        items = translate("NinjaSlayer2Ex.table.#{school}.items")
        body = items[clamped - KARMAROND_TABLE_MIN_INDEX]
        # 理论上钳制后不会越界（items 长度 == datarange 跨度），
        # 但 yml 若被手工改动长度会失配——兜底**按钳制方向取端点**而非 nil
        # （kimi P2-1：固定 items.first 在上溢时取错端点且掩盖失配；
        # 失配由 test/ledger_consistency_test.rb 常驻断言兜底）。
        if body.nil?
          body = clamped >= range[:max] ? items.last : items.first
        end

        "#{karmarond_table_label(school)}(#{spec[:expr]}) ＞ #{face_mark} ＞ #{body}"
      end

      # カルマロンダリング的标签（不带骰型标记）。
      #
      # yml 的 name 形如 `ソウカイヤカルマロンダリング(1D3) ＞ `，其中 `(1D3)`
      # 只是**默认骰型 a** 的标记（ledger roll_note），而 B/C/D 实际掷的是
      # 1D6 / 1D6+1 / 2D6，直接用 name 会标错（假信息）。
      # 与 nsrs_table_label 同解：按第一个 '(' 截断，日文表名逐字来自 yml。
      #
      # @param school [String]
      # @return [String]
      def karmarond_table_label(school)
        translate("NinjaSlayer2Ex.table.#{school}.name")[/\A[^(]*/]
      end

      # NSRS 発狂表を振る（忠实天狗纯表查询，无前置 NRS 判定）
      #
      # @param dice_type_s [String] "A" / "B" / "C" / "D"
      # @return [String, nil]
      def proc_nsrs(dice_type_s)
        spec = NSRS_DICE_TYPES[dice_type_s]
        return nil if spec.nil?

        # 補正込みの絶対出目。天狗は data[出目]（絶対）→ items[出目 - min_index]。
        # +1 骰型（C/D）不做任何额外偏移：sum 已含補正，直接按 min_index 索引。
        sum = @randomizer.roll_sum(spec[:times], spec[:sides]) + spec[:bonus]

        items = translate("NinjaSlayer2Ex.table.NSRS.items")
        body = items[sum - NSRS_TABLE_MIN_INDEX]
        # 越界（不应发生）当作不响应，避免 nil 文本进到输出里
        return nil if body.nil?

        "#{nsrs_table_label}(#{spec[:expr]}) ＞ (#{sum}) ＞ #{body}"
      end

      # NSRS 発狂表的标签（不带骰型标记）。
      #
      # yml 的 name 形如 `nsrs発狂(1D3) ＞ `，其中 `(1D3)` 只是**默认骰型 a**的标记
      # （ledger roll_note），而 +1 骰型实际掷的是 1D6+1 / 1D3+1，
      # 直接用 name 会把 C/D 的输出标成 1D3（假信息）。
      # 故按第一个 '(' 截断取标签，日文表名本身逐字来自 yml，不在代码里手写。
      # @return [String]
      def nsrs_table_label
        translate("NinjaSlayer2Ex.table.NSRS.name")[/\A[^(]*/]
      end

      # 天狗呈现版的 1d6 单骰型表を振る（SBX / WSX）。
      # 与父类 SB / WSE 的无指定出目分支同形：`DiceTable::Table.from_i18n(...).roll`。
      #
      # @param i18n_key [String]
      # @return [String]
      def proc_ex_simple_table(i18n_key)
        DiceTable::Table.from_i18n(i18n_key, @locale).roll(@randomizer).to_s
      end
    end
  end
end