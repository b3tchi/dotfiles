#!/bin/sh
# Headless test of config/Common/CameraSwitch.js (sp046 T4). No camera.
cd "$(dirname "$0")" || exit 1
QT_QPA_PLATFORM=offscreen exec /usr/lib/qt6/bin/qmltestrunner -input test-camera-switch.qml
