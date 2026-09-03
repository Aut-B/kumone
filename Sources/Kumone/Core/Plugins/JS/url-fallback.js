// URL / URLSearchParams installation with defense in depth.
// Load AFTER the whatwg-url bundle, BEFORE kumone-plugin-runtime.js.
//
// Priority: native URL (if constructible) -> whatwg-url bundle ->
// minimal fallback implementation. Guarantees `new URL()` and
// URLSearchParams exist in the sandbox so plugins never crash with
// "URL is not a constructor" / "undefined is not a constructor".
(function () {
  'use strict';

  function isConstructible(fn) {
    if (typeof fn !== 'function') return false;
    try {
      new fn('http://example.com/');
      return true;
    } catch (e) {
      return false;
    }
  }

  // ---- minimal fallback implementation ----
  function MinimalSearchParams(query) {
    this._pairs = [];
    var s = String(query == null ? '' : query).replace(/^\?/, '');
    if (s) {
      var parts = s.split('&');
      for (var i = 0; i < parts.length; i++) {
        var kv = parts[i];
        var eq = kv.indexOf('=');
        var k = eq >= 0 ? kv.slice(0, eq) : kv;
        var v = eq >= 0 ? kv.slice(eq + 1) : '';
        this._pairs.push([decodeURIComponent(k), decodeURIComponent(v)]);
      }
    }
  }
  MinimalSearchParams.prototype.get = function (k) {
    for (var i = 0; i < this._pairs.length; i++) if (this._pairs[i][0] === k) return this._pairs[i][1];
    return null;
  };
  MinimalSearchParams.prototype.set = function (k, v) {
    for (var i = 0; i < this._pairs.length; i++) {
      if (this._pairs[i][0] === k) { this._pairs[i][1] = String(v); return; }
    }
    this._pairs.push([k, String(v)]);
  };
  MinimalSearchParams.prototype.append = function (k, v) { this._pairs.push([k, String(v)]); };
  MinimalSearchParams.prototype['delete'] = function (k) {
    this._pairs = this._pairs.filter(function (p) { return p[0] !== k; });
  };
  MinimalSearchParams.prototype.has = function (k) {
    return this._pairs.some(function (p) { return p[0] === k; });
  };
  MinimalSearchParams.prototype.getAll = function (k) {
    return this._pairs.filter(function (p) { return p[0] === k; }).map(function (p) { return p[1]; });
  };
  MinimalSearchParams.prototype.forEach = function (cb) {
    this._pairs.forEach(function (p) { cb(p[1], p[0]); });
  };
  MinimalSearchParams.prototype.entries = function () {
    return this._pairs.map(function (p) { return p.slice(); })[Symbol.iterator]();
  };
  MinimalSearchParams.prototype.keys = function () {
    return this._pairs.map(function (p) { return p[0]; })[Symbol.iterator]();
  };
  MinimalSearchParams.prototype.values = function () {
    return this._pairs.map(function (p) { return p[1]; })[Symbol.iterator]();
  };
  MinimalSearchParams.prototype.toString = function () {
    return this._pairs.map(function (p) {
      return encodeURIComponent(p[0]) + '=' + encodeURIComponent(p[1]);
    }).join('&');
  };

  function MinimalURL(url, base) {
    var raw = String(url);
    if (base && raw.indexOf('://') < 0) {
      raw = String(base).replace(/\/[^\/]*$/, '') + '/' + raw;
    }
    var m = raw.match(/^([a-zA-Z][a-zA-Z0-9+.\-]*:)?\/\/([^\/?#]*)?([^?#]*)?(\?[^#]*)?(#.*)?$/) || [];
    this.protocol = m[1] || '';
    var host = m[2] || '';
    this.host = host;
    this.hostname = host.split(':')[0];
    var portIdx = host.indexOf(':');
    this.port = portIdx >= 0 ? host.slice(portIdx + 1) : '';
    this.pathname = m[3] || '/';
    this.search = m[4] || '';
    this.hash = m[5] || '';
    this.href = this.protocol + '//' + host + this.pathname + this.search + this.hash;
    this.searchParams = new MinimalSearchParams(this.search);
    this.toString = function () { return this.href; };
  }

  // ---- install ----
  var lib = globalThis.__mf_lib_whatwgurl || {};

  var URLClass = null;
  if (isConstructible(globalThis.URL)) URLClass = globalThis.URL;
  if (!URLClass && isConstructible(lib.URL)) URLClass = lib.URL;
  if (!URLClass && lib['default'] && isConstructible(lib['default'].URL)) URLClass = lib['default'].URL;
  if (!URLClass) URLClass = MinimalURL;
  globalThis.URL = URLClass;

  var SPC = null;
  if (isConstructible(globalThis.URLSearchParams)) SPC = globalThis.URLSearchParams;
  if (!SPC && isConstructible(lib.URLSearchParams)) SPC = lib.URLSearchParams;
  if (!SPC && lib['default'] && isConstructible(lib['default'].URLSearchParams)) SPC = lib['default'].URLSearchParams;
  if (!SPC) SPC = MinimalSearchParams;
  globalThis.URLSearchParams = SPC;
})();
