from pathlib import Path
import json
import re
import shutil
import subprocess
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
require("-kumone.search.tab" in main_window, "IOSMainWindow must support the direct search-tab launch argument")
require("-kumone.ui.test" in main_window, "IOSMainWindow must disable launch-time update checks in UI tests")
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
require("-kumone.ui.test" in ui_tests, "UI tests must disable launch-time update checks")

workflow = read(".github/workflows/build-ios-unsigned.yml")
require("Scripts/verify-ios-search-ui.py" in workflow, "Build workflow must run the source invariant check")
require("Test iOS search UI" in workflow, "Build workflow must run the simulator UI test")
require("BUILD_NUM" in workflow and "'194'" in workflow, "Build workflow must produce a new build number")

def parse_workflow_yaml(source):
    try:
        import yaml as pyyaml
    except ImportError:
        pyyaml = None
    if pyyaml is not None:
        try:
            return pyyaml.safe_load(source)
        except pyyaml.YAMLError as error:
            sys.exit(f"Build workflow YAML is invalid: {error}")
    ruby = shutil.which("ruby")
    require(ruby is not None, "PyYAML or Ruby is required to validate the build workflow")
    workflow_path = ROOT / ".github/workflows/build-ios-unsigned.yml"
    result = subprocess.run(
        [
            ruby,
            "-ryaml",
            "-rjson",
            "-e",
            "print JSON.generate(YAML.safe_load(File.read(ARGV[0])))",
            str(workflow_path),
        ],
        capture_output=True,
        text=True,
        check=False,
    )
    require(result.returncode == 0, f"Build workflow YAML is invalid: {result.stderr.strip()}")
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError as error:
        sys.exit(f"Build workflow YAML could not be parsed: {error}")


parsed_workflow = parse_workflow_yaml(workflow)
require(isinstance(parsed_workflow, dict), "Build workflow must parse as a YAML mapping")
build_job = parsed_workflow.get("jobs", {}).get("build-ios", {})
steps = build_job.get("steps", [])
require(
    any(step.get("name") == "Test iOS search UI" for step in steps),
    "Parsed workflow must contain the simulator UI test step",
)
require(
    any(step.get("name") == "Build iOS app (unsigned)" for step in steps),
    "Parsed workflow must contain the unsigned IPA build step",
)

test_script = read("Scripts/test-ios-search-ui.sh")
selector_script = read("Scripts/select-iphone-simulator.py")
require("Scripts/select-iphone-simulator.py" in test_script, "Simulator UI test must use the selector script")
require("-only-testing:KumoneIOSUITests/KumoneIOSUITests" in test_script, "Simulator UI test must target the search UI tests")
require("json.load(sys.stdin)" in selector_script, "Simulator selector must read simctl's JSON output")

simulator_fixture = {
    "devices": {
        "com.apple.CoreSimulator.SimRuntime.iOS-17-0": [
            {"name": "iPhone 15 Pro Max", "udid": "OLDER-PRO-MAX", "isAvailable": True},
        ],
        "com.apple.CoreSimulator.SimRuntime.iOS-26-0": [
            {"name": "iPhone 17", "udid": "NEWER-STANDARD", "isAvailable": True},
            {"name": "iPhone 17 Pro Max", "udid": "NEWEST-PRO-MAX", "isAvailable": True},
            {"name": "iPad Pro", "udid": "TABLET", "isAvailable": True},
        ],
    }
}
selection = subprocess.run(
    [sys.executable, str(ROOT / "Scripts/select-iphone-simulator.py")],
    input=json.dumps(simulator_fixture),
    capture_output=True,
    text=True,
    check=False,
)
require(selection.returncode == 0, f"Simulator selector failed: {selection.stderr.strip()}")
require(
    selection.stdout.strip() == "NEWEST-PRO-MAX",
    "Simulator selector must prefer the newest iOS Pro Max over older Pro Max models",
)

print("iOS search UI invariants: OK")
