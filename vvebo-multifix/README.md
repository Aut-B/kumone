# VVebo × LiveContainer 多任务修复（dylib 构建仓库）

给 `VVebo 3.3.31` 打一个补丁动态库，让它在 LiveContainer 的**多任务（Multitask）**模式下也能启动。

## 为什么要单独开一个仓库

本机（Windows）没有 clang、没有 iPhoneOS SDK，只能拿 zig 交叉编译到 macOS 再把
Mach-O 改成 iOS —— 这条路能跑通，但产物是**链接器自签**的签名形态，被 iOS 判为
`code signature invalid`。

iOS 能接受的 ad-hoc 签名长这样（与 `codesign -s -` 的输出一致）：

```
SuperBlob (CSMAGIC_EMBEDDED_SIGNATURE, 3 slots)
  ├─ slot 0x00000000  CSMAGIC_CODEDIRECTORY   v0x20400, flags 0x2, nSpecialSlots 2
  ├─ slot 0x00000002  CSMAGIC_REQUIREMENTS    (空)
  └─ slot 0x00010000  CSMAGIC_BLOBWRAPPER     (空 CMS, 8 字节)
```

所以这里用 GitHub 的 **macOS runner** 跑真 `clang -target arm64-apple-ios14.0` +
`codesign --force --sign -`，产出与官方工具链一致的 dylib。

仓库里**不放 IPA**（22 MB）：workflow 只产出 ~50 KB 的 dylib 作为 artifact，
回本机用 `build_ipa_v2.py` 注入即可。

## 修的是什么

LiveContainer 的多任务不是把 App 载入自己的进程，而是**另起一个 LiveProcess 扩展
子进程**（`LiveProcess.appex`）再托管它的窗口 —— 也就是说 guest App 实际跑在
`NSExtension` 里。

VVebo 的 `AppDelegate` 在 `didFinishLaunchingWithOptions` 里注册后台任务：

```swift
BGTaskScheduler.shared.register(forTaskWithIdentifier: "com.johnil.vvebo.autosign", using: nil) { ... }
```

`-[BGTaskScheduler registerForTaskWithIdentifier:usingQueue:launchHandler:]` 在 SDK
头文件里标注为 **扩展不可用**（*Only the host application may register launch
handlers*）。普通模式没有子进程，永远碰不到这条路。

补丁做的事：在 LiveProcess 子进程里把 `BGTaskScheduler.sharedScheduler`、注册、
提交、取消全部换成自己的**空实现替身**，并拦截 `registerForRemoteNotifications`、
`setMinimumBackgroundFetchInterval:`，**但只在子进程里生效**（`LP_HOME_PATH`
环境变量 + `LiveProcessHandler` 类双重判定），普通启动行为完全不变。

## build 3：还需要把死因录下来

build 2 只拦 BGTaskScheduler，装上后仍然「App 已被终止」。从 LiveContainer 源码
可以确定一件关键的事：

`LiveContainer/LCBootstrap.m:809` 在跳进 guest 之前装了自己的
`NSSetUncaughtExceptionHandler`，并且用 litehook 把符号重绑，**让 guest 无法替换
它**。它的处理函数（`LCBootstrap.m:664`）会把未捕获异常送进
`NSExtensionContext -cancelRequestWithError:`，LiveContainer 会因此**弹出带异常
原因 + 调用栈 + 复制按钮的对话框**。

既然用户看到的是「App 已被终止」而不是那个对话框，说明 guest 不是被
**未捕获 ObjC 异常**打死的，而是**信号级死亡**（Swift trap、SIGABRT、SIGKILL…）。

所以 build 3 做成「守卫 + 飞行记录仪」：

| 探针 | 作用 |
| --- | --- |
| `open()`+`write()` 无缓冲日志 | `fwrite` 缓冲会在 `abort()` 时丢内容，必须绕过 stdio |
| `dup2` 把 stdout/stderr 接到日志 | Swift `fatalError`、断言文案、`*** Terminating app due to uncaught exception` 全落到文件里 |
| `sigaction` 捕获 ABRT/SEGV/BUS/ILL/TRAP/FPE/SYS | 打信号号 + `backtrace_symbols_fd` 栈，再恢复默认处理重新抛出 |
| 心跳线程（250ms→10s） | 打 RSS / `os_proc_available_memory` / 线程数，用来区分「外部击杀（jetsam、启动看门狗）」和「某 API 崩了」 |
| 生命周期面包屑 | AppDelegate / SceneDelegate / `UNUserNotificationCenter` / 后台 URLSession 配置等逐个记「谁被调用了」 |

日志落在 LiveContainer 自己的 Documents 下（`LP_HOME_PATH/Documents`），
LiveContainer 声明了 `UIFileSharingEnabled` + `LSSupportsOpeningDocumentsInPlace`，
所以能在**文件 App → 我的 iPhone → LiveContainer → VVeboMultiFix.log** 里看到。

怎么读日志：

- 末尾出现 `FATAL SIGNAL ...` → 硬崩溃，下面就是调用栈
- 末尾停在某条 `[call ] <api>` → 就是那个 API 打死的
- 末尾是心跳、后面什么都没有 → 被外部杀掉（内存 / 看门狗 / 沙箱），不是崩溃
- 出现 `launch sequence complete` → 其实起来了

## 取产物

```bash
gh run list  --repo Aut-B/kumone --workflow build-vvebo-multifix.yml --limit 3
gh run watch <run_id> --repo Aut-B/kumone --exit-status
gh run download <run_id> --repo Aut-B/kumone --name VVeboMultiFix-dylib --dir dylib
```

本机脚本：`python push_to_kumone.py`（推送 + 等 CI + 拉 dylib），
`python fetch_dylib.py`（只等 + 拉）。

> ⚠️ 用 Git Trees API 造树**必须带 `base_tree`**。build 2 那次没带，等于用只含
> `vvebo-multifix/` 的根树覆盖了整个仓库 —— kumone 自己的文件全被冲掉了。
> `restore_kumone.py` 就是用来从 `292f91a1b0` 还原的，现在 `push_to_kumone.py`
> 已经改成一律带 `base_tree`。

然后在 Windows 侧：

```bash
cd <vvebo 工作目录>
cp dylib/VVeboMultiFix.dylib build/VVeboMultiFix.dylib
python build_ipa_v2.py          # 注入 + 重打包
```

## 校验

workflow 里的 `verify_shape.py` 会硬性检查（任一条不过就让构建失败）：

- `cputype == arm64`、`MH_DYLIB`、`LC_BUILD_VERSION.platform == 2`（iOS）
- SuperBlob 三个槽齐全、`CodeDirectory.flags == 0x2`、`nSpecialSlots == 2`
- 所有页哈希与文件内容一致、`codeLimit == 签名偏移`、`__LINKEDIT` 覆盖到 EOF
- 签名块正好结束于文件尾

本机也可以直接跑：`python verify_shape.py VVeboMultiFix.dylib`
