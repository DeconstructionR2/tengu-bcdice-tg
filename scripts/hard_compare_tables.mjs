#!/usr/bin/env node
// ============================================================================
// 一次性硬比对（kimi 总复核 P5）：天狗**原文** vs 提取 JSON 的独立 oracle
//
// 为什么存在：extract_tengu_data.mjs 产出的 tengu_tables.json 是全管线源头——
// 它若提取错，自检/三方校验/toml 全链都绿（同一份错数据）。本脚本绕开 JSON 的
// 生成逻辑，**重新 require 钉版快照原文**，与 JSON 逐项逐字硬比对。
// 非驻守测试（依赖 Node 环境），跑法：node scripts/hard_compare_tables.mjs
// ============================================================================
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";

const require = createRequire(import.meta.url);
const path = require("path");

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const SNAP = path.join(ROOT, "references/src/TenguDiceBot/TenguDiceBot");
const extracted = require(path.join(ROOT, "references/extracted/tengu_tables.json"));

// 与 extract_tengu_data.mjs 同款的依赖 stub（数据文件不真正触达这些，stub 无害）
const Module = require("module");
const origResolve = Module._resolveFilename;
Module._resolveFilename = function (request, ...args) {
  try {
    return origResolve.call(this, request, ...args);
  } catch {
    return request; // 未安装依赖 → 原样返回，配合下面的空 stub
  }
};
const origLoad = Module._load;
Module._load = function (request, ...args) {
  try {
    return origLoad.call(this, request, ...args);
  } catch {
    return {}; // firebase-admin / discord.js 等空 stub
  }
};

const datatable = require(path.join(SNAP, "tengu_dice/nd_datatable.js"));
// nd_datatable.js 的导出形态：module.exports = { dataTable: { <日文表名>: { dice, data } } }
//（与 extract_tengu_data.mjs:97 同口径）
const SRC_TABLES = datatable.dataTable;

let checked = 0;
let mismatched = 0;
let missing = [];

for (const [ja, entry] of Object.entries(extracted.tables)) {
  const src = SRC_TABLES[ja];
  if (!src) {
    missing.push(ja);
    continue;
  }
  const srcData = src.data || {};
  const srcItems = Object.keys(srcData).map((k) => srcData[k]);
  const gotItems = entry.items;

  if (srcItems.length !== gotItems.length) {
    console.log(`❌ ${ja}: 条目数 源=${srcItems.length} vs JSON=${gotItems.length}`);
    mismatched += 1;
    continue;
  }
  srcItems.forEach((s, i) => {
    checked += 1;
    if (s !== gotItems[i]) {
      mismatched += 1;
      console.log(`❌ ${ja}[${i + 1}]: 源=${JSON.stringify(String(s).slice(0, 50))} vs JSON=${JSON.stringify(String(gotItems[i]).slice(0, 50))}`);
    }
  });
}

// 反向：源里有而 JSON 没有的表（提取遗漏面）
const missingInJson = Object.keys(SRC_TABLES).filter((k) => !extracted.tables[k]);

console.log(`\n硬比对：${checked} 项逐字比对，${mismatched} 项不一致；JSON 缺表 ${missing.length} 张${missing.length ? "：" + missing.join("、") : ""}；源多出而 JSON 未收 ${missingInJson.length} 张${missingInJson.length ? "：" + missingInJson.join("、") : ""}`);
if (mismatched > 0 || missing.length > 0 || missingInJson.length > 0) {
  process.exit(1);
}
console.log("✅ JSON 与天狗原文逐字一致（提取层零漂移）");
