/*
 * VVeboMultiFix.c  --  plain C, no SDK headers required.
 *
 * Purpose
 * -------
 * Make VVebo survive LiveContainer's "multitask" mode.
 *
 * LiveContainer's multitask does NOT run the guest app in its own process: it
 * spawns the LiveProcess app-extension (LiveProcess.appex) as a child process
 * and then hosts that child's scene inside a virtual window
 * (MultitaskSupport/AppSceneViewController.m).  The guest app therefore runs
 * *inside an NSExtension*.
 *
 * VVebo's AppDelegate does this from application:didFinishLaunchingWithOptions:
 *
 *     BGTaskScheduler.shared.register(forTaskWithIdentifier:
 *             "com.johnil.vvebo.autosign", using: nil) { task in ... }
 *     BGTaskScheduler.shared.submit(BGAppRefreshTaskRequest(...))
 *
 * Verified in the shipped binary: the Swift ivar list of _TtC5VVebo11AppDelegate
 * sits immediately above the literals "com.johnil.vvebo.autosign",
 * "Could not schedule app refresh: " (the verbatim Apple sample text) and the
 * block encoding "v16@?0@\"BGTask\"8"; BackgroundTasks is hard-linked
 * (_OBJC_CLASS_$_BGTaskScheduler, _OBJC_CLASS_$_BGAppRefreshTaskRequest).
 *
 * -[BGTaskScheduler registerForTaskWithIdentifier:usingQueue:launchHandler:] is
 * annotated API_UNAVAILABLE(ios_app_extension) in the SDK header - "Only the host
 * application may register launch handlers".  Called from an extension process,
 * the framework trips an assertion inside
 * -[BGTaskScheduler _unsafe_registerForTaskWithIdentifier:usingQueue:launchHandler:]
 * -> uncaught exception -> the child process dies -> LiveContainer reports the
 * app as terminated.  A normal in-process launch never takes that path, which is
 * exactly the asymmetry between "works normally" and "dies in multitask".
 *
 * LiveContainer does nothing about this: its whole tree has zero references to
 * BGTaskScheduler.
 *
 * What this file does
 * -------------------
 * Replaces the extension-hostile entry point with a harmless no-op, but ONLY
 * when we really are the LiveProcess child process (detected through
 * LP_HOME_PATH, set by LiveProcess/main.m:59 before the guest is loaded, plus
 * the LiveProcessHandler class that only exists in that process).  Normal
 * launches are left completely untouched.
 *
 * A breadcrumb log is written to $LP_HOME_PATH/Documents/VVeboMultiFix.log -
 * the same directory LiveContainer itself uses for JIT dylibs
 * (LiveContainer/Tweaks/Dyld.m:626), which is inside LiveContainer's container
 * and therefore reachable from the Files app.
 */

#include <stdarg.h>

#pragma clang diagnostic ignored "-Wbuiltin-requires-header"

typedef unsigned char u8;
typedef unsigned long usize;

/* ------------------------------------------------------------------ libSystem */
extern void  *dlopen(const char *path, int mode);
extern void  *dlsym(void *handle, const char *symbol);
extern char  *getenv(const char *name);
extern int    vsnprintf(char *buf, usize n, const char *fmt, va_list ap);
extern int    snprintf(char *buf, usize n, const char *fmt, ...);
extern void  *fopen(const char *path, const char *mode);
extern usize  fwrite(const void *p, usize sz, usize n, void *fp);
extern int    fclose(void *fp);

#define RTLD_DEFAULT ((void *)-2L)
#define RTLD_LAZY    0x1

/* The ObjC runtime is reached through dlsym so this dylib needs no link-time
   dependency beyond libSystem. */
typedef void *Class;
typedef void *SEL;
typedef void *IMP;
typedef void *Method;
typedef void *id;

static Class  (*p_objc_getClass)(const char *);
static SEL    (*p_sel_registerName)(const char *);
static Method (*p_class_getInstanceMethod)(Class, SEL);
static IMP    (*p_method_setImplementation)(Method, IMP);
static id     (*p_objc_msgSend)(id, SEL, ...);
static void   (*p_NSLog)(id, ...);

/* ------------------------------------------------------------------- logging */

static void *gLogFile;

static void VVLog(const char *fmt, ...) {
    char buf[512];
    int n;
    __builtin_va_list ap;

    __builtin_va_start(ap, fmt);
    n = vsnprintf(buf, sizeof(buf) - 2, fmt, ap);
    __builtin_va_end(ap);
    if (n < 0) return;
    if ((usize)n > sizeof(buf) - 2) n = (int)(sizeof(buf) - 2);
    buf[n]     = '\n';
    buf[n + 1] = '\0';

    if (p_NSLog && p_objc_msgSend && p_objc_getClass && p_sel_registerName) {
        id s = p_objc_msgSend(p_objc_getClass("NSString"),
                              p_sel_registerName("stringWithUTF8String:"), buf);
        if (s) p_NSLog(s);
    }
    if (gLogFile) fwrite(buf, 1, (usize)n + 1, gLogFile);
}

/* Try the places the child process might be able to write, in order of how easy
   they are for the user to retrieve:

     1. $LP_HOME_PATH/Documents  - what LiveContainer itself uses for JIT dylibs
        (LiveContainer/Tweaks/Dyld.m:626), i.e. guaranteed writable from the child
     2. $LC_HOME_PATH/Documents  - LiveContainer's own container (the host's home);
        LiveContainer declares UIFileSharingEnabled + LSSupportsOpeningDocumentsInPlace
        so this shows up in the Files app
     3. $HOME/Documents          - last resort
*/
static void VVOpenLog(void) {
    static const char *envs[3] = { "LP_HOME_PATH", "LC_HOME_PATH", "HOME" };
    char path[512];
    int i;

    for (i = 0; i < 3 && !gLogFile; i++) {
        const char *home = getenv(envs[i]);
        if (!home || !*home) continue;
        snprintf(path, sizeof(path), "%s/Documents/VVeboMultiFix.log", home);
        gLogFile = fopen(path, "w");
        if (!gLogFile) {
            snprintf(path, sizeof(path), "%s/VVeboMultiFix.log", home);
            gLogFile = fopen(path, "w");
        }
        if (gLogFile) {
            VVLog("[VVeboMultiFix] log file: %s", path);
            return;
        }
    }
}

/* ------------------------------------------------------------ mode detection */

/* LiveProcess/main.m:59 runs setenv("LP_HOME_PATH", getenv("HOME"), 1) before the
   guest bundle is loaded, so it exists in exactly the child process.
   LiveProcessHandler lives in LiveProcess.appex and is a second, independent
   signal (it does not exist when the app runs in-process). */
static int VVIsLiveProcess(void) {
    static int cached = -1;
    const char *lp;

    if (cached >= 0) return cached;
    cached = 0;

    lp = getenv("LP_HOME_PATH");
    if (lp && *lp) {
        cached = 1;
    } else if (p_objc_getClass && p_objc_getClass("LiveProcessHandler")) {
        cached = 1;
    }
    return cached;
}

/* Pull a C string out of an NSString-ish object for logging. */
static const char *VVStr(id obj) {
    id cls;
    const char *s;

    if (!obj || !p_objc_msgSend || !p_sel_registerName) return "(null)";
    cls = p_objc_msgSend(obj, p_sel_registerName("class"));
    if (!cls) return "(?)";
    if (!p_class_getInstanceMethod(cls, p_sel_registerName("UTF8String"))) return "(non-string)";
    s = (const char *)p_objc_msgSend(obj, p_sel_registerName("UTF8String"));
    return s ? s : "(null)";
}

/* ----------------------------------------------------------------- the guards */

/* Original implementations, kept so that a normal (non-multitask) launch behaves
   exactly as it did before. */
typedef u8   (*RegImp)(id, SEL, id, void *, id);
typedef void (*RemoteImp)(id, SEL);
static RegImp    gOrigRegister;
static RemoteImp gOrigRemoteReg;

/* -[BGTaskScheduler registerForTaskWithIdentifier:usingQueue:launchHandler:]
   Inside the LiveProcess child this is extension-unavailable, so we return NO -
   exactly what an app extension gets, and background refresh could not be
   delivered to the child anyway. Anywhere else we call straight through. */
static u8 VVBlockedRegister(id self, SEL _cmd, id identifier, void *queue, id handler) {
    if (!VVIsLiveProcess()) {
        return gOrigRegister ? gOrigRegister(self, _cmd, identifier, queue, handler) : 0;
    }
    VVLog("[VVeboMultiFix] BLOCKED BGTaskScheduler register '%s' (extension-hostile)",
          VVStr(identifier));
    (void)self; (void)_cmd; (void)queue; (void)handler;
    return 0;
}

/* -[UIApplication registerForRemoteNotifications] - the guest has no APNs
   identity while running inside the extension. */
static void VVBlockedRemoteNotificationRegistration(id self, SEL _cmd) {
    if (!VVIsLiveProcess()) {
        if (gOrigRemoteReg) gOrigRemoteReg(self, _cmd);
        return;
    }
    VVLog("[VVeboMultiFix] BLOCKED registerForRemoteNotifications (extension-hostile)");
    (void)self; (void)_cmd;
}

/* ------------------------------------------------ launch breadcrumb trail */

typedef int (*DFLImp)(id, SEL, id, id);
static DFLImp gOrigDFL;

static int VVHookedDidFinishLaunching(id self, SEL _cmd, id application, id launchOptions) {
    VVLog("[VVeboMultiFix] didFinishLaunchingWithOptions -> ENTER");
    int r = gOrigDFL ? gOrigDFL(self, _cmd, application, launchOptions) : 1;
    VVLog("[VVeboMultiFix] didFinishLaunchingWithOptions <- RETURN %d", r);
    return r;
}

/* Scene breadcrumbs: tell us whether the app ever got as far as connecting a
   scene, which is the last thing that has to happen for the window to appear. */
typedef void (*SceneImp)(id, SEL, id, id, id);
static Class gSceneClsApp, gSceneClsBrowser;
static SceneImp gOrigSceneApp, gOrigSceneBrowser;

static void VVHookedSceneConnect(id self, SEL _cmd, id scene, id session, id options) {
    id cls = p_objc_msgSend ? p_objc_msgSend(self, p_sel_registerName("class")) : 0;
    SceneImp orig = (cls == gSceneClsBrowser) ? gOrigSceneBrowser : gOrigSceneApp;

    VVLog("[VVeboMultiFix] scene:willConnectToSession: -> ENTER (%s)",
          (cls == gSceneClsBrowser) ? "BrowserSceneDelegate" : "SceneDelegate");
    if (orig) orig(self, _cmd, scene, session, options);
    VVLog("[VVeboMultiFix] scene:willConnectToSession: <- RETURN");
}

/* ------------------------------------------------------------------ installer */

static void VVReplaceMethod(Class cls, const char *selName, IMP newImp, IMP *oldOut) {
    SEL s;
    Method m;
    IMP old;

    if (!cls || !p_class_getInstanceMethod || !p_sel_registerName || !p_method_setImplementation) return;
    s = p_sel_registerName(selName);
    m = p_class_getInstanceMethod(cls, s);
    if (!m) {
        VVLog("[VVeboMultiFix] !! selector not present: %s", selName);
        return;
    }
    old = p_method_setImplementation(m, newImp);
    if (oldOut) *oldOut = old;
    VVLog("[VVeboMultiFix] + guard installed: %s", selName);
}

static void VVInstall(void) {
    Class bg, app, ad;

    p_objc_getClass           = (Class (*)(const char *))dlsym(RTLD_DEFAULT, "objc_getClass");
    p_sel_registerName        = (SEL (*)(const char *))dlsym(RTLD_DEFAULT, "sel_registerName");
    p_class_getInstanceMethod = (Method (*)(Class, SEL))dlsym(RTLD_DEFAULT, "class_getInstanceMethod");
    p_method_setImplementation= (IMP (*)(Method, IMP))dlsym(RTLD_DEFAULT, "method_setImplementation");
    p_objc_msgSend            = (id (*)(id, SEL, ...))dlsym(RTLD_DEFAULT, "objc_msgSend");
    p_NSLog                   = (void (*)(id, ...))dlsym(RTLD_DEFAULT, "NSLog");

    VVOpenLog();
    VVLog("[VVeboMultiFix] loaded (build 2)");

    if (!p_objc_getClass || !p_sel_registerName || !p_class_getInstanceMethod ||
        !p_method_setImplementation) {
        VVLog("[VVeboMultiFix] !! ObjC runtime unreachable, aborting");
        return;
    }

    VVLog("[VVeboMultiFix] mode: %s", VVIsLiveProcess() ? "LiveProcess child (multitask)"
                                                        : "in-process (normal launch)");

    /* Force BackgroundTasks in so objc_getClass can see BGTaskScheduler. The app
       hard-links it already, so this introduces no new dependency. */
    dlopen("/System/Library/Frameworks/BackgroundTasks.framework/BackgroundTasks", RTLD_LAZY);

    /* The hooks are always installed; each one decides at call time whether it is
       inside the LiveProcess child, so a normal launch just forwards to the
       original implementation. */
    bg = p_objc_getClass("BGTaskScheduler");
    VVLog("[VVeboMultiFix] BGTaskScheduler class = %p", (void *)bg);
    if (bg) {
        VVReplaceMethod(bg,
            "registerForTaskWithIdentifier:usingQueue:launchHandler:",
            (IMP)VVBlockedRegister, (IMP *)&gOrigRegister);
    }

    app = p_objc_getClass("UIApplication");
    if (app) {
        VVReplaceMethod(app, "registerForRemoteNotifications",
                        (IMP)VVBlockedRemoteNotificationRegistration, (IMP *)&gOrigRemoteReg);
    }

    /* Breadcrumb: shows whether the child dies inside didFinishLaunching. */
    ad = p_objc_getClass("_TtC5VVebo11AppDelegate");
    if (!ad) ad = p_objc_getClass("VVebo.AppDelegate");
    VVLog("[VVeboMultiFix] AppDelegate class = %p", (void *)ad);
    if (ad) {
        VVReplaceMethod(ad, "application:didFinishLaunchingWithOptions:",
                        (IMP)VVHookedDidFinishLaunching, (IMP *)&gOrigDFL);
    }

    /* Breadcrumbs for the two scene delegates the app declares in its
       UIApplicationSceneManifest ("Default Configuration" and "BrowserSence"). */
    {
        Class sa = p_objc_getClass("_TtC5VVebo13SceneDelegate");
        Class sb = p_objc_getClass("_TtC5VVebo19BrowserSceneDelegate");
        if (!sa) sa = p_objc_getClass("VVebo.SceneDelegate");
        if (!sb) sb = p_objc_getClass("VVebo.BrowserSceneDelegate");
        gSceneClsApp     = sa;
        gSceneClsBrowser = sb;
        VVLog("[VVeboMultiFix] scene delegate classes: default=%p browser=%p", (void *)sa, (void *)sb);
        if (sa) VVReplaceMethod(sa, "scene:willConnectToSession:options:",
                                (IMP)VVHookedSceneConnect, (IMP *)&gOrigSceneApp);
        if (sb) VVReplaceMethod(sb, "scene:willConnectToSession:options:",
                                (IMP)VVHookedSceneConnect, (IMP *)&gOrigSceneBrowser);
    }

    VVLog("[VVeboMultiFix] guards ready");
}

__attribute__((constructor))
static void VVeboMultiFixInit(void) {
    VVInstall();
}
