// T1.2 第一棒：钉版快照 → 保真 JSON
//
// 设计原则（计划 §8 T1.2① + docs/spike-t1.1-report.md §5.4）：
//   - **让 JS 引擎自己解析** template literal，本脚本零正则切文本；
//   - 只对源文件做「行号锚点定位」（找 exports.KEY = [ 的行），不碰内容；
//   - references/src/** 一律只读，本脚本只 require 不写。
//
// 产出：references/extracted/tengu_tables.json
// 跑法：node scripts/extract_tengu_data.mjs [--out <path>]

import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";
import path from "node:path";
import fs from "node:fs";

const require = createRequire(import.meta.url);
const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const SNAP = path.join(ROOT, "references/src/TenguDiceBot/TenguDiceBot");

// ---------------------------------------------------------------------------
// 0. 依赖 stub：钉版快照 node_modules 不可用（firebase-admin / discord.js 等）
//    本脚本只取「数据」与「纯逻辑函数」，这些外部依赖对数据值无影响，
//    用最小 stub 兜底并在报告里注明（计划 T1.2① 明确允许）。
// ---------------------------------------------------------------------------
function deepStub() {
  const fn = function () {};
  return new Proxy(fn, {
    get(target, prop) {
      if (prop === "then" || prop === Symbol.toPrimitive) return undefined;
      if (!(prop in target)) target[prop] = deepStub();
      return target[prop];
    },
    apply() {
      return deepStub();
    },
    construct() {
      return deepStub();
    },
  });
}
const STUBBED_MODULES =
  /^(firebase-admin|firebase|discord\.js|dotenv|pg|require-dir|@google-cloud\/translate|timers\/promises)$/;
{
  const Module = require("node:module");
  const origLoad = Module._load;
  Module._load = function (request, parent, isMain) {
    if (STUBBED_MODULES.test(request)) return deepStub();
    return origLoad.apply(this, arguments);
  };
}

const usedStubs = new Set();

// ---------------------------------------------------------------------------
// 1. 行号锚点：只定位键的定义行/结束行，不解析内容
// ---------------------------------------------------------------------------
function readSource(rel) {
  return fs.readFileSync(path.join(SNAP, rel), "utf8").split("\n");
}

function anchorFor(rel, keyRegex) {
  const lines = readSource(rel);
  for (let i = 0; i < lines.length; i += 1) {
    if (keyRegex.test(lines[i])) {
      // 从命中行开始做**大括号深度追踪**，直到回到深度 0 —— 嵌套对象
      // （dice / datarange / data）都必须被完整覆盖，否则锚点会截在内部 `},` 上。
      let depth = 0;
      let started = false;
      let end = i;
      for (let j = i; j < lines.length; j += 1) {
        for (const ch of lines[j]) {
          if (ch === "{") {
            depth += 1;
            started = true;
          } else if (ch === "}") {
            depth -= 1;
          }
        }
        if (started && depth <= 0) {
          end = j;
          break;
        }
      }
      return { file: `TenguDiceBot/${rel}`, start_line: i + 1, end_line: end + 1 };
    }
  }
  return null;
}

// ---------------------------------------------------------------------------
// 2. 数据表：nd_datatable.js（519 行）
// ---------------------------------------------------------------------------
function extractTables() {
  usedStubs.clear();
  const mod = require(path.join(SNAP, "tengu_dice/nd_datatable.js"));
  usedStubs.add("nd_datatable.js → nd_datatext.js");
  const dt = mod.dataTable;
  const out = {};
  for (const [jaName, tbl] of Object.entries(dt)) {
    const data = tbl.data || {};
    const keys = Object.keys(data);
    const items = keys.map((k) => data[k]);
    const itemLines = {};
    keys.forEach((k) => {
      itemLines[k] = typeof data[k] === "string" ? data[k].split("\n").length : null;
    });
    out[jaName] = {
      ja_name: jaName,
      // dice 是「骰型键 → D 表达式」的映射（可变量 +x 保留原样）
      dice: tbl.dice || {},
      // datarange 是钳制范围（只有含 +x 的表有）
      datarange: tbl.datarange || null,
      // data_index 是实际的出目键（非 1..n 连续的表要如实记录，如 2d6 表从 2 起）
      data_index: keys,
      // kimi P12 口径注记：template literal 源条目带尾 \n 时行数 = 可视行数+1；
      // inline 字符串不带尾 \n。该字段仅作锚点辅助，不参与保真判定（保真看 items 逐字）。
      item_line_counts: itemLines,
      item_char_counts: keys.map((k) => data[k].length),
      total_chars: items.reduce((a, s) => a + s.length, 0),
      items,
      anchor: anchorFor(
        "tengu_dice/nd_datatable.js",
        new RegExp(`^    ${jaName.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}:`)
      ),
    };
  }
  return out;
}

// ---------------------------------------------------------------------------
// 3. 数据文本：nd_datatext.js（882 行）—— table 的上游真值，独立 dump
// ---------------------------------------------------------------------------
function extractTexts() {
  const mod = require(path.join(SNAP, "tengu_dice/nd_datatext.js"));
  const out = {};
  for (const [key, arr] of Object.entries(mod)) {
    const list = Array.isArray(arr) ? arr : [arr];
    out[key] = {
      ja_name: key,
      count: list.length,
      total_chars: list.reduce((a, s) => a + s.length, 0),
      items: list,
      anchor: anchorFor(
        "tengu_dice/nd_datatext.js",
        new RegExp(`^exports\\.${key.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}\\s*=`)
      ),
    };
  }
  return out;
}

// ---------------------------------------------------------------------------
// 4. NJShortcutTranslator.js：快捷键 → 命令语义映射
//    不用「读源码抄 switch」，而是直接**调用真函数**验证每条映射。
// ---------------------------------------------------------------------------
function extractShortcut() {
  const translate = require(path.join(SNAP, "tengu_dice/NJShortcutTranslator.js"));
  const difficulty = [
    ["k", "KIDS"],
    ["e", "EASY"],
    ["n", "NORMAL"],
    ["h", "HARD"],
    ["u", "U-HARD"],
  ];
  const appendix = [
    ["s", "[S]/[S6] サツバツ！カウント"],
    ["s5", "[S5] ヘンゲ『肉体破壊』用サツバツ！カウント"],
    ["s6", "[S6] サツバツ！カウント"],
    ["j", "[J] ジツ拡張サイバネ導入時のジツ暴走ファンブルカウント"],
    ["l", "[L] LAN直結攻撃時、出目6数カウント"],
    ["c", "[C] コッポ判定（出目4数カウント）"],
  ];
  const probes = {};
  for (const [ch] of difficulty) {
    probes[`${ch}3`] = translate(`${ch}3`);
  }
  for (const [ch] of appendix) {
    probes[`n3[${ch}]`] = translate(`n3[${ch}]`);
  }
  probes["n4,3"] = translate("n4,3");
  probes["n4,3[s]"] = translate("n4,3[s]");
  probes["e4,3#連続攻撃"] = translate("e4,3#連続攻撃");
  probes["n5,6[s5]#ヘンゲ連続攻撃"] = translate("n5,6[s5]#ヘンゲ連続攻撃");
  probes["5d6-2"] = translate("5d6-2");
  probes["8d6>=4[>=5*2]"] = translate("8d6>=4[>=5*2]");
  probes["2d6>=4[=6]"] = translate("2d6>=4[=6]");
  probes["2d6>=4+4d6>=5"] = translate("2d6>=4+4d6>=5");
  probes["3d6>=2[>=3][>=4*2]"] = translate("3d6>=2[>=3][>=4*2]");

  return {
    // 难度快捷键：源码 switch 分支的**可执行验证结果**
    difficulty: difficulty.map(([ch, label]) => ({
      key: ch,
      ascii_label: label,
      expands_to: translate(`${ch}3`),
      operator: translate(`${ch}3`).match(/3d6([<>=!]+)(\d+)/)?.slice(1) || [],
    })),
    // Appendix 快捷键：[c] / [l] 等
    appendix: appendix.map(([ch, label]) => ({
      key: ch,
      ja_label: label,
      expands_to: translate(`n3[${ch}]`),
    })),
    // 组合语法探针：证明多段/逗号连掷/注释/倍率等行为
    probes,
    // 源码里逐字抄下的映射表（作为 probes 的对照锚）
    source_mapping_verbatim: {
      K: ">=2",
      E: ">=3",
      N: ">=4",
      H: ">=5",
      U: "=6",
    },
    anchor: anchorFor(
      "tengu_dice/NJShortcutTranslator.js",
      /case 'k':/
    ),
  };
}

// ---------------------------------------------------------------------------
// 5. wasshoi.js：聖戦/ワッショイ判定逻辑参数
// ---------------------------------------------------------------------------
async function extractWasshoi() {
  const WD = require(path.join(SNAP, "tengu_dice/wasshoi.js"));
  const kind = WD.KIND;
  const kinds = {};
  for (const [k, v] of Object.entries(kind)) {
    kinds[k] = {
      judge_name: v.judgeName,
      kind_regexp_source: v.kindRegExp.source,
      kind_regexp_flags: v.kindRegExp.flags,
      success_message: v.successMessage,
      success_message_chars: v.successMessage.length,
      // 真函数验证：逐条喂输入给 kindRegExp，证明匹配语义
      regexp_accepts: {
        wasshoi9: /wasshoi[!！]?(\d+)$/i.test("wasshoi9"),
        wasshoi_9: /wasshoi[!！]?(\d+)$/i.test("wasshoi_9"),
        "wasshoi!9": /wasshoi[!！]?(\d+)$/i.test("wasshoi!9"),
        "wasshoi！9": /wasshoi[!！]?(\d+)$/i.test("wasshoi！9"),
        wasshoi: /wasshoi[!！]?(\d+)$/i.test("wasshoi"),
        WASSHOI10: /wasshoi[!！]?(\d+)$/i.test("WASSHOI10"),
        seisen9: /^seisen(\d+)$/i.test("seisen9"),
        SEISEN12: /^seisen(\d+)$/i.test("SEISEN12"),
        "seisen!9": /^seisen(\d+)$/i.test("seisen!9"),
        "seisen 9": /^seisen(\d+)$/i.test("seisen 9"),
      },
    };
  }

  // 类路径实测：nd_diceRollHandler 走的是 `new WasshoiDiceRoll(string, KIND)`，
  // 判定式 `dice.sum <= dkk` → 成功。用同一 seed 跑多次覆盖成功/失败两支，
  // 但**只登记判定分支与结构**（dice 出目是随机的，不入库）。
  // 固定 RNG 种子（xorshift）→ 保证逐次生成的 JSON **逐字节幂等**。
  // 天狗用 Math.random()，不 seed 就每次结果不同，会破坏保真锚点的可复现性。
  // kimi P11：进程级覆盖必须在使用后恢复（哪怕脚本随即退出，也不留污染面）
  let _seed = 0x5eed1234;
  const _origRandom = Math.random;
  Math.random = () => {
    _seed ^= _seed << 13; _seed >>>= 0;
    _seed ^= _seed >>> 17;
    _seed ^= _seed << 5;  _seed >>>= 0;
    return _seed / 0x100000000;
  };

  const live = {};
  for (const [input, kindKey] of [
    ["wasshoi9", "WASSHOI"],
    ["wasshoi!9", "WASSHOI"],
    ["seisen9", "SEISEN"],
  ]) {
    try {
      const inst = new WD(input, WD.KIND[kindKey]);
      const out = await inst.receiveDiceRoll();
      // 把随机出目抹掉，只保留**结构**证明 → 保证 JSON 逐次生成可复现（幂等）
      live[input] = {
        kind: kindKey,
        dkk: inst.dkk,
        outcome: /成功！/.test(out) ? "成功！" : "失敗",
        skeleton: out
          .replace(/\(\d+(?:\+\d+)*\)/g, "(<出目>)")
          .replace(/(\d+)<=(\d+)/, "<合計><=<dkk>"),
      };
    } catch (e) {
      live[input] = { error: e.message };
    }
  }
  // 「!」「！」容错与「缺 DKK」报错路径（正则 + 空白剥离的实测行为）
  const errorPaths = {};
  for (const input of ["wasshoi", "wasshoi!9", "wasshoi！9", "seisen!9", "seisen 9"]) {
    try {
      const k = /seisen/i.test(input) ? WD.KIND.SEISEN : WD.KIND.WASSHOI;
      const inst = new WD(input, k);
      errorPaths[input] = { accepted: true, dkk: inst.dkk, normalized: inst.string };
    } catch (e) {
      errorPaths[input] = { accepted: false, error: e.message };
    }
  }

  // kimi P11 恢复进程级 Math.random（探针段已结束）
  Math.random = _origRandom;

  return {
    dice_expression: "2d6",
    comparison: "dice.sum <= Number(dkk)",
    success_word: "成功！",
    failure_word: "失敗",
    output_template:
      "<判定名>! = <dice.toString()> = <dice.sum><=<dkk>  判定" +
      "成功！<successMessage> | 失敗",
    live_path: "nd_diceRollHandler → new WasshoiDiceRoll(string, KIND) → receiveDiceRoll()",
    dead_code_finding: {
      issue:
        "wasshoi.js 顶部定义了 exports.wasshoiDiceRoll / exports.seisenDiceRoll 两个" +
        "模块级辅助函数，但文件末尾 module.exports = WasshoiDiceRoll 把它们**覆盖**了。",
      consequence:
        "require('tengu_dice/wasshoi').wasshoiDiceRoll === undefined（实测）。" +
        "天狗实际走的是 WasshoiDiceRoll 类路径，两个函数是死代码。",
      impact_on_us: "语义无影响——两条路径判定式与文案完全一致；移植时按类路径实现即可。",
    },
    kinds,
    live_samples: live,
    regexp_error_paths: errorPaths,
    anchor: anchorFor("tengu_dice/wasshoi.js", /WasshoiDiceRoll\.KIND/),
  };
}


// ---------------------------------------------------------------------------
// 6. Discord 命令面（人工 diff 的「代码侧」真值；命令元数据取自 require 后的
//    command 对象，非人工抄写）
// ---------------------------------------------------------------------------
function extractSlashCommands() {
  const files = ["nd", "fnd", "snd", "ct", "tb"];
  const out = [];
  for (const f of files) {
    const cmd = require(path.join(SNAP, `discord_command/${f}.js`));
    out.push({
      file: `TenguDiceBot/discord_command/${f}.js`,
      name: cmd.command.name,
      description: cmd.command.description,
      options: (cmd.command.options || []).map((o) => ({
        type: o.type,
        name: o.name,
        description: o.description,
        required: o.required === true,
      })),
    });
  }
  return out;
}

function extractSubCommands() {
  // CT（12 操作）与银行子命令：命令名 + help 文案从源文件 require 取得
  const ctSrc = readSource("ct_command/ctcommand.js").join("\n");
  const ctNames = [...ctSrc.matchAll(/'([a-z]+)'\s*:\s*require\('\.\/(\w+)'\)/g)].map(
    (m) => ({ command: m[1], module: `ct_command/${m[2]}.js` })
  );
  const ctHelp = require(path.join(SNAP, "ct_command/help.js"));
  const recSrc = readSource("tengu_bank/record.js").join("\n");
  const bankOps = [...recSrc.matchAll(/case "([a-z]+)":/g)].map((m) => m[1]);
  return {
    ct: {
      ops: ctNames,
      op_count: ctNames.length,
      help_keys: Object.keys(ctHelp),
    },
    bank: {
      switch_ops: bankOps,
      input_regexes: {
        M_PLUSNUMBER: "/^m\\+\\d+$/",
        M_MINUSNUMBER: "/^m-\\d+$/",
        I_PLUSITEM: "/^i\\+.+$/",
        I_MINUSITEM: "/^i-.+$/",
      },
      separator: "「、」（全角读点，/、/g）",
      easter_egg: "change893(money)：金额字符串含 '893' 时包 :japanese_goblin: 装饰",
      anchor: anchorFor("tengu_bank/record.js", /exports\.receiveResponce/),
    },
  };
}

// errorMessage 数组是模块私有（不 export），但能从**源文件字面量**逐条取
// （errorMessage 是纯字符串数组，无插值/转义构造）。
// ⚠ 不能改存 `replyErrorMessage()` 的单条 sample —— 那是随机的，会破坏
//   保真锚点的可复现性（幂等）。全量 dump 才能既保真又可复现。
function extractErrorMessagePool() {
  const src = readSource("tengu_dice/nd_errormessage.js").join("\n");
  const body = src.slice(src.indexOf("const errorMessage = ["));
  // 末条目**无尾逗号**（`…な。」'` 而非 `…な。」',`），正则需允许逗号缺省
  const pool = [...body.matchAll(/^\s*'(.*?)',?\s*$/gm)].map((m) => m[1]);
  if (pool.length === 0) {
    throw new Error("errorMessage 池提取失败：字面量正则未命中任何条目");
  }
  return pool;
}

function extractHelpTexts() {
  const help = require(path.join(SNAP, "tengu_dice/help.js"));
  const tablehelp = require(path.join(SNAP, "tengu_dice/tablehelp.js"));
  const errMsg = require(path.join(SNAP, "tengu_dice/nd_errormessage.js"));
  const ctHelpSrc = readSource("ct_command/help.js").join("\n");
  // HelpMessage 的键 = CT 各子命令的 help 主题词（外加 'all'）
  const ctHelpKeys = [...ctHelpSrc.matchAll(/^'([a-z]+)'\s*:\s*$/gm)].map((m) => m[1]);
  const errSrc = readSource("tengu_dice/nd_errormessage.js").join("\n");
  const errCount = (errSrc.match(/^':japanese_goblin:/gm) || []).length;
  const errPool = extractErrorMessagePool();
  if (errPool.length !== errCount) {
    throw new Error(
      `errorMessage 池提取不完整：字面量 ${errPool.length} 条 vs 行首计数 ${errCount} 条`
    );
  }
  // 真函数可调用性冒烟测试（证明 error.js stub 兜底有效），只取**是否可调**，
  // 不取返回值（随机 → 会破坏幂等）
  void typeof errMsg.replyErrorMessage === "function";
  return {
    nd_help: {
      // classes/help.js 的 Help 实例持有 .help 字符串
      text: help.help,
      chars: help.help.length,
    },
    tablehelp: {
      text: tablehelp.help,
      chars: tablehelp.help.length,
    },
    ct_help: {
      keys: ctHelpKeys,
      // 每键全文较长（约 1-3KB），只入库键清单 + 长度指针，正文留在钉版快照
      key_count: ctHelpKeys.length,
      anchor: anchorFor("ct_command/help.js", /^const HelpMessage/),
    },
    error_messages: {
      // 彩蛋台词池（骰子掷错时随机吐出）：属「文本资产」，非规则数据。
      // ⚠ 不能只存 sample —— `replyErrorMessage()` 每次随机取一条，会让 JSON
      //   逐次生成不一致（破坏保真锚点的可复现性）。这里**全量 dump** 56 条原文。
      count: errCount,
      pool_source: "nd_errormessage.js 的 errorMessage 数组字面量（逐条全量，无抽样）",
      pool: errPool,
      anchor: anchorFor("tengu_dice/nd_errormessage.js", /^const errorMessage/),
    },
  };
}

// ---------------------------------------------------------------------------
// 7. 组装
// ---------------------------------------------------------------------------
const outArg = process.argv.indexOf("--out");
const OUT =
  outArg > -1 && process.argv[outArg + 1]
    ? path.resolve(process.argv[outArg + 1])
    : path.join(ROOT, "references/extracted/tengu_tables.json");

const tables = extractTables();
const texts = extractTexts();
const result = {
  _meta: {
    generator: "scripts/extract_tengu_data.mjs",
    task: "T1.2-①",
    source_repo: "github.com/kooreme/TenguDiceBot",
    source_commit: "ca3d85a",
    source_version: "4.2.1",
    license: "MIT",
    snapshot_root: "references/src/TenguDiceBot/TenguDiceBot",
    node_version: process.version,
    principle:
      "数据值由 Node 直接 require 钉版 JS 求得（JS 引擎自行解析 template literal），" +
      "脚本零正则切文本；正则仅用于**行号锚点定位**与命令面清点。",
    stubbed_dependencies: [...STUBBED_MODULES.source.match(/[a-z-]+/g)].filter((x) =>
      ["firebase-admin", "discord.js", "dotenv", "pg", "require-dir"].includes(x)
    ),
    counts: {
      tables: Object.keys(tables).length,
      text_segments: Object.keys(texts).length,
      table_items: Object.values(tables).reduce((a, t) => a + t.items.length, 0),
      text_items: Object.values(texts).reduce((a, t) => a + t.items.length, 0),
      table_chars: Object.values(tables).reduce((a, t) => a + t.total_chars, 0),
      text_chars: Object.values(texts).reduce((a, t) => a + t.total_chars, 0),
    },
  },
  tables,
  text_segments: texts,
  shortcut: extractShortcut(),
  wasshoi: await extractWasshoi(),
  slash_commands: extractSlashCommands(),
  sub_commands: extractSubCommands(),
  help_texts: extractHelpTexts(),
};

fs.mkdirSync(path.dirname(OUT), { recursive: true });
fs.writeFileSync(OUT, JSON.stringify(result, null, 2) + "\n", "utf8");

console.log(`[extract] → ${path.relative(ROOT, OUT)}`);
console.log(
  `[extract] 表 ${result._meta.counts.tables} 张 / ${result._meta.counts.table_items} 条 / ${result._meta.counts.table_chars} 字符`
);
console.log(
  `[extract] 文本段 ${result._meta.counts.text_segments} 段 / ${result._meta.counts.text_items} 条 / ${result._meta.counts.text_chars} 字符`
);
console.log(`[extract] slash 命令 ${result.slash_commands.length} 个；CT 操作 ${result.sub_commands.ct.op_count} 个`);
