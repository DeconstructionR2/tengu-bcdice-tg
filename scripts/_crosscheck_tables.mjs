#!/usr/bin/env node
// T1.2 辅助核对脚本（不入库产物，仅供人工复核台账取证用）
// 逐字比对：天狗表 vs 上游 BCDice NinjaSlayer2 i18n / NinjaSlayer 内联表
// 用法：node scripts/_crosscheck_tables.mjs

import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";
import path from "node:path";
import fs from "node:fs";

const require = createRequire(import.meta.url);
const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");

// references/src/ 是 gitignore 的上游钉版快照——新克隆里没有它（2026-10-12 三审）
if (!fs.existsSync(path.join(ROOT, "references/src"))) {
  console.error("缺少 references/src/ 上游钉版快照（不入库）。请先按 docs/REFERENCES.md 顶部流程重取快照再运行本脚本。");
  process.exit(1);
}

const d = JSON.parse(
  fs.readFileSync(path.join(ROOT, "references/extracted/tengu_tables.json"), "utf8")
);

// 上游 NinjaSlayer2 i18n（只取 table.<KEY>.items 的双引号数组块，
//   YAML 双重引号转义需按 YAML 规范还原：\n \t \" \\ ）
function upstreamTable(file, key) {
  const yml = fs.readFileSync(path.join(ROOT, file), "utf8").split("\n");
  const start = yml.findIndex((l) => l.trim() === `${key}:`);
  if (start < 0) return null;
  // items: 之后到下一个同缩进 key（6 空格 + 非 "- " 开头的行）为止
  const itemsAt = yml.findIndex((l, i) => i > start && /^\s+items:\s*$/.test(l));
  if (itemsAt < 0) return null;
  const out = [];
  for (let i = itemsAt + 1; i < yml.length; i += 1) {
    const m = yml[i].match(/^\s*- "(.*)"\s*$/);
    if (!m) {
      if (/^\s{6}\S/.test(yml[i])) break; // 下一个表键
      if (/^\s*$/.test(yml[i])) continue;
      break;
    }
    out.push(unescapeYamlDouble(m[1]));
  }
  return out;
}

function unescapeYamlDouble(s) {
  let out = "";
  for (let i = 0; i < s.length; i += 1) {
    if (s[i] === "\\" && i + 1 < s.length) {
      const c = s[i + 1];
      if (c === "n") { out += "\n"; i += 1; continue; }
      if (c === "t") { out += "\t"; i += 1; continue; }
      if (c === '"') { out += '"'; i += 1; continue; }
      if (c === "\\") { out += "\\"; i += 1; continue; }
    }
    out += s[i];
  }
  return out;
}

// 上游 NinjaSlayer 1版内联 SATSUBATSU_TABLE（Ruby 单引号数组，行尾 ',' 或 ',.freeze'）
function upstreamNsSatsubatsu() {
  const rb = fs
    .readFileSync(
      path.join(ROOT, "references/src/BCDice/lib/bcdice/game_system/NinjaSlayer.rb"),
      "utf8"
    )
    .split("\n");
  const start = rb.findIndex((l) => l.includes("SATSUBATSU_TABLE = ["));
  const out = [];
  for (let i = start + 1; i < rb.length; i += 1) {
    const m = rb[i].match(/^\s+'(.*)',?\.freeze\s*$/);
    if (m) { out.push(m[1]); continue; }
    const m2 = rb[i].match(/^\s+'(.*)',?\s*$/);
    if (m2) { out.push(m2[1]); continue; }
    if (/^\s+\]\.freeze/.test(rb[i])) break;
  }
  return out;
}

// 三级归一化，逐级剥掉「呈现层差异」，逼近「语义是否同源」：
//   L0 逐字
//   L1 剥 markdown 强调 ** 与全角/半角数字、全角空格差异
//   L2 再剥天狗独有的**加粗摘要标题行**（`XXX：『…』` 形式，位于条目首行）
// L2 相同即判定「语义同源、仅呈现差异」
const FW_DIGIT = "０１２３４５６７８９";
const fw2half = (s) =>
  s
    .replace(/＋/g, "+")
    .replace(/－/g, "-")
    // kimi P5：`ー→-` 全局替换误伤日文长音（ユーザー→ユ-ザ-），已删除
    .split("")
    .map((c) => {
      const i = FW_DIGIT.indexOf(c);
      return i >= 0 ? String(i) : c;
    })
    .join("");

const norm1 = (s) =>
  fw2half(s)
    .replace(/\*\*/g, "")
    .replace(/　/g, " ")
    .replace(/–/g, "-")
    // kimi P4：剥天狗摘要标题尾的全角冒号（`标题`：\n本体 vs 上游 `标题` \n本体）
    .replace(/：/g, "")
    .replace(/\s+/g, "");

const norm2 = (s) => {
  const t = norm1(s);
  // 天狗摘要在条目开头，形如 `腹部の痛打：『…』`（『』可省略），其后再跟正文本体
  // kimi P3：初版正则写死双全角冒号 `：：` 永不命中（死代码），已修为单 `：` 并放宽『』
  const m = t.match(/^[^『「\n]{2,30}：(『[^』]*』)?/);
  if (m) return t.slice(m[0].length);
  return t;
};

function cmp(label, a, b) {
  console.log(`\n########## ${label} ##########`);
  if (!a || !b) {
    console.log("  (一方为空)");
    return { label, total: Math.max(a?.length ?? 0, b?.length ?? 0), matched: 0 };
  }
  console.log(`  条目数: 天狗=${a.length} 上游=${b.length}`);
  let l0 = 0;
  let l1 = 0;
  let l2 = 0;
  const n = Math.max(a.length, b.length);
  for (let i = 0; i < n; i += 1) {
    const x = a[i] ?? "";
    const y = b[i] ?? "";
    if (x === y) l0 += 1;
    if (norm1(x) === norm1(y)) l1 += 1;
    if (norm2(x) === norm2(y)) l2 += 1;
    if (norm2(x) !== norm2(y)) {
      console.log(`  --- 第 ${i + 1} 项：L2 语义仍不同 ---`);
      console.log(`    天狗: ${JSON.stringify(x.slice(0, 160))}`);
      console.log(`    上游: ${JSON.stringify(y.slice(0, 160))}`);
    }
  }
  console.log(`  L0 逐字 ${l0}/${n} | L1 去呈现差异 ${l1}/${n} | L2 再去摘要标题 ${l2}/${n}`);
  return {
    label,
    items_tengu: a.length,
    items_upstream: b.length,
    L0: l0,
    L1: l1,
    L2: l2,
    total: n,
    semantic_same: l2 === n,
  };
}

const up2 = (k) => upstreamTable("references/src/BCDice/i18n/NinjaSlayer2/ja_jp.yml", k);
const results = [];

results.push(cmp("天狗[サツバツ] vs 上游2版 NinjaSlayer2.table.SATSUBATSU", d.tables["サツバツ"].items, up2("SATSUBATSU")));
results.push(cmp("天狗[wasshoiエントリー] vs 上游2版 NinjaSlayer2.table.WASSHOI", d.tables["wasshoiエントリー"].items, up2("WASSHOI")));
results.push(cmp("天狗[nrs発狂] vs 上游2版 NinjaSlayer2.table.NRS", d.tables["nrs発狂"].items, up2("NRS")));
results.push(cmp("天狗[サツバツ_1] vs 上游1版 NinjaSlayer.SATSUBATSU_TABLE(内联)", d.tables["サツバツ_1"].items, upstreamNsSatsubatsu()));
results.push(cmp("天狗[サツバツ_1] vs 上游2版 NinjaSlayer2.table.SATSUBATSU", d.tables["サツバツ_1"].items, up2("SATSUBATSU")));

// 天狗内部：2版无后缀表 vs 1版 _1 表
results.push(cmp("天狗内部 [サツバツ] vs [サツバツ_1]", d.tables["サツバツ"].items, d.tables["サツバツ_1"].items));
results.push(cmp("天狗内部 [wasshoiエントリー] vs [wasshoiエントリー_1]", d.tables["wasshoiエントリー"].items, d.tables["wasshoiエントリー_1"].items));

console.log("\n\n===== 汇总（L2 全等 = 语义同源）=====");
for (const r of results) {
  console.log(
    `${r.label}` +
      `\n    条目 ${r.items_tengu} vs ${r.items_upstream} | L0 ${r.L0}/${r.total}` +
      ` | L1 ${r.L1}/${r.total} | L2 ${r.L2}/${r.total} | 语义同源=${r.semantic_same}`
  );
}
