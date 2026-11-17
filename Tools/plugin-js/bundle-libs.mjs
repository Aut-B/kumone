// Builds the JS library bundles used by the plugin sandbox.
// Run: npm install && node bundle-libs.mjs
// Outputs committed into ./ (same dir), loaded by the app at runtime.
import { build } from "esbuild";
import { createRequire } from "module";
import fs from "fs";
import path from "path";

const require = createRequire(import.meta.url);
const out = process.cwd();
const copy = (src, dst) => {
  const p = require.resolve(src);
  fs.copyFileSync(p, path.join(out, dst));
  console.log("copied", dst, path.basename(p));
};

// UMD builds loaded as raw scripts (they attach to globalThis)
copy("crypto-js/crypto-js.js", "crypto-js.js");           // global CryptoJS
copy("dayjs/dayjs.min.js", "dayjs.js");                    // global dayjs
copy("qs/dist/qs.js", "qs.js");                            // global qs
copy("he/he.js", "he.js");                                 // global he
copy("big-integer/BigInteger.min.js", "big-integer.js");   // global bigInt

// CJS/ESM-only libs: bundle to IIFE with a fixed global name
const bundles = [
  ["cheerio", "__mf_lib_cheerio"],
  ["webdav", "__mf_lib_webdav"],
  ["whatwg-url", "__mf_lib_whatwgurl"],
  ["compare-versions", "__mf_lib_compareVersions"],
];
for (const [mod, gname] of bundles) {
  const outfile = path.join(out, gname + ".js");
  await build({
    entryPoints: [require.resolve(mod)],
    bundle: true,
    format: "iife",
    globalName: gname,
    platform: "browser",
    outfile,
    minify: false,
  });
  console.log("bundled", mod, "->", path.basename(outfile));
}
console.log("done");
