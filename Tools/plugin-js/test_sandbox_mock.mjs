// Deterministic full-chain test: local mock server + mock plugin.
import fs from "fs";
import vm from "vm";
import path from "path";
import http from "http";
import { fileURLToPath } from "url";

const dir = path.dirname(fileURLToPath(import.meta.url));
const jsDir = path.join(dir, "../../Sources/Kumone/Core/Plugins/JS");

// --- local mock server acting as a fake music API ---
const server = http.createServer((req, res) => {
  const u = new URL(req.url, "http://127.0.0.1");
  if (u.pathname === "/search") {
    res.setHeader("content-type", "application/json");
    res.setHeader("set-cookie", "token=abc123; Path=/");
    res.end(JSON.stringify({
      isEnd: true,
      data: [
        { id: "1", platform: "mock", title: "测试歌曲 " + u.searchParams.get("q"), artist: "测试歌手", url: "http://127.0.0.1:18081/song1" },
        { id: "2", platform: "mock", title: "第二首", artist: "B", url: "http://127.0.0.1:18081/song2" },
      ],
    }));
  } else if (u.pathname === "/cookietest") {
    res.setHeader("content-type", "application/json");
    res.end(JSON.stringify({ cookieReceived: req.headers.cookie || null }));
  } else {
    res.statusCode = 404;
    res.end("{}");
  }
});
await new Promise((r) => server.listen(18081, "127.0.0.1", r));

const libOrder = [
  "crypto-js.js", "dayjs.js", "qs.js", "he.js", "big-integer.js",
  "__mf_lib_cheerio.js", "__mf_lib_webdav.js", "__mf_lib_whatwgurl.js",
  "url-fallback.js",
  "__mf_lib_compareVersions.js", "kumone-plugin-runtime.js",
];
const sandbox = {
  console: { log: () => {}, warn: () => {}, error: (...a) => console.log("[js:error]", ...a), info: () => {} },
  TextEncoder, TextDecoder, setTimeout, clearTimeout,
};
sandbox.globalThis = sandbox;
vm.createContext(sandbox);
sandbox.__mf_native = {
  httpRequest: (optionsJSON, cb) => {
    (async () => {
      let opts = {};
      try { opts = JSON.parse(optionsJSON); } catch (e) { cb(JSON.stringify({ error: "bad options" })); return; }
      try {
        const resp = await fetch(opts.url, {
          method: opts.method || "get",
          headers: opts.headers || {},
          body: opts.data ? Buffer.from(opts.data, "utf8") : undefined,
        });
        const buf = Buffer.from(await resp.arrayBuffer());
        const outHeaders = {};
        resp.headers.forEach((v, k) => { outHeaders[k] = v; });
        console.log(`[http] ${(opts.method || "get").toUpperCase()} ${opts.url} -> ${resp.status} (${buf.length}B)`);
        cb(JSON.stringify({ status: resp.status, statusText: resp.statusText, headers: outHeaders, body: buf.toString("utf8") }));
      } catch (e) {
        cb(JSON.stringify({ error: String((e && e.message) || e) }));
      }
    })();
  },
  getUserVariables: () => ({}),
  setUserVariables: () => {},
};
sandbox.__mf_nativeLog = () => {};
for (const f of libOrder) {
  vm.runInContext(fs.readFileSync(path.join(jsDir, f), "utf8"), sandbox, { filename: f });
}

const pluginCode = `
module.exports = {
  platform: "mock源",
  appVersion: ">0.4.0-alpha.0",   // version check must pass (engine reports 0.6.2)
  async search(query, page, type) {
    const axios = require("axios");
    const resp = await axios.get("http://127.0.0.1:18081/search", { params: { q: query } });
    const resp2 = await axios.get("http://127.0.0.1:18081/cookietest"); // cookie jar round-trip
    return {
      isEnd: resp.data.isEnd,
      data: resp.data.data.map(it => ({ ...it, cookieOk: !!resp2.data.cookieReceived })),
    };
  },
  async getMediaSource(item, quality) {
    return { url: item.url + "?q=" + quality, headers: { "x-test": "1" } };
  },
};`;

const instance = vm.runInContext(`__mf_runPlugin(${JSON.stringify(pluginCode)}, "mock")`, sandbox);
console.log("mounted:", instance.platform);

sandbox.__instance = instance;
const call = (method, args) => new Promise((resolve) => {
  sandbox.__done = (json) => resolve(JSON.parse(json));
  vm.runInContext(`__mf_call(__instance, ${JSON.stringify(method)}, ${JSON.stringify(JSON.stringify(args))}, __done)`, sandbox);
});

const r1 = await call("search", ["周杰伦", 1, "music"]);
console.log("search ok:", r1.ok, JSON.stringify(r1.value && r1.value.data && r1.value.data[0]));

const r2 = await call("getMediaSource", [{ id: "1", platform: "mock", url: "http://127.0.0.1:18081/song1" }, "standard"]);
console.log("getMediaSource ok:", r2.ok, JSON.stringify(r2.value));

const r3 = await call("nonexistentMethod", []);
console.log("missing method handled:", r3.ok === false, r3.error);

server.close();
console.log(r1.ok && r2.ok && !r3.ok ? "\nMOCK CHAIN TEST PASSED" : "\nMOCK CHAIN TEST FAILED");
