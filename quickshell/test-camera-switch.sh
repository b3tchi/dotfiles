#!/bin/sh
# Headless tests of the lens switch (sp046 T4). No camera.
#   test-camera-switch.qml  config/Common/CameraSwitch.js (pure selection + plan)
#   test-lens-switch.qml    config/Common/LensSwitch.qml against a stub
#                           CameraSource (calibration-before-id order,
#                           settling guard, failed start)
cd "$(dirname "$0")" || exit 1
export QT_QPA_PLATFORM=offscreen
rc=0
/usr/lib/qt6/bin/qmltestrunner -input test-camera-switch.qml || rc=1
/usr/lib/qt6/bin/qmltestrunner -input test-lens-switch.qml || rc=1
exit $rc
