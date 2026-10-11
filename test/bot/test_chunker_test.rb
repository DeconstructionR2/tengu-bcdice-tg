# frozen_string_literal: true

# ============================================================================
# test/bot/test_chunker_test.rb — 4096 切段边界（T2.1）
#
# 硬要求三条（缺一即验收不过）：
#   1. 不丢内容：split(t).join == t
#   2. 按**字符**数切，不按字节（中文/日文一字符 3 字节；按字节切会切得过碎，
#      用 byteslice 切还会切坏多字节字符产生乱码）
#   3. 优先按行边界切；无换行的超长行才硬切
# ============================================================================

require_relative "test_helper"

class TestChunker < Minitest::Test
  include BotTestHelper

  L = TelegramBot::Chunker::MAX_MESSAGE_LENGTH

  # --- 基本边界 -----------------------------------------------------------

  def test_short_text_is_single_segment
    segs = TelegramBot::Chunker.split("hello")
    assert_equal ["hello"], segs
  end

  def test_exactly_4096_is_one_segment
    text = "a" * L
    segs = TelegramBot::Chunker.split(text)
    assert_equal 1, segs.size
    assert_equal L, segs.first.length
    assert_equal text, segs.first
  end

  def test_4097_splits_into_two
    text = "a" * (L + 1)
    segs = TelegramBot::Chunker.split(text)
    assert_equal 2, segs.size
    assert_operator segs.first.length, :<=, L
    assert_operator segs.last.length, :<=, L
    assert_equal text, segs.join, "切段不得丢内容"
  end

  def test_4095_untouched
    text = "a" * (L - 1)
    assert_equal [text], TelegramBot::Chunker.split(text)
  end

  def test_empty_string
    # 空文本返回单元素空数组段（发送层可安全处理）
    segs = TelegramBot::Chunker.split("")
    assert_equal [""], segs
  end

  # --- 内容不丢 -----------------------------------------------------------

  def test_no_content_loss_across_many_segments
    text = (1..5000).map { |i| "line #{i}\n" }.join
    segs = TelegramBot::Chunker.split(text)
    assert_equal text, segs.join, "join 后必须逐字等于原文"
  end

  # --- 多字节：按字符不按字节 ----------------------------------------------

  def test_multibyte_uses_character_count_not_bytes
    # 日文一字符 3 字节。4096 字符的日文 = 12288 字节。
    # 若按字节切，会被切成 ~4 段且产生乱码；按字符切应是 2 段（4096 + 剩余）。
    text = "忍" * (L + 10)
    segs = TelegramBot::Chunker.split(text)

    assert_equal text, segs.join, "多字节文本切段后必须逐字还原（不得切坏字符）"
    segs.each do |s|
      assert_operator s.length, :<=, L, "每段字符数必须 ≤4096"
      assert_equal Encoding::UTF_8, s.encoding
      assert s.valid_encoding?, "切段不得产生非法 UTF-8（byteslice 切多字节的典型症状）"
    end
    assert_equal 2, segs.size

    # 关键鉴别：首段是满 4096 **字符**的日文 → 字节数 12288。
    # 若实现按字节切，首段字节数只会 ≈4096（即约 1365 字符）→ 本断言当场红。
    assert_equal L, segs.first.length, "首段应恰好装满 4096 个**字符**"
    assert_equal L * 3, segs.first.bytesize, "首段字节数 = 3× 字符数（证明按字符而非字节计）"
  end

  def test_mixed_cjk_ascii_no_mojibake
    text = "「ニンジャスレイヤー」ABC 123 サツバツ!! ＞ " * 200
    segs = TelegramBot::Chunker.split(text)
    assert_equal text, segs.join
    segs.each { |s| assert s.valid_encoding?, "混合文本切段出现非法编码" }
  end

  # --- 按行边界切 ---------------------------------------------------------

  def test_prefers_line_boundaries
    # 每行 100 字符，共 100 行（总 10000 > 4096）
    text = (1..100).map { "x" * 99 + "\n" }.join
    segs = TelegramBot::Chunker.split(text)

    assert_equal text, segs.join
    # 关键性质：**除了最后一段**，每段都以换行结尾 → 证明按行切而非硬切
    segs[0..-2].each_with_index do |s, i|
      assert s.end_with?("\n"), "第 #{i} 段应以换行结尾（按行边界切），实际尾部=#{s[-3..].inspect}"
    end
  end

  def test_line_boundary_respected_when_one_line_would_overflow
    # 两行各 3000 字符，第二行会让累计超过 4096 → 必须在第一行后切
    line1 = "a" * 3000
    line2 = "b" * 3000
    segs = TelegramBot::Chunker.split("#{line1}\n#{line2}\n")

    assert_equal 2, segs.size
    assert_equal "#{line1}\n", segs[0]
    assert_equal "#{line2}\n", segs[1]
  end

  # --- 超长行硬切 ---------------------------------------------------------

  def test_long_line_without_newlines_is_hard_split
    text = "z" * (L * 2 + 37)
    segs = TelegramBot::Chunker.split(text)

    assert_equal text, segs.join, "无换行长行硬切也不得丢内容"
    segs.each { |s| assert_operator s.length, :<=, L }
    assert_equal 3, segs.size
  end

  def test_hard_split_preserves_multibyte_characters
    # 无换行的超长日文行：必须硬切且不产生乱码
    text = "鬼" * (L + 5)
    segs = TelegramBot::Chunker.split(text)

    assert_equal text, segs.join
    segs.each do |s|
      assert s.valid_encoding?, "硬切不得切坏多字节字符"
      assert_operator s.length, :<=, L
    end
  end

  def test_overflowing_line_after_accumulated_content
    # 先攒一小段，再来一条超长行 → 小段必须先被冲出，且超长行硬切
    text = +("head\n" * 3) + ("x" * (L + 10))
    segs = TelegramBot::Chunker.split(text)

    assert_equal text, segs.join
    assert_operator segs.size, :>=, 3
    segs.each { |s| assert_operator s.length, :<=, L }
  end

  # --- 覆盖式断言：长度永不超限 + 内容永不失 ------------------------------

  def test_fuzz_never_exceeds_limit_and_never_loses_content
    srand(42) # 确定性

    40.times do |i|
      alphabet = [("a".."z").to_a, %w[忍 者 ス レ イ], %w[「 」 ＞ ！]].sample
      chars = alphabet.flatten
      text = Array.new(rand(1..9000)) { chars.sample }.join
      text = text.chars.each_slice(rand(1..200)).map(&:join).join("\n") if i.even?

      segs = TelegramBot::Chunker.split(text)
      segs.each { |s| assert_operator s.length, :<=, L, "case #{i}: 段长超限" }
      assert_equal text, segs.join, "case #{i}: 内容丢失"
    end
  end
end