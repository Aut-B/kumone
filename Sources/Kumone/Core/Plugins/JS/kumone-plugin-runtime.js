// Kumone plugin runtime — mirrors the MusicFree RN plugin engine
// (src/core/pluginManager/plugin.ts) for a JavaScriptCore host.
//
// Load order (native side):
//   1. all lib bundles (crypto-js.js, cheerio, dayjs, qs, he, big-integer,
//      whatwg-url, compare-versions, webdav stub)
//   2. this file
//   3. native bridge functions are injected as globalThis.__mf_native*
//
// A plugin is a JS string whose body runs inside a factory function:
//   function(require, __musicfree_require, module, exports, console, env,
//            URL, process) { ...plugin code... }
// The plugin assigns module.exports = { platform, search, getMediaSource, ... }.

(function () {
  'use strict';

  // ---------------------------------------------------------------
  // Polyfills: atob/btoa (via CryptoJS), URL / URLSearchParams (whatwg-url)
  // ---------------------------------------------------------------
  if (typeof globalThis.atob !== 'function') {
    globalThis.atob = function (b64) {
      var words = globalThis.CryptoJS.enc.Base64.parse(String(b64));
      return globalThis.CryptoJS.enc.Latin1.stringify(words);
    };
  }
  if (typeof globalThis.btoa !== 'function') {
    globalThis.btoa = function (str) {
      var words = globalThis.CryptoJS.enc.Latin1.parse(String(str));
      return globalThis.CryptoJS.enc.Base64.stringify(words);
    };
  }
  if (typeof globalThis.URL !== 'function' && globalThis.__mf_lib_whatwgurl) {
    globalThis.URL = globalThis.__mf_lib_whatwgurl.URL;
  }
  if (typeof globalThis.URLSearchParams !== 'function' && globalThis.__mf_lib_whatwgurl) {
    globalThis.URLSearchParams = globalThis.__mf_lib_whatwgurl.URLSearchParams;
  }
  if (typeof globalThis.__mf_lib_whatwgurl === 'object' && globalThis.__mf_lib_whatwgurl !== null) {
    // whatwg-url v13 exports classes on the namespace; also try direct
    if (!globalThis.URL) globalThis.URL = globalThis.__mf_lib_whatwgurl.default && globalThis.__mf_lib_whatwgurl.default.URL;
    if (!globalThis.URLSearchParams) globalThis.URLSearchParams = globalThis.__mf_lib_whatwgurl.default && globalThis.__mf_lib_whatwgurl.default.URLSearchParams;
  }

  // ---------------------------------------------------------------
  // Cookie jar (simple per-domain jar; MusicFree plugins mostly stateless)
  // ---------------------------------------------------------------
  var cookieJar = {};
  function cookieDomain(host) {
    try { return new globalThis.URL('http://' + host).hostname || host; } catch (e) { return host; }
  }
  function applyCookies(url, headers) {
    var host = cookieDomain(new globalThis.URL(url).hostname || '');
    var c = cookieJar[host];
    if (c && !(headers['cookie'] || headers['Cookie'])) headers['cookie'] = c;
  }
  function storeCookies(url, setCookies) {
    if (!setCookies || !setCookies.length) return;
    if (typeof setCookies === 'string') setCookies = [setCookies];
    var host = cookieDomain(new globalThis.URL(url).hostname || '');
    var jar = cookieJar[host] || {};
    for (var i = 0; i < setCookies.length; i++) {
      var parts = String(setCookies[i]).split(';');
      var kv = parts[0].split('=');
      if (kv.length >= 2) {
        var k = kv[0].trim();
        var v = kv.slice(1).join('=').trim();
        if (v === '' || /expires|path|domain/i.test(k)) continue;
        jar[k] = v;
      }
    }
    cookieJar[host] = jar;
    var list = [];
    for (var k in jar) list.push(k + '=' + jar[k]);
    return list.join('; ');
  }

  // ---------------------------------------------------------------
  // axios-compatible client backed by the native bridge
  // ---------------------------------------------------------------
  function makeAxios(native) {
    function Axios(config) { return Axios.request(config); }

    Axios.defaults = { timeout: 2000, headers: {} };
    Axios.interceptors = {
      request: { use: function () { return 0; } },
      response: { use: function () { return 0; } },
    };
    Axios.create = function (cfg) {
      // minimal create(): return a derived instance sharing the bridge
      var derived = function (c) { return derived.request(c); };
      derived.defaults = Object.assign({}, Axios.defaults, cfg || {});
      derived.interceptors = Axios.interceptors;
      derived.get = function (u, c) { return send(Object.assign({}, c, { method: 'get', url: u })); };
      derived.post = function (u, d, c) { return send(Object.assign({}, c, { method: 'post', url: u, data: d })); };
      derived.request = function (c) { return send(Object.assign({}, derived.defaults, c)); };
      return derived;
    };

    function serializeParams(params) {
      if (!params) return '';
      if (typeof params === 'string') return params;
      if (globalThis.URLSearchParams && params instanceof globalThis.URLSearchParams) return params.toString();
      if (typeof globalThis.qs === 'object' && globalThis.qs.stringify) {
        return globalThis.qs.stringify(params, { arrayFormat: 'brackets' });
      }
      var parts = [];
      for (var k in params) parts.push(encodeURIComponent(k) + '=' + encodeURIComponent(params[k]));
      return parts.join('&');
    }

    function send(cfg) {
      var method = String(cfg.method || 'get').toLowerCase();
      var timeout = Number(cfg.timeout || Axios.defaults.timeout || 5000);
      var url = cfg.url;
      var query = serializeParams(cfg.params);
      if (query) url += (url.indexOf('?') >= 0 ? '&' : '?') + query;
      var headers = {};
      var h = Object.assign({}, cfg.headers || {});
      for (var k in h) headers[String(k).toLowerCase()] = String(h[k]);
      applyCookies(url, headers);

      var data = cfg.data;
      var dataStr = null;
      if (data != null) {
        if (typeof data === 'string') dataStr = data;
        else if (globalThis.URLSearchParams && data instanceof globalThis.URLSearchParams) dataStr = data.toString();
        else if (data instanceof ArrayBuffer || ArrayBuffer.isView(data)) {
          var u8 = data instanceof ArrayBuffer ? new Uint8Array(data) : new Uint8Array(data.buffer, data.byteOffset, data.byteLength);
          var bin = '';
          for (var i = 0; i < u8.length; i++) bin += String.fromCharCode(u8[i]);
          dataStr = globalThis.btoa(bin);
          headers['data-encoding'] = 'base64';
        } else {
          dataStr = JSON.stringify(data);
          if (!headers['content-type']) headers['content-type'] = 'application/json';
        }
      }

      return new Promise(function (resolve, reject) {
        native.httpRequest(JSON.stringify({
          method: method,
          url: url,
          headers: headers,
          data: dataStr,
          timeout: timeout,
        }), function (resultJSON) {
          try {
            var result = JSON.parse(resultJSON);
          } catch (e) {
            reject(new Error('bridge parse error: ' + e.message));
            return;
          }
          if (result.error) { reject(new Error(result.error)); return; }

          var setCookies = result.headers ? result.headers['set-cookie'] : null;
          var cookieHeader = storeCookies(url, setCookies);
          if (cookieHeader && result.headers) result.headers['cookie'] = cookieHeader;

          var rt = cfg.responseType || 'json';
          var body = result.body != null ? result.body : '';
          if (rt === 'json') {
            if (typeof body === 'string' && body.length) {
              try { body = JSON.parse(body); } catch (e) { /* keep raw string */ }
            }
          } else if (rt === 'arraybuffer') {
            var bin2 = typeof body === 'string' ? body : '';
            var u8b = new Uint8Array(bin2.length);
            for (var i2 = 0; i2 < bin2.length; i2++) u8b[i2] = bin2.charCodeAt(i2);
            body = u8b.buffer;
          }

          var response = {
            data: body,
            status: result.status || 0,
            statusText: result.statusText || '',
            headers: result.headers || {},
            config: cfg,
          };
          if (result.status >= 400) {
            var err = new Error('Request failed with status code ' + result.status);
            err.response = response;
            err.status = result.status;
            reject(err);
            return;
          }
          resolve(response);
        });
      });
    }

    Axios.request = function (cfg) { return send(cfg); };
    Axios.get = function (u, c) { return send(Object.assign({}, c, { method: 'get', url: u })); };
    Axios.post = function (u, d, c) { return send(Object.assign({}, c, { method: 'post', url: u, data: d })); };
    Axios.put = function (u, d, c) { return send(Object.assign({}, c, { method: 'put', url: u, data: d })); };
    Axios.delete = function (u, c) { return send(Object.assign({}, c, { method: 'delete', url: u })); };
    Axios.head = function (u, c) { return send(Object.assign({}, c, { method: 'head', url: u })); };
    Axios.getUri = function (cfg) { return (cfg || {}).url; };
    Axios.isAxiosError = function (e) { return !!(e && (e.response || (e && e.isAxiosError))); };
    return Axios;
  }

  // ---------------------------------------------------------------
  // require() table (mirrors MusicFree packages map)
  // ---------------------------------------------------------------
  var cookieStub = { get: function () { return null; }, set: function () { }, flush: function () { } };

  function buildPackages(axiosInstance) {
    var cheerio = globalThis.__mf_lib_cheerio;
    if (cheerio && cheerio.__esModule && cheerio.default) cheerio = cheerio.default;
    return {
      cheerio: cheerio,
      'crypto-js': globalThis.CryptoJS,
      axios: axiosInstance,
      dayjs: globalThis.dayjs,
      'big-integer': globalThis.bigInt,
      qs: globalThis.qs,
      he: globalThis.he,
      webdav: globalThis.__mf_lib_webdav,
      '@react-native-cookies/cookies': cookieStub,
    };
  }

  // ---------------------------------------------------------------
  // console shim
  // ---------------------------------------------------------------
  function makeConsole() {
    function bind(method) {
      return function () {
        try {
          if (typeof console !== 'undefined' && console[method]) console[method].apply(console, arguments);
        } catch (e) { /* ignore */ }
        try {
          if (typeof globalThis.__mf_nativeLog === 'function') {
            var parts = [];
            for (var i = 0; i < arguments.length; i++) {
              var a = arguments[i];
              parts.push(typeof a === 'string' ? a : JSON.stringify(a));
            }
            globalThis.__mf_nativeLog(method, parts.join(' ').slice(0, 4000));
          }
        } catch (e2) { /* ignore */ }
      };
    }
    return { log: bind('log'), warn: bind('warn'), info: bind('info'), error: bind('error') };
  }

  // ---------------------------------------------------------------
  // Plugin factory + version check + call harness
  // ---------------------------------------------------------------
  var APP_VERSION = '0.6.2'; // MusicFree API level this engine implements

  function makeEnv(pluginName) {
    var env = {
      getUserVariables: function () {
        if (typeof globalThis.__mf_nativeGetUserVariables === 'function') {
          return globalThis.__mf_nativeGetUserVariables(pluginName) || {};
        }
        return {};
      },
      appVersion: APP_VERSION,
      os: 'android', // same as upstream MusicFree (even on iOS builds)
      lang: 'zh-CN',
    };
    Object.defineProperty(env, 'userVariables', {
      get: function () { return env.getUserVariables() || {}; },
      configurable: true,
    });
    return env;
  }

  function checkVersion(instance) {
    if (!instance || !instance.appVersion) return;
    var satisfies = (globalThis.__mf_lib_compareVersions && globalThis.__mf_lib_compareVersions.satisfies)
      || function () { return true; };
    var ok = false;
    try { ok = satisfies(APP_VERSION, String(instance.appVersion)); } catch (e) { ok = false; }
    if (!ok) throw new Error('PluginVersionNotMatch: requires "' + instance.appVersion + '", engine level ' + APP_VERSION);
  }

  globalThis.__mf_runPlugin = function (pluginCode, pluginName) {
    var module = { exports: {} };
    var env = makeEnv(pluginName);
    var _process = { platform: 'android', version: APP_VERSION, env: env };
    var _console = makeConsole();
    var axiosInstance = makeAxios(globalThis.__mf_native);
    var packages = buildPackages(axiosInstance);
    var _require = function (name) {
      var pkg = packages[name];
      if (!pkg) throw new Error('module not found: ' + name);
      if (pkg && pkg.default === undefined) { try { pkg.default = pkg; } catch (e) { } }
      return pkg;
    };
    var factory = Function("'use strict';\nreturn function(require, __musicfree_require, module, exports, console, env, URL, process) {\n" + String(pluginCode) + "\n}")();
    var instance = factory(_require, _require, module, module.exports, _console, env, globalThis.URL, _process);
    if (module.exports && module.exports.default) {
      instance = module.exports.default;
    } else {
      instance = module.exports;
    }
    if (!instance || typeof instance !== 'object') throw new Error('plugin did not export an object');
    checkVersion(instance);
    if (Array.isArray(instance.userVariables)) {
      instance.userVariables = instance.userVariables.filter(function (v) { return v && v.key; });
    }
    if (!instance.platform) throw new Error('plugin missing platform name');
    instance.__mf_pluginName = instance.platform;
    return instance;
  };

  // Async method call: done(JSON) is a native function. Mirrors the engine's
  // method surface so the native side only needs one entry point.
  globalThis.__mf_call = function (instance, method, argsJSON, done) {
    var args;
    try {
      args = JSON.parse(argsJSON);
    } catch (e) {
      done(JSON.stringify({ ok: false, error: 'args parse error: ' + e.message }));
      return;
    }
    var fn = instance ? instance[method] : undefined;
    if (typeof fn !== 'function') {
      done(JSON.stringify({ ok: false, error: 'method not implemented: ' + method }));
      return;
    }
    Promise.resolve(fn.apply(instance, args)).then(function (value) {
      var out;
      try {
        out = JSON.stringify({ ok: true, value: value === undefined ? null : value });
      } catch (e) {
        out = JSON.stringify({ ok: true, value: null, serializeError: String(e && e.message || e) });
      }
      done(out);
    }).catch(function (e) {
      var out;
      try {
        out = JSON.stringify({
          ok: false,
          error: String((e && e.message) || e),
          stack: String((e && e.stack) || '').slice(0, 2000),
        });
      } catch (e2) {
        out = JSON.stringify({ ok: false, error: 'unknown error' });
      }
      done(out);
    });
  };

  globalThis.__mf_sha256 = function (text) {
    return globalThis.CryptoJS.SHA256(String(text)).toString();
  };

  // ---------------------------------------------------------------
  // Instance registry + mount helper (called from Swift)
  // ---------------------------------------------------------------
  globalThis.__mf_instances = {};
  globalThis.__mf_mountPlugin = function (code, pluginName) {
    try {
      var inst = __mf_runPlugin(code, pluginName);
      globalThis.__mf_instances[inst.platform] = inst;
      return JSON.stringify({
        ok: true,
        platform: inst.platform,
        userVariables: Array.isArray(inst.userVariables) ? inst.userVariables : [],
      });
    } catch (e) {
      return JSON.stringify({
        ok: false,
        error: String((e && e.message) || e),
        stack: String((e && e.stack) || '').slice(0, 1500),
      });
    }
  };
  // Platform-name variants of the same source family (item names vs declared
  // names can differ, e.g. backup items "b站-ios" vs mounted "bilibili").
  var __mf_platformFamilies = [
    ['bilibili', 'b站-ios', 'b站', 'bili', '哔哩哔哩'],
  ];
  function __mf_sameFamily(a, b) {
    for (var i = 0; i < __mf_platformFamilies.length; i++) {
      var f = __mf_platformFamilies[i];
      if (f.indexOf(a) >= 0 && f.indexOf(b) >= 0) return true;
    }
    return false;
  }

  globalThis.__mf_callNamed = function (platform, method, argsJSON, done) {
    var inst = globalThis.__mf_instances[platform];
    if (!inst) {
      var keys = Object.keys(globalThis.__mf_instances);
      if (keys.length === 1) {
        inst = globalThis.__mf_instances[keys[0]];
      } else {
        var target = String(platform).toLowerCase();
        for (var i = 0; i < keys.length; i++) {
          var k = keys[i];
          var lk = k.toLowerCase();
          if (lk === target || __mf_sameFamily(platform, k)
              || lk.indexOf(target) >= 0 || target.indexOf(lk) >= 0) {
            inst = globalThis.__mf_instances[k];
            break;
          }
        }
      }
    }
    if (!inst) { done(JSON.stringify({ ok: false, error: 'plugin not mounted: ' + platform })); return; }
    __mf_call(inst, method, argsJSON, done);
  };
})();
