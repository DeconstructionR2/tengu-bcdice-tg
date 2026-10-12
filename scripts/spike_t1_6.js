#!/usr/bin/env node
// ============================================================================
// T1.6 天狗侧真函数探针（只读 references/src 钉版快照，不改动任何文件）
//
// 目的：把「倍率 / [J] / [L]」的天狗语义从**源码推断**升级为**真函数实测**，
// 结论抄进 docs/t1.6-report.md §2。
//
// 跑法：node scripts/spike_t1_6.js
// 依赖：util.getRandomIntInclusive 被 dice.js 调用 → 需注入确定性随机
// ============================================================================

const path = require('path');
const fs = require('fs');
const SRC = path.join(__dirname, '..', 'references', 'src', 'TenguDiceBot', 'TenguDiceBot');

// references/src/ 是 gitignore 的上游钉版快照——新克隆里没有它（2026-10-12 三审）
if (!fs.existsSync(SRC)) {
  console.error('缺少 references/src/ 上游钉版快照（不入库）。请先按 docs/REFERENCES.md 顶部流程重取快照再运行本脚本。');
  process.exit(1);
}

// ---- 确定性随机注入（在 require 之前改 util 模块导出）----
const utilPath = path.join(SRC, 'util', 'util.js');
const util = require(utilPath);
let QUEUE = [];
let LAST_SIDES = 6;
util.getRandomIntInclusive = (min, max) => {
  LAST_SIDES = max;
  if (QUEUE.length === 0) return min;
  const v = QUEUE.shift();
  return Math.min(Math.max(v, min), max);
};

const Dice = require(path.join(SRC, 'classes', 'dice.js'));
const NJShortcutTranslator = require(path.join(SRC, 'tengu_dice', 'NJShortcutTranslator.js'));

function run(label, str, diceValues) {
  QUEUE = diceValues.slice();
  try {
    const d = new Dice(str);
    d.diceRoll();
    const apps = (d.appendixArray || []).map(a => ({
      string: a.string, option: a.option, border: a.border, bairitsu: a.bairitsu, comment: a.comment,
    }));
    console.log(`  ${label}`);
    console.log(`    input      : ${str}`);
    console.log(`    resArray   : [${d.resArray}]   sum=${d.sum}`);
    console.log(`    result     : ${d.result}`);
    console.log(`    appendix   : ${JSON.stringify(apps)}`);
  } catch (e) {
    console.log(`  ${label}`);
    console.log(`    input      : ${str}`);
    console.log(`    THROW      : ${e.message}`);
  }
}

console.log('='.repeat(78));
console.log('§A 倍率 [>=y*N]：命中数 × N');
console.log('='.repeat(78));
run('[>=5*2] 命中3颗5/6', '8d6>=4[>=5*2]', [1, 2, 3, 5, 6, 6, 1, 1]);
run('[>=5*2] 命中0颗', '8d6>=4[>=5*2]', [1, 2, 3, 4, 2, 1, 3, 4]);
run('[>=5*2] 命中1颗 → 1*2=2', '8d6>=4[>=5*2]', [5, 1, 2, 3, 4, 2, 1, 3]);
run('无倍率 [>=5] 命中3颗', '8d6>=4[>=5]', [1, 2, 3, 5, 6, 6, 1, 1]);

console.log('');
console.log('='.repeat(78));
console.log('§B 异常倍率（畸形形态的实际行为）');
console.log('='.repeat(78));
run('*0', '8d6>=4[>=5*0]', [5, 5, 6, 1, 2, 3, 4, 1]);
run('*x（字母）', '8d6>=4[>=5*x]', [5, 6, 1, 2, 3, 4, 1, 2]);
run('裸 *', '8d6>=4[>=5*]', [5, 6, 1, 2, 3, 4, 1, 2]);
run('*=（无数字）', '8d6>=4[>=5*=]', [5, 6, 1, 2, 3, 4, 1, 2]);
run('*2.5（小数）', '8d6>=4[>=5*2.5]', [5, 6, 1, 2, 3, 4, 1, 2]);
run('*（空倍率后跟 #注释）', '8d6>=4[>=5*#备注]', [5, 6, 1, 2, 3, 4, 1, 2]);

console.log('');
console.log('='.repeat(78));
console.log('§C 记忆符经 NJShortcutTranslator 的翻译（appTransration 实测）');
console.log('='.repeat(78));
['j', 'l', 's', 's5', 's6', 'c', 'J', 'L'].forEach((k) => {
  const out = NJShortcutTranslator.translateShortcut ? NJShortcutTranslator.translateShortcut(`K6[${k}]`) : '(no export)';
  console.log(`  K6[${k}] -> ${out}`);
});

console.log('');
console.log('='.repeat(78));
console.log('§D 记忆符翻译后的真函数语义（=1 / =6 等价性）');
console.log('='.repeat(78));
run('[J] 翻译后 =1', '8d6>=4[=1/ジツ暴走]', [1, 2, 3, 5, 6, 6, 1, 1]);
run('[L] 翻译后 =6', '8d6>=4[=6/LAN直結出目6数]', [1, 2, 3, 5, 6, 6, 1, 1]);
run('[=1] 对照', '8d6>=4[=1]', [1, 2, 3, 5, 6, 6, 1, 1]);
run('[=6] 对照', '8d6>=4[=6]', [1, 2, 3, 5, 6, 6, 1, 1]);

console.log('');
console.log('='.repeat(78));
console.log('§E 记忆符与倍率组合 / 多 appendix 共存');
console.log('='.repeat(78));
run('[J] + [>=5*2]', '8d6>=4[=1/ジツ暴走][>=5*2]', [1, 2, 3, 5, 6, 6, 1, 1]);
run('[J][L] 两记忆符', '8d6>=4[=1/ジツ暴走][=6/LAN直結出目6数]', [1, 2, 3, 5, 6, 6, 1, 1]);
run('逗号连缀 [J,L]', '8d6>=4[=1/ジツ暴走,=6/LAN直結出目6数]', [1, 2, 3, 5, 6, 6, 1, 1]);

console.log('');
console.log('='.repeat(78));
console.log('§F 记忆符 + 空白 / 大小写（与 BCDice 三关对照用）');
console.log('='.repeat(78));
run('空白 `8d6>=4 [=1]`', '8d6>=4 [=1]', [1, 2, 3, 5, 6, 6, 1, 1]);
run('小写 [=1]', '8d6>=4[=1]', [1, 2, 3, 5, 6, 6, 1, 1]);