# frozen_string_literal: true

# ============================================================================
# 声明式文本改写映射（2026-10-11 用户拍板）
#
# 用途：yml 生成期对天狗原文做的**唯一**机械改写，全部在此声明（可审计）。
# 纪律：references/extracted/tengu_tables.json 锚点保持逐字节保真不动；
#       改写只在生成期发生；自检/三方校验一律按 transform(JSON) 比对。
#
# 当前映射：
#   [拍板 B] 表文本内嵌命令引用 ASCII 化（全量扫描实证真实引用仅 2 处；
#            『サツバツ！』等书名号内为规则散文逐字保留，diehardtales.com 链接不动）
#   [拍板 C] Discord 表情码 `:japanese_goblin:` 删除（全量扫描：唯一表情码；
#            Telegram 上只能显示为裸文字。位置形态：行首带尾随空格 / 行尾带前导空格）
#
# 使用者：scripts/json_to_i18n.rb（生成 + 自检）、scripts/gen_table_toml.rb（三方校验）。
# ============================================================================

# 顺序敏感：先长后短、先带邻空格的形态，最后裸码兜底。
TEXT_REWRITE_PAIRS = [
  ["/nd NSRS発狂,d", "NSRS_D"],
  ["/fnd 初期ジツ系統#n", "NJI@n"],
  [":japanese_goblin: ", ""],
  [" :japanese_goblin:", ""],
  [":japanese_goblin:", ""],
].freeze

# 对单段文本应用全部声明式改写
def rewrite_text(s)
  TEXT_REWRITE_PAIRS.reduce(s) { |acc, (from, to)| acc.gsub(from, to) }
end

# 对表 items 数组逐条应用
def rewrite_items(items)
  items.map { |t| rewrite_text(t) }
end
