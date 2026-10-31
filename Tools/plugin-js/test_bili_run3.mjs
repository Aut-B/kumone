// Run the real bilibili plugin through the Kumone JS runtime in node vm.
import fs from "fs";
import vm from "vm";
import path from "path";
import { fileURLToPath } from "url";

const dir = path.dirname(fileURLToPath(import.meta.url));
const jsDir = path.join(dir, "..", "..", "Sources", "Kumone", "Core", "Plugins", "JS");

const libOrder = [
  "crypto-js.js", "dayjs.js", "qs.js", "he.js", "big-integer.js",
  "__mf_lib_cheerio.js", "__mf_lib_webdav.js", "__mf_lib_whatwgurl.js",
  "url-fallback.js", "__mf_lib_compareVersions.js", "kumone-plugin-runtime.js",
];

const sandbox = {
  console: { log: () => {}, warn: () => {}, error: (...a) => console.log("[js err]", ...a), info: () => {} },
  TextEncoder, TextDecoder, setTimeout, clearTimeout,
};
sandbox.globalThis = sandbox;
vm.createContext(sandbox);
sandbox.__mf_native = {
  httpRequest: (o, cb) => {
    (async () => {
      const opts = JSON.parse(o);
      try {
        const resp = await fetch(opts.url, {
          method: opts.method || "get",
          headers: opts.headers || {},
          body: opts.data ? Buffer.from(opts.data, "utf8") : undefined,
          redirect: "follow",
        });
        const buf = Buffer.from(await resp.arrayBuffer());
        const hdrs = {};
        resp.headers.forEach((v, k) => { hdrs[k] = v; });
        console.log("[http]", (opts.method || "get").toUpperCase(), opts.url.slice(0, 110), "->", resp.status, buf.length);
        cb(JSON.stringify({ status: resp.status, statusText: resp.statusText, headers: hdrs, body: buf.toString("utf8") }));
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

const pluginCode = fs.readFileSync(path.join(dir, "test_bili_official.js"), "utf8");
vm.runInContext("globalThis.__inst = __mf_runPlugin(" + JSON.stringify(pluginCode) + ', "bili")', sandbox);

const call = (m, args) => new Promise((resolve) => {
  sandbox.__done = (j) => resolve(JSON.parse(j));
  vm.runInContext('__mf_call(__inst, "' + m + '", ' + JSON.stringify(JSON.stringify(args)) + ", __done)", sandbox);
});

const r = await call("search", ["BV1884y137AZ", 1, "music"]);
console.log("search ok:", r.ok, r.error || "");
const data = (r.value && r.value.data) || [];
console.log("items:", data.length);
for (const it of data.slice(0, 3)) {
  console.log("-", it.id, it.title, it.artist, it.duration);
}
if (data[0]) {
  const ms = await call("getMediaSource", [data[0], "standard"]);
  console.log("getMediaSource ok:", ms.ok, ms.error || "");
  console.log("url:", JSON.stringify(ms.value).slice(0, 220));
}
