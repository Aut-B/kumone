#!/usr/bin/env bash
set -euo pipefail

SIM_UDID="$(xcrun simctl list devices available -j | python3 Scripts/select-iphone-simulator.py)"
echo "Using simulator: $SIM_UDID"
xcrun simctl boot "$SIM_UDID" || true
xcrun simctl bootstatus "$SIM_UDID" -b

xcodebuild -workspace ios/KumoneIOS.xcworkspace -scheme KumoneIOS \
  -configuration Debug -destination "platform=iOS Simulator,id=$SIM_UDID" \
  -derivedDataPath "$RUNNER_TEMP/search-ui-dd" \
  -only-testing:KumoneIOSUITests/KumoneIOSUITests \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  MARKETING_VERSION="$MARKETING" CURRENT_PROJECT_VERSION="$BUILD_NUM" \
  IPHONEOS_DEPLOYMENT_TARGET="$DEPLOY_TARGET" \
  test
