#!/bin/sh
# Headless test of config/Common/CameraReadout.js (sp045 T6). No camera.
cd "$(dirname "$0")" || exit 1
QT_QPA_PLATFORM=offscreen exec /usr/lib/qt6/bin/qmltestrunner -input test-camera-readout.qml
