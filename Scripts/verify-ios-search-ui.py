from pathlib import Path
import re
import sys

ROOT = Path(__file__).resolve().parents[1]


def read(relative_path):
    return (ROOT / relative_path).read_text(encoding="utf-8")


def require(condition, message):
    if not condition:
        sys.exit(message)


search_view = read("Sources/Kumone/Features/Pages/SearchView.swift")
require("VStack(spacing: 0)" in search_view, "SearchView must place its field in the content VStack")
require("searchField" in search_view, "SearchView must contain an explicit searchField")
require('accessibilityIdentifier("kumone.search.field")' in search_view, "Search field needs the UI test identifier")
require("safeAreaInset(edge: .top" not in search_view, "SearchView must not attach the field through a top safeAreaInset")

main_window = read("Sources/Kumone/Features/IOSMainWindow.swift")
tab_interface = re.search(r"private var tabInterface: some View \{(.*?)\n    \}", main_window, re.S)
require(tab_interface is not None, "IOSMainWindow tabInterface was not found")
tab_interface_body = tab_interface.group(1)
require(re.search(r"^\s*customTabInterface\s*$", tab_interface_body, re.M) is not None, "IOSMainWindow must always use customTabInterface")
require("iOS26TabInterface" not in tab_interface_body, "IOSMainWindow must not route search through iOS26TabInterface")

app_content = re.search(r"private var appContent: some View \{(.*?)\n    \}", main_window, re.S)
require(app_content is not None, "IOSMainWindow appContent was not found")
app_content_body = app_content.group(1)
require("tabInterface" in app_content_body, "IOSMainWindow appContent must render tabInterface")
require(".background {" in app_content_body, "Ambient background must sit behind the tab interface")
require(".overlay {" not in app_content_body, "Ambient background must not cover the tab interface")

glass_tab_bar = read("Sources/Kumone/Features/GlassTabBar.swift")
require("kumone.tab.search" in glass_tab_bar, "GlassTabBar needs a search tab identifier")
require("accessibilityElement(children: .combine)" in glass_tab_bar, "GlassTabBar items must be combined for UI tests")

ui_tests = read("ios/KumoneIOSUITests/KumoneIOSUITests.swift")
require("kumone.search.field" in ui_tests, "UI tests must assert the search field")
require("testSearchTabShowsSearchField" in ui_tests, "UI tests must open the search tab")
require("testSearchFieldIsVisibleFromLaunch" in ui_tests, "UI tests must cover direct search launch")

workflow = read(".github/workflows/build-ios-unsigned.yml")
require("Scripts/verify-ios-search-ui.py" in workflow, "Build workflow must run the source invariant check")
require("Test iOS search UI" in workflow, "Build workflow must run the simulator UI test")
require("BUILD_NUM" in workflow and "'194'" in workflow, "Build workflow must produce a new build number")

print("iOS search UI invariants: OK")
