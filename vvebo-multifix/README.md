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
handlers*）。在扩展进程里调用它会触发框架内部断言 → 抛
`NSInternalInconsistencyException` → `abort()` → **子进程当场死亡** →
LiveContainer 显示「App 已被终止」。普通模式没有子进程，永远碰不到这条路。

补丁做的事：拦截这个注册（以及 `registerForRemoteNotifications`），**但只在
LiveProcess 子进程里生效**（`LP_HOME_PATH` 环境变量 + `LiveProcessHandler` 类双重判定），
普通启动行为完全不变。

## 取产物

```bash
gh run list  --repo Aut-B/vvebo-multifix --limit 3
gh run watch <run_id> --repo Aut-B/vvebo-multifix --exit-status
gh run download <run_id> --repo Aut-B/vvebo-multifix \
   --name VVeboMultiFix-dylib --dir dylib
```

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
