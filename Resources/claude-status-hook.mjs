// ByteRate 任务状态 hook。Claude Code 各事件调用它，写一份 per-session 状态文件，
// ByteRate 轮询这些文件聚合出「运行中 / 空闲 / 待确认」。只写状态，不碰任何凭据或对话内容。
// 用法（settings.json 里）：node <此文件> <state>   state ∈ running|waiting|idle|end
import { mkdirSync, writeFileSync, unlinkSync } from "fs";
import { homedir } from "os";
import { join } from "path";

const state = process.argv[2] || "running";
const dir = join(homedir(), "Library/Application Support/ByteRate/status");

let input = "";
for await (const chunk of process.stdin) input += chunk;
let sid = "default";
try { sid = String(JSON.parse(input).session_id || "default"); } catch {}
sid = sid.replace(/[^a-zA-Z0-9_-]/g, "") || "default";

const file = join(dir, sid + ".json");
try {
  if (state === "end") {
    unlinkSync(file);
  } else {
    mkdirSync(dir, { recursive: true });
    writeFileSync(file, JSON.stringify({ state, ts: Date.now() }));
  }
} catch {}
