/*
 * VVeboMultiFix.m  --  LiveContainer multitask support for VVebo 3.3.31
 *                      (guards + flight recorder), build 3
 * ============================================================================
 *
 * The problem
 * -----------
 * VVebo installs and launches fine inside LiveContainer's *normal* mode, but in
 * *multitask* mode the guest dies during launch and LiveContainer paints its
 * "app has been terminated" label over the window.
 *
 * Why the two modes differ at all: multitask does not run the guest in
 * LiveContainer's own process.  It spawns LiveProcess.appex as a child process
 * and hosts that child's scene inside a virtual window
 * (MultitaskSupport/AppSceneViewController.m).  The guest app therefore runs
 * inside an *app extension* process, where a number of UIKit / BackgroundTasks
 * APIs are unavailable.  A normal launch never takes that path.
 *
 * What we learned from LiveContainer's source (this is why build 3 looks the
 * way it does)
 * ----------------------------------------------------------------------------
 *  - LCBootstrap.m:809 installs its own NSSetUncaughtExceptionHandler *before*
 *    jumping into the guest, and litehook only rebinds the symbol so that the
 *    *guest* cannot replace it.  Its handler (LCBootstrap.m:664) funnels an
 *    uncaught exception into NSExtensionContext -cancelRequestWithError:, which
 *    LiveContainer shows as an alert carrying the exception reason and call
 *    stack, with a Copy button.
 *
 *    ==> If the guest died from an uncaught Objective-C exception, the user
 *        would have seen that alert.  They see the plain "terminated" label
 *        instead, so the guest is dying from a *signal* (or from something the
 *        kernel does behind our back: jetsam, watchdog, sandbox), not from a
 *        raised NSException.
 *
 *  - LCBootstrap.m:574 dlopens the guest main executable with
 *    RTLD_LAZY|RTLD_GLOBAL|RTLD_FIRST, so this dylib is pulled in as a
 *    dependency and its constructor runs before the guest's own initializers.
 *
 * So build 3 does two jobs:
 *
 *   1. GUARDS -- neutralise the extension-hostile entry points we can name with
 *      confidence.  BGTaskScheduler is the big one: VVebo registers
 *      "com.johnil.vvebo.autosign" from application:didFinishLaunchingWithOptions:
 *      (the literals are in the shipped binary right next to
 *      "Could not schedule app refresh:" and the block encoding for BGTask).
 *      In the child, +[BGTaskScheduler sharedScheduler] / -registerForTask... /
 *      -submitTaskRequest:error: are all unavailable, so we hand the guest a
 *      stand-in scheduler that accepts and drops everything.
 *
 *   2. FLIGHT RECORDER -- everything else is pure observation, and the point of
 *      this build.  It writes an unbuffered log, mirrors the process's stdout and
 *      stderr into it (so Swift fatal errors, assertion text and
 *      "*** Terminating app due to uncaught exception ..." land in the file),
 *      catches deadly signals with a backtrace, breadcrumbs the app and scene
 *      lifecycle plus the suspicious APIs, and runs a heartbeat thread that
 *      reports RSS / available head-room / thread count.  The last lines before
 *      the log stops say how the guest died:
 *
 *        - ends on "FATAL SIGNAL ..."            -> hard crash, backtrace below
 *        - ends right after "[call ] <api>"      -> that API killed us
 *        - ends on a heartbeat, nothing after    -> killed from outside (jetsam,
 *                                                   launch watchdog, sandbox)
 *        - reaches "launch sequence complete"    -> it actually worked
 *
 * The log lands next to LiveContainer's own Documents directory, which
 * LiveContainer publishes to the Files app (UIFileSharingEnabled +
 * LSSupportsOpeningDocumentsInPlace in LiveContainer/Info.plist):
 *
 *      Files app -> On My iPhone -> LiveContainer -> VVeboMultiFix.log
 *
 * Nothing here changes behaviour on a normal (in-process) launch: every guard
 * checks VVIsLiveProcess() first and falls straight through to the original
 * implementation otherwise.
 */

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <fcntl.h>
#import <unistd.h>
#import <signal.h>
#import <string.h>
#import <stdlib.h>
#import <stdio.h>
#import <stdarg.h>
#import <errno.h>
#import <limits.h>
#import <pthread.h>
#import <sys/time.h>
#import <sys/types.h>
#import <mach/mach.h>
#import <mach/task_info.h>

/* Declared by hand rather than through <execinfo.h> / <mach-o/dyld.h>: the
   iPhoneOS SDK does not expose _dyld_image_count() through the public header
   (build 3's first CI run failed on exactly that), and execinfo.h is not
   guaranteed to exist in the SDK at all.  Neither is a link-time dependency. */
extern int  backtrace(void **buffer, int size);
extern void backtrace_symbols_fd(void *const *buffer, int size, int fd);
extern uint32_t _dyld_image_count(void);

#ifndef PATH_MAX
#define PATH_MAX 1024
#endif

/* os_proc_available_memory() is iOS 13+; declare it weak so the dylib still
   loads on anything older instead of failing to bind. */
extern size_t os_proc_available_memory(void) __attribute__((weak_import));

#define VV_MAXLOG 6
#define VV_MAXHOOK 96

/* ====================================================================== log */

static int   gFD[VV_MAXLOG];
static int   gNFD = 0;
static char  gLogPath[VV_MAXLOG][PATH_MAX];
static struct timeval gT0;
static pthread_mutex_t gLogLock = PTHREAD_MUTEX_INITIALIZER;

static void vvWriteAll(const char *buf, size_t len) {
    for (int i = 0; i < gNFD; i++) {
        size_t off = 0;
        while (off < len) {
            ssize_t k = write(gFD[i], buf + off, len - off);
            if (k <= 0) break;
            off += (size_t)k;
        }
    }
}

/* Unbuffered, timestamped, written to every log copy we managed to open.
   fwrite() would have been lost on abort() - that is the whole reason this is
   hand-rolled on top of write(). */
static void VVLog(const char *fmt, ...) {
    char body[1400];
    char line[1500];
    va_list ap;
    int n;

    va_start(ap, fmt);
    vsnprintf(body, sizeof(body), fmt, ap);
    va_end(ap);

    {
        struct timeval now;
        double t;
        gettimeofday(&now, NULL);
        t = (double)(now.tv_sec - gT0.tv_sec) + (double)(now.tv_usec - gT0.tv_usec) / 1e6;
        n = snprintf(line, sizeof(line), "[%8.3f] %s\n", t, body);
    }
    if (n <= 0) return;
    if ((size_t)n >= sizeof(line)) n = (int)sizeof(line) - 1;

    pthread_mutex_lock(&gLogLock);
    vvWriteAll(line, (size_t)n);
    pthread_mutex_unlock(&gLogLock);
}

/* Describes any object in one line, for breadcrumbs.  Never logs (no recursion),
   never throws. */
static const char *vvDesc(id obj) {
    static char buf[320];
    NSString *s;

    if (!obj) return "nil";
    if ((id)obj == [NSNull null]) return "(NSNull)";

    @try {
        if (![obj respondsToSelector:@selector(description)]) return "(no description)";
        s = [obj description];
    } @catch (NSException *e) {
        snprintf(buf, sizeof(buf), "(description threw %s)", e.name.UTF8String ?: "?");
        return buf;
    }
    if (![s isKindOfClass:NSString.class]) return "(non-string)";
    snprintf(buf, sizeof(buf), "%.240s", s.UTF8String ?: "(nil)");
    return buf;
}

/* ==================================================== log file + std streams */

static void vvOpenAt(const char *pattern, const char *home) {
    char path[PATH_MAX];
    int fd;

    if (!home || !*home) return;
    snprintf(path, sizeof(path), pattern, home);
    fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd >= 0 && gNFD < VV_MAXLOG) {
        gFD[gNFD] = fd;
        snprintf(gLogPath[gNFD], PATH_MAX, "%s", path);
        gNFD++;
    }
}

static void VVOpenLogs(void) {
    const char *homes[3];
    int i;

    gettimeofday(&gT0, NULL);

    /* Order matters, and the order is not the obvious one.

       HOME is rewritten by LCBootstrap.m:476 (setenv("HOME", newHomePath)) to the
       *guest* container, and that happens BEFORE the guest bundle is dlopen()ed,
       i.e. before this constructor ever runs.  For a private app newHomePath is
       LiveContainer/Documents/Data/Application/<uuid> -- a directory the Files app
       can actually open.  That is where a log is worth anything, so HOME goes
       first.

       LP_HOME_PATH (LiveProcess/main.m:59) is the LiveProcess extension's OWN
       sandbox.  It is just as writable, which is exactly the trap build 3 fell
       into: every copy landed there and the user had no way to reach a single
       one.  It stays as the last resort, together with LC_HOME_PATH, which is
       LiveContainer's own container and only writable when the guest holds a
       security-scoped bookmark for it. */
    homes[0] = getenv("HOME");
    homes[1] = getenv("LC_HOME_PATH");
    homes[2] = getenv("LP_HOME_PATH");

    for (i = 0; i < 3; i++) {
        /* both spellings: LC's published Documents, and the container root in
           case the directory layout differs on this LiveContainer build */
        vvOpenAt("%s/Documents/VVeboMultiFix.log", homes[i]);
        vvOpenAt("%s/VVeboMultiFix.log", homes[i]);
    }
    vvOpenAt("%s/VVeboMultiFix.log", NSTemporaryDirectory().UTF8String);

    if (gNFD == 0) return;

    /* Mirror the process streams into the primary log.  This is what turns a
       silent signal death into a readable autopsy: the Objective-C runtime,
       Foundation assertions, Swift's fatalError and __builtin_trap all print
       their last words to stderr. */
    dup2(gFD[0], STDOUT_FILENO);
    dup2(gFD[0], STDERR_FILENO);
    setvbuf(stdout, NULL, _IONBF, 0);
    setvbuf(stderr, NULL, _IONBF, 0);

    VVLog("=========== VVeboMultiFix build 4 (log lands in the guest container) ===========");
    for (i = 0; i < gNFD; i++) {
        VVLog("log copy #%d -> %s", i, gLogPath[i]);
    }
}

/* =========================================================== signal autopsy */

/* strsignal() is not worth depending on either. */
static const char *vvSignalName(int sig) {
    switch (sig) {
        case SIGABRT: return "SIGABRT";
        case SIGSEGV: return "SIGSEGV";
        case SIGBUS:  return "SIGBUS";
        case SIGILL:  return "SIGILL";
        case SIGTRAP: return "SIGTRAP";
        case SIGFPE:  return "SIGFPE";
        case SIGSYS:  return "SIGSYS";
        case SIGKILL: return "SIGKILL";
        default:      return "SIG?";
    }
}

static void VVSignalHandler(int sig, siginfo_t *info, void *ucontext) {
    char head[320];
    void *bt[96];
    int n, cnt, i;

    n = snprintf(head, sizeof(head),
                 "\n!!!!! FATAL SIGNAL %d (%s) si_code=%d si_addr=%p ucontext=%p\n",
                 sig, vvSignalName(sig), info ? info->si_code : 0,
                 info ? info->si_addr : NULL, ucontext);
    if (n > 0) {
        for (i = 0; i < gNFD; i++) {
            ssize_t r = write(gFD[i], head, (size_t)n);
            (void)r;
        }
    }

    /* No mutex here: we may have interrupted a thread that holds it. */
    cnt = backtrace(bt, (int)(sizeof(bt) / sizeof(bt[0])));
    for (i = 0; i < gNFD; i++) {
        backtrace_symbols_fd(bt, cnt, gFD[i]);
    }

    /* Restore the default action and re-raise so iOS still files its own crash
       report for the guest. */
    {
        struct sigaction sa;
        memset(&sa, 0, sizeof(sa));
        sa.sa_handler = SIG_DFL;
        sigemptyset(&sa.sa_mask);
        sigaction(sig, &sa, NULL);
    }
    raise(sig);
}

static void VVInstallSignalHandlers(void) {
    static const int sigs[] = { SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGTRAP, SIGFPE, SIGSYS };
    struct sigaction sa;

    memset(&sa, 0, sizeof(sa));
    sa.sa_sigaction = VVSignalHandler;
    sa.sa_flags = SA_SIGINFO | SA_NODEFER;
    sigemptyset(&sa.sa_mask);

    for (unsigned i = 0; i < sizeof(sigs) / sizeof(sigs[0]); i++) {
        sigaction(sigs[i], &sa, NULL);
    }
}

/* ================================================================ heartbeat */

/* Tells "the process was killed from outside" apart from "the process crashed
   inside an API": the former leaves only heartbeats behind, the latter stops
   right after a breadcrumb.  available= is the head-room jetsam looks at. */
static void *VVHeartbeatThread(void *unused) {
    int beat = 0;
    (void)unused;

    for (;;) {
        struct task_vm_info vm;
        mach_msg_type_number_t vmCount = TASK_VM_INFO_COUNT;
        double rss = -1.0, avail = -1.0;
        int threads = 0;
        char extra[128];

        memset(&vm, 0, sizeof(vm));
        if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&vm, &vmCount) == KERN_SUCCESS) {
            rss = (double)vm.resident_size / 1048576.0;
            snprintf(extra, sizeof(extra), "peak=%.1fMB", (double)vm.resident_size_peak / 1048576.0);
        } else {
            snprintf(extra, sizeof(extra), "peak=n/a");
        }
        if (os_proc_available_memory) {
            avail = (double)os_proc_available_memory() / 1048576.0;
        }
        {
            thread_act_array_t acts = NULL;
            mach_msg_type_number_t nacts = 0;
            if (task_threads(mach_task_self(), &acts, &nacts) == KERN_SUCCESS && acts) {
                threads = (int)nacts;
                for (mach_msg_type_number_t i = 0; i < nacts; i++) {
                    mach_port_deallocate(mach_task_self(), acts[i]);
                }
                vm_deallocate(mach_task_self(), (vm_address_t)acts,
                              (vm_size_t)(nacts * sizeof(thread_act_t)));
            }
        }

        VVLog("[beat #%d] rss=%.1fMB %s available=%.1fMB threads=%d",
              beat, rss, extra, avail, threads);
        beat++;

        usleep(beat < 24 ? 250000 : (beat < 60 ? 1000000 : 10000000));
    }
    return NULL;
}

/* ============================================================ mode detection */

/* LiveProcess/main.m:59 setenv()s LP_HOME_PATH before the guest is loaded, so it
   is present in exactly the multitask child.  LiveProcessHandler is a second,
   independent signal: that class lives in LiveProcess.appex and does not exist
   when the guest runs in LiveContainer's own process. */
static int VVIsLiveProcess(void) {
    static int cached = -1;
    const char *lp;

    if (cached >= 0) return cached;
    cached = 0;

    lp = getenv("LP_HOME_PATH");
    if (lp && *lp) {
        cached = 1;
    } else if (NSClassFromString(@"LiveProcessHandler") != Nil) {
        cached = 1;
    }
    return cached;
}

/* ============================================================ environment log */

static void VVDumpEnvironment(void) {
    NSBundle *bundle = [NSBundle mainBundle];
    NSDictionary *info = bundle.infoDictionary;
    const char *lp = getenv("LP_HOME_PATH");
    const char *lc = getenv("LC_HOME_PATH");
    const char *tmp = getenv("TMPDIR");

    VVLog("=========== environment ===========");
    VVLog("pid=%d ppid=%d dyldImages=%u", getpid(), getppid(), _dyld_image_count());
    VVLog("processName  = %s", [NSProcessInfo processInfo].processName.UTF8String);
    VVLog("mainBundle   = %s", bundle.bundlePath.UTF8String);
    VVLog("executable   = %s", bundle.executablePath.UTF8String);
    VVLog("bundleId     = %s", [[info objectForKey:@"CFBundleIdentifier"] description].UTF8String);
    VVLog("shortVersion = %s", [[info objectForKey:@"CFBundleShortVersionString"] description].UTF8String);
    VVLog("minOS        = %s", [[info objectForKey:@"MinimumOSVersion"] description].UTF8String);
    VVLog("systemVersion= %s", [UIDevice currentDevice].systemVersion.UTF8String);
    VVLog("HOME         = %s", getenv("HOME") ?: "(unset)");
    VVLog("LP_HOME_PATH = %s", lp ?: "(unset)");
    VVLog("LC_HOME_PATH = %s", lc ?: "(unset)");
    VVLog("TMPDIR       = %s", tmp ?: "(unset)");
    VVLog("backgroundModes = %s",
          [[info objectForKey:@"UIBackgroundModes"] description].UTF8String ?: "(none)");
    VVLog("sceneManifest   = %s",
          [[info objectForKey:@"UIApplicationSceneManifest"] description].UTF8String ?: "(none)");
    VVLog("extension mode  = %s (LiveProcessHandler=%p)",
          VVIsLiveProcess() ? "MULTITASK CHILD" : "in-process / normal",
          (void *)NSClassFromString(@"LiveProcessHandler"));
    VVLog("UIApplication.shared = %p, delegate = %s",
          (void *)[UIApplication sharedApplication],
          [[[UIApplication sharedApplication] delegate] description].UTF8String ?: "(none)");
    VVLog("guest data dir exists = %d",
          lp ? [[NSFileManager defaultManager] fileExistsAtPath:
                [NSString stringWithFormat:@"%s/Documents/Data/Application", lp]] : 0);
    VVLog("VVeboFix.dylib loaded = %d", dlopen("@rpath/VVeboFix.dylib", RTLD_LAZY | RTLD_NOLOAD) != NULL);
}

/* ================================================================== hooking */

enum {
    K_VOID0 = 0, K_VOID1, K_VOID2, K_VOID3,
    K_BOOL0, K_BOOL1, K_BOOL2,
    K_ID0, K_ID1
};

typedef struct {
    Class cls;
    SEL   sel;
    IMP   orig;
    int   isClass;
    int   kind;
    char  tag[72];
} VVHook;

static VVHook gHooks[VV_MAXHOOK];
static int    gNHooks = 0;

static int vvIsSubclassOf(Class c, Class base) {
    for (Class k = c; k != Nil; k = class_getSuperclass(k)) {
        if (k == base) return 1;
    }
    return 0;
}

/* Both originals are looked up per call so that the breadcrumb can be emitted
   before the real method runs. */
static VVHook *vvFindHook(id self, SEL cmd) {
    VVHook *fallback = NULL;

    for (int i = 0; i < gNHooks; i++) {
        VVHook *h = &gHooks[i];
        if (h->sel != cmd) continue;
        if (!fallback) fallback = h;
        if (h->isClass) {
            if (object_isClass(self) && vvIsSubclassOf((Class)self, h->cls)) return h;
        } else {
            if (!object_isClass(self) && vvIsSubclassOf(object_getClass(self), h->cls)) return h;
        }
    }
    return fallback;
}

#define VV_ORIG0(h, type) ((type)((h) && (h)->orig ? (h)->orig : NULL))

static void vvKindVoid0(id self, SEL cmd) {
    VVHook *h = vvFindHook(self, cmd);
    VVLog("[call ] %s", h ? h->tag : "?");
    if (h && h->orig) ((void (*)(id, SEL))h->orig)(self, cmd);
}
static void vvKindVoid1(id self, SEL cmd, id a1) {
    VVHook *h = vvFindHook(self, cmd);
    VVLog("[call ] %s  arg=%s", h ? h->tag : "?", vvDesc(a1));
    if (h && h->orig) ((void (*)(id, SEL, id))h->orig)(self, cmd, a1);
}
static void vvKindVoid2(id self, SEL cmd, id a1, id a2) {
    VVHook *h = vvFindHook(self, cmd);
    VVLog("[call ] %s  a=%s b=%s", h ? h->tag : "?", vvDesc(a1), vvDesc(a2));
    if (h && h->orig) ((void (*)(id, SEL, id, id))h->orig)(self, cmd, a1, a2);
}
static void vvKindVoid3(id self, SEL cmd, id a1, id a2, id a3) {
    VVHook *h = vvFindHook(self, cmd);
    VVLog("[call ] %s  a=%s b=%s c=%s", h ? h->tag : "?", vvDesc(a1), vvDesc(a2), vvDesc(a3));
    if (h && h->orig) ((void (*)(id, SEL, id, id, id))h->orig)(self, cmd, a1, a2, a3);
}
static BOOL vvKindBOOL0(id self, SEL cmd) {
    VVHook *h = vvFindHook(self, cmd);
    BOOL r = NO;
    VVLog("[call ] %s", h ? h->tag : "?");
    if (h && h->orig) r = ((BOOL (*)(id, SEL))h->orig)(self, cmd);
    VVLog("[ret  ] %s -> %d", h ? h->tag : "?", (int)r);
    return r;
}
static BOOL vvKindBOOL1(id self, SEL cmd, id a1) {
    VVHook *h = vvFindHook(self, cmd);
    BOOL r = NO;
    VVLog("[call ] %s  arg=%s", h ? h->tag : "?", vvDesc(a1));
    if (h && h->orig) r = ((BOOL (*)(id, SEL, id))h->orig)(self, cmd, a1);
    VVLog("[ret  ] %s -> %d", h ? h->tag : "?", (int)r);
    return r;
}
static BOOL vvKindBOOL2(id self, SEL cmd, id a1, id a2) {
    VVHook *h = vvFindHook(self, cmd);
    BOOL r = NO;
    VVLog("[call ] %s  a=%s b=%s", h ? h->tag : "?", vvDesc(a1), vvDesc(a2));
    if (h && h->orig) r = ((BOOL (*)(id, SEL, id, id))h->orig)(self, cmd, a1, a2);
    VVLog("[ret  ] %s -> %d", h ? h->tag : "?", (int)r);
    return r;
}
static id vvKindID0(id self, SEL cmd) {
    VVHook *h = vvFindHook(self, cmd);
    id r = nil;
    VVLog("[call ] %s", h ? h->tag : "?");
    if (h && h->orig) r = ((id (*)(id, SEL))h->orig)(self, cmd);
    VVLog("[ret  ] %s -> %s", h ? h->tag : "?", vvDesc(r));
    return r;
}
static id vvKindID1(id self, SEL cmd, id a1) {
    VVHook *h = vvFindHook(self, cmd);
    id r = nil;
    VVLog("[call ] %s  arg=%s", h ? h->tag : "?", vvDesc(a1));
    if (h && h->orig) r = ((id (*)(id, SEL, id))h->orig)(self, cmd, a1);
    VVLog("[ret  ] %s -> %s", h ? h->tag : "?", vvDesc(r));
    return r;
}

static IMP vvImpForKind(int kind) {
    switch (kind) {
        case K_VOID0: return (IMP)vvKindVoid0;
        case K_VOID1: return (IMP)vvKindVoid1;
        case K_VOID2: return (IMP)vvKindVoid2;
        case K_VOID3: return (IMP)vvKindVoid3;
        case K_BOOL0: return (IMP)vvKindBOOL0;
        case K_BOOL1: return (IMP)vvKindBOOL1;
        case K_BOOL2: return (IMP)vvKindBOOL2;
        case K_ID0:   return (IMP)vvKindID0;
        case K_ID1:   return (IMP)vvKindID1;
        default:      return NULL;
    }
}

static void vvHook(Class cls, const char *selName, int isClass, int kind, const char *tag) {
    SEL sel;
    Method m;
    IMP old;

    if (!cls) {
        VVLog("[hook ] skip %-34s (class missing)", tag);
        return;
    }
    sel = sel_registerName(selName);
    m = isClass ? class_getClassMethod(cls, sel) : class_getInstanceMethod(cls, sel);
    if (!m) {
        VVLog("[hook ] skip %-34s (no selector %s)", tag, selName);
        return;
    }
    old = method_setImplementation(m, vvImpForKind(kind));
    if (gNHooks < VV_MAXHOOK) {
        VVHook *h = &gHooks[gNHooks++];
        h->cls = cls;
        h->sel = sel;
        h->orig = old;
        h->isClass = isClass;
        h->kind = kind;
        snprintf(h->tag, sizeof(h->tag), "%s", tag);
    }
    VVLog("[hook ] %-34s orig=%p", tag, (void *)old);
}

/* ============================================== BGTaskScheduler: the guard */

/* Stand-in scheduler handed to the guest inside the multitask child.  Every call
   the app can make on BGTaskScheduler is accepted and dropped: background
   refresh cannot be delivered to the child in the first place, and the real
   class asserts before it gets that far. */
@interface VVFakeBGTaskScheduler : NSObject
@end

@implementation VVFakeBGTaskScheduler

- (void)registerForTaskWithIdentifier:(id)identifier usingQueue:(id)queue launchHandler:(id)handler {
    VVLog("[guard] fake scheduler: register('%s') swallowed", vvDesc(identifier));
}

- (BOOL)submitTaskRequest:(id)request error:(NSError **)error {
    VVLog("[guard] fake scheduler: submit(%s) swallowed", vvDesc(request));
    if (error) *error = nil;
    return NO;
}

- (void)cancelTaskRequestWithIdentifier:(id)identifier {
    VVLog("[guard] fake scheduler: cancel('%s') swallowed", vvDesc(identifier));
}

- (void)cancelAllTaskRequests {
    VVLog("[guard] fake scheduler: cancelAll swallowed");
}

- (void)getPendingTaskRequestsWithCompletionHandler:(id)handler {
    VVLog("[guard] fake scheduler: getPending -> []");
    if (handler) {
        void (^done)(id) = (void (^)(id))handler;
        done(@[]);
    }
}

@end

static IMP gOrigBGShared;
static IMP gOrigBGRegister;
static IMP gOrigBGSubmit;

static id VVSharedScheduler(id self, SEL cmd) {
    if (VVIsLiveProcess()) {
        static VVFakeBGTaskScheduler *fake;
        if (!fake) fake = [VVFakeBGTaskScheduler new];
        VVLog("[guard] +[BGTaskScheduler sharedScheduler] -> stand-in %p", (void *)fake);
        return fake;
    }
    VVLog("[call ] +[BGTaskScheduler sharedScheduler] (normal mode)");
    return gOrigBGShared ? ((id (*)(id, SEL))gOrigBGShared)(self, cmd) : nil;
}

static void VVBGRegister(id self, SEL cmd, id identifier, id queue, id handler) {
    if (VVIsLiveProcess()) {
        VVLog("[guard] -[BGTaskScheduler registerForTaskWithIdentifier:'%s'] blocked",
              vvDesc(identifier));
        return;
    }
    VVLog("[call ] -[BGTaskScheduler registerForTaskWithIdentifier:'%s'] passthrough",
          vvDesc(identifier));
    if (gOrigBGRegister) {
        ((void (*)(id, SEL, id, id, id))gOrigBGRegister)(self, cmd, identifier, queue, handler);
    }
}

static BOOL VVBGSubmit(id self, SEL cmd, id request, NSError **error) {
    if (VVIsLiveProcess()) {
        VVLog("[guard] -[BGTaskScheduler submitTaskRequest:%s] blocked", vvDesc(request));
        if (error) *error = nil;
        return NO;
    }
    VVLog("[call ] -[BGTaskScheduler submitTaskRequest:%s] passthrough", vvDesc(request));
    return gOrigBGSubmit ? ((BOOL (*)(id, SEL, id, NSError **))gOrigBGSubmit)(self, cmd, request, error)
                         : NO;
}

/* ======================================================= other hard guards */

static IMP gOrigRemoteReg;
static IMP gOrigMinFetch;

/* -[UIApplication registerForRemoteNotifications]: no APNs identity exists for a
   guest running inside the extension, and the call is extension-unavailable. */
static void VVBlockRemoteReg(id self, SEL cmd) {
    if (VVIsLiveProcess()) {
        VVLog("[guard] -[UIApplication registerForRemoteNotifications] blocked");
        return;
    }
    VVLog("[call ] -[UIApplication registerForRemoteNotifications] passthrough");
    if (gOrigRemoteReg) ((void (*)(id, SEL))gOrigRemoteReg)(self, cmd);
}

/* -[UIApplication setMinimumBackgroundFetchInterval:]: deprecated, and likewise
   unavailable to extensions. Double argument, hence the dedicated function. */
static void VVBlockMinFetch(id self, SEL cmd, double interval) {
    if (VVIsLiveProcess()) {
        VVLog("[guard] -[UIApplication setMinimumBackgroundFetchInterval:%.0f] blocked", interval);
        return;
    }
    VVLog("[call ] -[UIApplication setMinimumBackgroundFetchInterval:%.0f] passthrough", interval);
    if (gOrigMinFetch) ((void (*)(id, SEL, double))gOrigMinFetch)(self, cmd, interval);
}

/* ============================================================ flight recorder */

static void VVHookLifecycle(void) {
    Class app = NSClassFromString(@"_TtC5VVebo11AppDelegate");
    Class scene;
    Class browser;
    Class uiapp = [UIApplication class];
    Class cfg = [NSURLSessionConfiguration class];

    if (!app) app = NSClassFromString(@"VVebo.AppDelegate");

    if (app) {
        VVLog("[hook ] AppDelegate class = %s", class_getName(app));
        vvHook(app, "application:willFinishLaunchingWithOptions:", 0, K_BOOL2, "app willFinishLaunching");
        vvHook(app, "application:didFinishLaunchingWithOptions:", 0, K_BOOL2, "app didFinishLaunching");
        vvHook(app, "applicationDidBecomeActive:", 0, K_VOID1, "app didBecomeActive");
        vvHook(app, "applicationWillEnterForeground:", 0, K_VOID1, "app willEnterForeground");
        vvHook(app, "applicationDidEnterBackground:", 0, K_VOID1, "app didEnterBackground");
        vvHook(app, "application:performFetchWithCompletionHandler:", 0, K_VOID2, "app performFetch");
        vvHook(app, "application:handleEventsForBackgroundURLSession:completionHandler:", 0,
               K_VOID3, "app eventsForBackgroundURLSession");
        vvHook(app, "application:didReceiveRemoteNotification:fetchCompletionHandler:", 0,
               K_VOID3, "app didReceiveRemoteNotification");
    } else {
        VVLog("[hook ] !! AppDelegate class not found");
    }

    scene = NSClassFromString(@"_TtC5VVebo13SceneDelegate");
    browser = NSClassFromString(@"_TtC5VVebo19BrowserSceneDelegate");
    if (!scene) scene = NSClassFromString(@"VVebo.SceneDelegate");
    if (!browser) browser = NSClassFromString(@"VVebo.BrowserSceneDelegate");

    VVLog("[hook ] scene delegates: default=%s browser=%s",
          scene ? class_getName(scene) : "nil",
          browser ? class_getName(browser) : "nil");
    if (scene) {
        vvHook(scene, "scene:willConnectToSession:options:", 0, K_VOID3, "scene willConnect");
        vvHook(scene, "sceneDidBecomeActive:", 0, K_VOID1, "scene didBecomeActive");
    }
    if (browser) {
        vvHook(browser, "scene:willConnectToSession:options:", 0, K_VOID3, "browserScene willConnect");
    }

    /* UIApplication / notification / session entry points that are worth a
       breadcrumb even when we let them through: if the log stops right after one
       of these lines, that call is the killer.

       Deliberately NOT hooked: -beginBackgroundTaskWithExpirationHandler: and
       -beginBackgroundTaskWithName:expirationHandler:.  They return an
       NSUInteger identifier, so a void-shaped breadcrumb would hand the app
       garbage, and LiveContainer's own Dead10ccFix.m already swizzles them. */
    vvHook(uiapp, "openURL:options:completionHandler:", 0, K_VOID3, "UIApplication openURL");

    vvHook(NSClassFromString(@"UNUserNotificationCenter"), "currentNotificationCenter", 1, K_ID0,
           "UNUserNotificationCenter.current");
    vvHook(NSClassFromString(@"UNUserNotificationCenter"), "requestAuthorizationWithOptions:completionHandler:",
           0, K_VOID2, "UN requestAuthorization");
    vvHook(NSClassFromString(@"UNUserNotificationCenter"), "addNotificationRequest:withCompletionHandler:",
           0, K_VOID2, "UN addNotificationRequest");

    vvHook(cfg, "backgroundSessionConfigurationWithIdentifier:", 1, K_ID1,
           "URLSessionConfiguration.background");
    vvHook(cfg, "sharedContainerIdentifier", 0, K_ID0, "URLSessionConfiguration.sharedContainer");
}

static void VVInstallGuards(void) {
    Class bg, uiapp;

    /* Force BackgroundTasks in so objc_getClass() can see BGTaskScheduler; the
       app hard-links it already, so this adds no new dependency. */
    dlopen("/System/Library/Frameworks/BackgroundTasks.framework/BackgroundTasks", RTLD_LAZY);

    bg = NSClassFromString(@"BGTaskScheduler");
    VVLog("[hook ] BGTaskScheduler class = %p", (void *)bg);
    if (bg) {
        SEL shared = sel_registerName("sharedScheduler");
        Method m = class_getClassMethod(bg, shared);
        if (m) {
            gOrigBGShared = method_setImplementation(m, (IMP)VVSharedScheduler);
            VVLog("[hook ] BGTaskScheduler sharedScheduler       orig=%p", (void *)gOrigBGShared);
        }

        SEL reg = sel_registerName("registerForTaskWithIdentifier:usingQueue:launchHandler:");
        m = class_getInstanceMethod(bg, reg);
        if (m) {
            gOrigBGRegister = method_setImplementation(m, (IMP)VVBGRegister);
            VVLog("[hook ] BGTaskScheduler register             orig=%p", (void *)gOrigBGRegister);
        }

        SEL sub = sel_registerName("submitTaskRequest:error:");
        m = class_getInstanceMethod(bg, sub);
        if (m) {
            gOrigBGSubmit = method_setImplementation(m, (IMP)VVBGSubmit);
            VVLog("[hook ] BGTaskScheduler submit               orig=%p", (void *)gOrigBGSubmit);
        }
    } else {
        VVLog("[hook ] !! BGTaskScheduler class not found");
    }

    uiapp = [UIApplication class];
    {
        SEL sel = sel_registerName("registerForRemoteNotifications");
        Method m = class_getInstanceMethod(uiapp, sel);
        if (m) {
            gOrigRemoteReg = method_setImplementation(m, (IMP)VVBlockRemoteReg);
            VVLog("[hook ] UIApplication registerForRemoteNotifications orig=%p", (void *)gOrigRemoteReg);
        }
        sel = sel_registerName("setMinimumBackgroundFetchInterval:");
        m = class_getInstanceMethod(uiapp, sel);
        if (m) {
            gOrigMinFetch = method_setImplementation(m, (IMP)VVBlockMinFetch);
            VVLog("[hook ] UIApplication setMinimumBackgroundFetch   orig=%p", (void *)gOrigMinFetch);
        }
    }
}

/* ===================================================================== boot */

__attribute__((constructor))
static void VVeboMultiFixInit(void) {
    @autoreleasepool {
        /* From here on VVLog() is a no-op if we found nowhere to write, but the
           guards still get installed: they may be all this app needs. */
        VVOpenLogs();

        VVLog("constructor fired; liveProcess=%d", VVIsLiveProcess());

        VVInstallSignalHandlers();
        VVLog("signal handlers installed (ABRT/SEGV/BUS/ILL/TRAP/FPE/SYS)");

        /* The constructor runs from inside dyld's dlopen() of the guest image, so
           nothing here may be allowed to throw: an exception escaping a
           constructor would fail the load and hand LiveContainer a bogus error.
           Observation code is wrapped for that reason; the guards are plain
           runtime calls. */
        @try {
            VVDumpEnvironment();
        } @catch (NSException *e) {
            VVLog("!! environment dump threw: %s", e.name.UTF8String ?: "?");
        }

        @try {
            VVInstallGuards();
        } @catch (NSException *e) {
            VVLog("!! installing guards threw: %s", e.name.UTF8String ?: "?");
        }

        @try {
            VVHookLifecycle();
        } @catch (NSException *e) {
            VVLog("!! lifecycle hooks threw: %s", e.name.UTF8String ?: "?");
        }

        if (gNFD > 0) {
            pthread_t th;
            if (pthread_create(&th, NULL, VVHeartbeatThread, NULL) == 0) {
                pthread_detach(th);
                VVLog("heartbeat thread started");
            }
        } else {
            VVLog("!! no writable log file - running guards blind");
        }

        VVLog("=========== guards armed, handing over to VVebo ===========");
    }
}
