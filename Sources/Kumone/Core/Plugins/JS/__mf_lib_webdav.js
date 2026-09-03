// webdav stub: plugins rarely use it; keep the require() slot alive.
var __mf_lib_webdav = {
  createClient: function () {
    throw new Error("webdav is not supported in this environment");
  }
};
