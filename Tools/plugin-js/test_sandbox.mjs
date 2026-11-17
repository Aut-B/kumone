// Local smoke test: simulate the JSC sandbox in node vm and run a REAL
// MusicFree plugin (search). Run: node test_sandbox.mjs [pluginUrl]
import fs from "fs";
import vm from "vm";
import path from "path";
import { fileURLToPath } from "url";

const dir = path.dirname(fileURLToPath(import.meta.url));
const jsDir = path.join(dir, "../../Sources/Kumone/Core/Plugins/JS");
const defaultPlugins = [
  "https://raw.githubusercontent.com/ThomasBy2025/musicfree/refs/heads/main/plugins/wy.js",
  "https://13413.kstore.vip/yuanli/wy.js",
];
const pluginUrl = process.argv[2] || defaultPlugins[0];

const libOrder = [
  "crypto-js.js",
  "dayjs.js",
  "qs.js",
  "he.js",
  "big-integer.js",
  "__mf_lib_cheerio.js",
  "__mf_lib_webdav.js",
  "__mf_lib_whatwgurl.js",
  "__mf_lib_compareVersions.js",
  "kumone-plugin-runtime.js",
];

const sandbox = {
  console: {
    log: (...a) => console.log("[js:log]", ...a.map((x) => (typeof x === "string" ? x.slice(0, 300) : x))),
    warn: (...a) => console.log("[js:warn]", ...a),
    error: (...a) => console.log("[js:error]", ...a),
    info: (...a) => console.log("[js:info]", ...a),
  },
  TextEncoder, TextDecoder,
  setTimeout, clearTimeout,
};
sandbox.globalThis = sandbox;
vm.createContext(sandbox);

// ---- native bridge mock (real HTTP via node fetch) ----
sandbox.__mf_native = {
  httpRequest: (optionsJSON, cb) => {
    (async () => {
      let opts = {};
      try { opts = JSON.parse(optionsJSON); } catch (e) { cb(JSON.stringify({ error: "bad options" })); return; }
      try {
        const ctrl = new AbortController();
        const t = setTimeout(() => ctrl.abort(), Math.max(1000, (opts.timeout || 5000) + 500));
        const headers = {};
        for (const k in (opts.headers || {})) headers[k] = opts.headers[k];
        if (opts.data) headers["content-length"] = Buffer.byteLength(opts.data);
        const resp = await fetch(opts.url, {
          method: opts.method || "get",
          headers,
          body: opts.data ? Buffer.from(opts.data, "utf8") : undefined,
          signal: ctrl.signal,
          redirect: "follow",
        });
        clearTimeout(t);
        const buf = Buffer.from(await resp.arrayBuffer());
        const outHeaders = {};
        resp.headers.forEach((v, k) => { outHeaders[k] = v; });
        let bodyStr = null;
        try { bodyStr = buf.toString("utf8"); } catch (e) { /* binary */ }
        if (bodyStr === null || bodyStr.includes("�")) bodyStr = buf.toString("latin1");
        console.log(`[http] ${(opts.method || "get").toUpperCase()} ${opts.url} -> ${resp.status} (${buf.length}B) body: ${bodyStr.slice(0, 120).replace(/\n/g, " ")}`);
        cb(JSON.stringify({ status: resp.status, statusText: resp.statusText, headers: outHeaders, body: bodyStr }));
      } catch (e) {
        cb(JSON.stringify({ error: String((e && e.message) || e) }));
      }
    })();
  },
  getUserVariables: () => ({}),
  setUserVariables: () => {},
};
sandbox.__mf_nativeLog = (lvl, msg) => console.log(`[plugin:${lvl}]`, msg.slice(0, 300));

for (const f of libOrder) {
  const code = fs.readFileSync(path.join(jsDir, f), "utf8");
  try {
    vm.runInContext(code, sandbox, { filename: f });
  } catch (e) {
    console.log(`FAIL loading ${f}:`, e.message);
    process.exit(1);
  }
  console.log("loaded", f);
}

// ---- fetch plugin code ----
console.log("\nfetching plugin:", pluginUrl);
let pluginCode;
for (const url of pluginUrl === defaultPlugins[0] ? defaultPlugins : [pluginUrl]) {
  try {
    const r = await fetch(url, { redirect: "follow" });
    pluginCode = await r.text();
    console.log("got plugin from", url, "len", pluginCode.length);
    break;
  } catch (e) {
    console.log("fetch fail", url, e.message);
  }
}
if (!pluginCode) { console.log("NO PLUGIN CODE"); process.exit(1); }

// ---- run plugin ----
let instance;
try {
  instance = vm.runInContext(`__mf_runPlugin(${JSON.stringify(pluginCode)}, "test")`, sandbox);
  console.log("mounted platform:", instance.platform);
  console.log("methods:", Object.keys(instance).filter((k) => typeof instance[k] === "function"));
} catch (e) {
  console.log("MOUNT FAIL:", e.message);
  process.exit(1);
}

// ---- call search ----
sandbox.__instance = instance;
const result = await new Promise((resolve) => {
  sandbox.__done = (json) => resolve(JSON.parse(json));
  vm.runInContext(`__mf_call(__instance, "search", ${JSON.stringify(JSON.stringify(["周杰伦", 1, "music"]))}, __done)`, sandbox);
});
console.log("\n=== search result ===");
if (result.ok) {
  const d = result.value || {};
  console.log("isEnd:", d.isEnd, "count:", (d.data || []).length);
  for (const item of (d.data || []).slice(0, 3)) {
    console.log("-", item.platform, item.id, item.title, item.artist, "url:", !!item.url, "qualities:", Object.keys(item.qualities || {}));
  }
} else {
  console.log("FAIL:", result.error);
  console.log("stack:", (result.stack || "").slice(0, 600));
  process.exit(1);
}
console.log("\nSMOKE TEST PASSED");
