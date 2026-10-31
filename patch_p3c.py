# -*- coding: utf-8 -*-
"""P3c patches: PluginLogView call-log section + real MusicFree backup format."""
import io

p = r'Sources\Kumone\Features\Plugins\PluginsView.swift'
s = open(p, encoding='utf-8').read()
changed = []

# 1. PluginLogView: call-log section
old = "struct PluginLogView: View {\n    @State private var entries: [PluginEngine.RequestLogEntry] = []\n"
new = "struct PluginLogView: View {\n    @State private var entries: [PluginEngine.RequestLogEntry] = []\n    @State private var callErrors: [String] = []\n"
if old in s:
    s = s.replace(old, new, 1)
    changed.append("logview-state")

old = "        List {\n            if entries.isEmpty {\n                Text(\"还没有插件请求记录\")\n                    .foregroundStyle(.secondary)\n            } else {\n"
new = "        List {\n            if !callErrors.isEmpty {\n                Section(\"JS 调用失败\") {\n                    ForEach(callErrors, id: \\.self) { line in\n                        Text(line)\n                            .font(.caption.monospacedDigit())\n                            .foregroundStyle(.red)\n                    }\n                }\n            }\n            if entries.isEmpty {\n                Text(\"还没有插件请求记录\")\n                    .foregroundStyle(.secondary)\n            } else {\n"
if old in s:
    s = s.replace(old, new, 1)
    changed.append("logview-section")

old = "        .task {\n            entries = await PluginEngine.shared.snapshotRequestLog()\n        }\n"
new = "        .task {\n            entries = await PluginEngine.shared.snapshotRequestLog()\n            callErrors = await PluginEngine.shared.snapshotCallLog()\n        }\n"
if old in s:
    s = s.replace(old, new, 1)
    changed.append("logview-task")

# 2. Backup format: musicSheets + plugins [{srcUrl, version}]
old = '            // Format 2: MusicFree backup = { playlists: [...], plugins: {...}, ... }.'
new = '            // Format 2: real MusicFree backup = { musicSheets: [...], plugins: [{srcUrl, version}] }.'
if old in s:
    s = s.replace(old, new, 1)
    changed.append("backup-comment")

old = '                let sheets = backup["playlists"] as? [[String: Any]] ?? []'
new = '''                let sheets = (backup["musicSheets"] as? [[String: Any]])
                    ?? (backup["playlists"] as? [[String: Any]]) ?? []'''
if old in s:
    s = s.replace(old, new, 1)
    changed.append("backup-sheets")

old = '''                // Collect bundled plugin code for optional installation.
                var plugins: [(name: String, code: String)] = []
                if let dict = backup["plugins"] as? [String: [String: Any]] {
                    for (name, value) in dict {
                        if let code = value["code"] as? String { plugins.append((name, code)) }
                    }
                } else if let array = backup["plugins"] as? [[String: Any]] {
                    for value in array {
                        if let name = value["name"] as? String, let code = value["code"] as? String {
                            plugins.append((name, code))
                        }
                    }
                }'''
new = '''                // Backup plugins are URLs; install via the mirror-fallback path.
                var pluginURLs: [String] = []
                if let array = backup["plugins"] as? [[String: Any]] {
                    for value in array {
                        if let srcUrl = value["srcUrl"] as? String { pluginURLs.append(srcUrl) }
                    }
                } else if let dict = backup["plugins"] as? [String: [String: Any]] {
                    for (_, value) in dict {
                        if let srcUrl = value["srcUrl"] as? String { pluginURLs.append(srcUrl) }
                    }
                }'''
if old in s:
    s = s.replace(old, new, 1)
    changed.append("backup-plugins")

old = "                if sheets.isEmpty && plugins.isEmpty {"
new = "                if sheets.isEmpty && pluginURLs.isEmpty {"
if old in s:
    s = s.replace(old, new, 1)
    changed.append("backup-guard")

old = "                if !plugins.isEmpty {\n                    backupPlugins = plugins\n                    showBackupPluginsOffer = true\n"
new = "                if !pluginURLs.isEmpty {\n                    backupPluginURLs = pluginURLs\n                    showBackupPluginsOffer = true\n"
if old in s:
    s = s.replace(old, new, 1)
    changed.append("backup-offer")

# 3. URL-based install state + funcs
old = '''    @State private var backupPlugins: [(name: String, code: String)] = []
    @State private var showBackupPluginsOffer = false

    private func installBackupPlugins() async {
        var installed = 0
        for (name, code) in backupPlugins {
            do {
                try await PluginManager.shared.installFromCode(code, sourceName: name)
                installed += 1
            } catch {
                // Keep going with the rest.
            }
        }
        if installed > 0 {
            ToastCenter.shared.show(String(localized: "已从备份安装 \\(installed) 个插件"))
        }
        backupPlugins = []
        showBackupPluginsOffer = false
        dismiss()
    }'''
new = '''    @State private var backupPluginURLs: [String] = []
    @State private var showBackupPluginsOffer = false

    private func installBackupPlugins() async {
        var installed = 0
        for urlString in backupPluginURLs {
            do {
                try await PluginManager.shared.install(fromMirrors: [urlString])
                installed += 1
            } catch {
                // Keep going with the rest.
            }
        }
        if installed > 0 {
            ToastCenter.shared.show(String(localized: "已从备份安装 \\(installed) 个插件"))
        }
        backupPluginURLs = []
        showBackupPluginsOffer = false
        dismiss()
    }'''
if old in s:
    s = s.replace(old, new, 1)
    changed.append("backup-install-funcs")

old = '.alert("备份包含 \\(backupPlugins.count) 个插件"'
new = '.alert("备份包含 \\(backupPluginURLs.count) 个插件"'
if old in s:
    s = s.replace(old, new, 1)
    changed.append("backup-alert-count")

old = "                Button(\"跳过\", role: .cancel) {\n                    backupPlugins = []\n                    dismiss()\n                }"
new = "                Button(\"跳过\", role: .cancel) {\n                    backupPluginURLs = []\n                    dismiss()\n                }"
if old in s:
    s = s.replace(old, new, 1)
    changed.append("backup-alert-skip")

open(p, 'w', encoding='utf-8', newline='\n').write(s)
print("applied:", changed)
print("missing count:", 9 - len(changed))
