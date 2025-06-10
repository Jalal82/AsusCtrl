import QtQuick
import QtQuick.Controls 2.15 as QQC2
import QtQuick.Controls 2.15
import QtQuick.Layouts
import QtQuick.Layouts 1.15
import org.kde.kirigami 2.20 as Kirigami
import org.kde.plasma.components 3.0 as PC3
import org.kde.plasma.core as PlasmaCore
import org.kde.plasma.extras as PlasmaExtras

Window {
    // Dark background
    // property real currentPL1: 0
    // property real currentPL2: 0
    // property real minPowerLimit: 5
    // property real maxPowerLimit: 95

    id: advancedWindow

    property var rootItem: null
    // Properties to receive from main window
    property bool cpuBoostEnabled: true
    property int currentPL1: 45
    property int currentPL2: 65
    property int minPowerLimit: 15
    property int maxPowerLimit: 95
    property int gpuClockOffset: 0
    property int gpuMemOffset: 0
    property int gpuTargetTemp: 85
    property bool commandsRunning: false
    // Define dark theme colors
    property color textColor: "#ffffff"
    property color disabledTextColor: "#888888"
    property color highlightColor: "#9daee9"
    property color backgroundColor: "#3f454b"
    property color alternateBackgroundColor: "#353535"
    // Function to run commands (passed from main window)
    property var runCommandFunc: function(type, value) {
        console.log("Command would run:", type, value);
    }
    property bool isWindowReady: true  // Always ready for immediate interaction
    property bool isPL1Dragging: false
    property bool isPL2Dragging: false
    property bool isUpdatingLedStates: false // New flag to prevent toggle loop
    // Add LED power/mode state properties
    property bool ledBoot: true
    property bool ledAwake: true
    property bool ledSleep: true
    property bool ledShutdown: true
    property int ledMode: 0 // 0: static, 1: breath, 10: fast

    // Signal when window is closed
    signal windowClosed()

    function updateValues() {
        // Update properties from root without recreating the window
        if (!rootItem) {
            console.log("AdvancedControlsWindow: rootItem is null/undefined, skipping update");
            return;
        }
        
        try {
            // Only update if not currently dragging to avoid interrupting user interaction
            if (!isPL1Dragging) {
                cpuBoostEnabled = rootItem.cpuBoostEnabled || false;
                currentPL1 = rootItem.currentPL1 || 0;
            }
            if (!isPL2Dragging) {
                currentPL2 = rootItem.currentPL2 || 0;
            }
            
            gpuClockOffset = rootItem.gpuClockOffset || 0;
            gpuMemOffset = rootItem.gpuMemOffset || 0;
            gpuTargetTemp = rootItem.gpuTargetTemp || 85;
            commandsRunning = rootItem.commandsRunning || false;
            
            // Set flag before updating LED properties to prevent onCheckedChanged from firing
            isUpdatingLedStates = true;
            ledBoot = rootItem.ledBoot !== undefined ? rootItem.ledBoot : true;
            ledAwake = rootItem.ledAwake !== undefined ? rootItem.ledAwake : true;
            ledSleep = rootItem.ledSleep !== undefined ? rootItem.ledSleep : true;
            ledShutdown = rootItem.ledShutdown !== undefined ? rootItem.ledShutdown : true;
            ledMode = rootItem.ledMode !== undefined ? rootItem.ledMode : 0;
            isUpdatingLedStates = false; // Reset flag after update
        } catch (error) {
            console.log("AdvancedControlsWindow: Error updating values:", error);
            isUpdatingLedStates = false; // Reset flag on error
        }
    }

    function updatePowerLimits() {
        // Use runCommandFunc instead of execHelper
        runCommandFunc("power-limits", "", function(output) {
            let lines = output.trim().split('\n');
            if (lines.length >= 4) {
                currentPL1 = parseFloat(lines[0]);
                currentPL2 = parseFloat(lines[1]);
                minPowerLimit = parseFloat(lines[2]);
                maxPowerLimit = parseFloat(lines[3]);
                // Update slider values without triggering onMoved
                pl1Slider.value = currentPL1;
                pl2Slider.value = currentPL2;
            }
        });
    }

    function setPowerLimits(pl1, pl2) {
        // Use runCommandFunc instead of execHelper
        runCommandFunc("set-power-limits", pl1 + " " + pl2, function(output) {
            // Refresh values after setting
            updatePowerLimits();
        });
    }

    function updateLedStatesFromStatus(status) {
        // status: {led_power: {boot:bool, awake:bool, sleep:bool, shutdown:bool}, led_mode:int}
        if (status && status.led_power) {
            ledBoot = status.led_power.boot;
            ledAwake = status.led_power.awake;
            ledSleep = status.led_power.sleep;
            ledShutdown = status.led_power.shutdown;
        }
    }

    function setLedPowerStates() {
        let bootState = bootLedCheckbox.checked ? 1 : 0;
        let awakeState = awakeLedCheckbox.checked ? 1 : 0;
        let sleepState = sleepLedCheckbox.checked ? 1 : 0;
        let shutdownState = shutdownLedCheckbox.checked ? 1 : 0;
        runCommandFunc("ledpower", bootState + " " + awakeState + " " + sleepState + " " + shutdownState);
    }

    width: 400
    height: 400
    title: i18n("Advanced Controls")
    // Set dark colors directly
    color: "#2a2e32"
    // Close event handler
    onClosing: {
        windowClosed();
    }
    Component.onCompleted: {
        // Immediate UI activation - set all controls as ready
        console.log("AdvancedControlsWindow: Ready for immediate interaction");
        
        // Enable immediate interaction by setting a ready state
        Qt.callLater(function() {
            // Ensure all UI elements are enabled for immediate use
            if (rootItem) {
                updateValues();
            }
        });
    }

    // Main content
    ColumnLayout {
        anchors.fill: parent
        spacing: 0

        QQC2.TabBar {
            id: tabBar

            width: parent.width

            QQC2.TabButton {
                text: i18n("CPU Controls")

                // Style for dark theme
                contentItem: PC3.Label {
                    text: parent.text
                    color: textColor
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                }

                background: Rectangle {
                    color: parent.checked ? highlightColor : "transparent"
                    opacity: parent.checked ? 0.2 : 1
                    radius: 1
                }

            }

            // QQC2.TabButton {
            //     text: i18n("GPU Controls")

            //     // Style for dark theme
            //     contentItem: PC3.Label {
            //         text: parent.text
            //         color: textColor
            //         horizontalAlignment: Text.AlignHCenter
            //         verticalAlignment: Text.AlignVCenter
            //     }

            //     background: Rectangle {
            //         color: parent.checked ? highlightColor : "transparent"
            //         opacity: parent.checked ? 0.2 : 1
            //         radius: 1
            //     }

            // }

            QQC2.TabButton {
                text: i18n("Settings")

                contentItem: PC3.Label {
                    text: parent.text
                    color: textColor
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                }

                background: Rectangle {
                    color: parent.checked ? highlightColor : "transparent"
                    opacity: parent.checked ? 0.2 : 1
                    radius: 1
                }

            }

        }

        StackLayout {
            // GPU Controls Tab
            // Item {
            //     ColumnLayout {
            //         anchors.fill: parent
            //         spacing: 12 // Use a fixed value
            //         // GPU Clock Offset
            //         QQC2.GroupBox {
            //             title: i18n(" GPU Clock Offset")
            //             Layout.fillWidth: true
            //             ColumnLayout {
            //                 anchors.fill: parent
            //                 RowLayout {
            //                     Layout.fillWidth: true
            //                     QQC2.Slider {
            //                         id: gpuClockSlider
            //                         Layout.fillWidth: true
            //                         from: -100
            //                         to: 200
            //                         stepSize: 5
            //                         value: gpuClockOffset
            //                         enabled: !commandsRunning
            //                         onPressedChanged: {
            //                             if (!pressed && value !== gpuClockOffset)
            //                                 runCommandFunc("gpuclock", value);
            //                         }
            //                     }
            //                     PC3.Label {
            //                         text: gpuClockSlider.value + " MHz"
            //                         horizontalAlignment: Text.AlignRight
            //                         Layout.minimumWidth: 70
            //                         color: textColor
            //                     }
            //                 }
            //                 PC3.Label {
            //                     text: i18n("Adjusts the GPU core clock offset. Positive values increase performance but may cause instability.")
            //                     wrapMode: Text.WordWrap
            //                     Layout.fillWidth: true
            //                     font.italic: true
            //                     opacity: 0.7
            //                     color: textColor
            //                 }
            //             }
            //             // Style for dark theme
            //             background: Rectangle {
            //                 color: backgroundColor
            //                 border.color: disabledTextColor
            //                 border.width: 0
            //                 radius: 2
            //             }
            //             label: PC3.Label {
            //                 text: parent.title
            //                 color: textColor
            //                 font.bold: true
            //             }
            //         }
            //         // GPU Memory Offset
            //         QQC2.GroupBox {
            //             title: i18n(" GPU Memory Offset")
            //             Layout.fillWidth: true
            //             ColumnLayout {
            //                 anchors.fill: parent
            //                 RowLayout {
            //                     Layout.fillWidth: true
            //                     QQC2.Slider {
            //                         id: gpuMemSlider
            //                         Layout.fillWidth: true
            //                         from: -100
            //                         to: 1000
            //                         stepSize: 50
            //                         value: gpuMemOffset
            //                         enabled: !commandsRunning
            //                         onPressedChanged: {
            //                             if (!pressed && value !== gpuMemOffset)
            //                                 runCommandFunc("gpumem", value);
            //                         }
            //                     }
            //                     PC3.Label {
            //                         text: gpuMemSlider.value + " MHz"
            //                         horizontalAlignment: Text.AlignRight
            //                         Layout.minimumWidth: 70
            //                         color: textColor
            //                     }
            //                 }
            //                 PC3.Label {
            //                     text: i18n("Adjusts the GPU memory clock offset. Higher values may improve performance in memory-bound applications.")
            //                     wrapMode: Text.WordWrap
            //                     Layout.fillWidth: true
            //                     font.italic: true
            //                     opacity: 0.7
            //                     color: textColor
            //                 }
            //             }
            //             // Style for dark theme
            //             background: Rectangle {
            //                 color: backgroundColor
            //                 border.color: disabledTextColor
            //                 border.width: 0
            //                 radius: 2
            //             }
            //             label: PC3.Label {
            //                 text: parent.title
            //                 color: textColor
            //                 font.bold: true
            //             }
            //         }
            //         // GPU Target Temperature
            //         QQC2.GroupBox {
            //             title: i18n(" GPU Target Temperature")
            //             Layout.fillWidth: true
            //             ColumnLayout {
            //                 anchors.fill: parent
            //                 RowLayout {
            //                     Layout.fillWidth: true
            //                     QQC2.Slider {
            //                         id: gpuTempSlider
            //                         Layout.fillWidth: true
            //                         from: 60
            //                         to: 95
            //                         stepSize: 1
            //                         value: gpuTargetTemp
            //                         enabled: !commandsRunning
            //                         onPressedChanged: {
            //                             if (!pressed && value !== gpuTargetTemp)
            //                                 runCommandFunc("gputemp", value);
            //                         }
            //                     }
            //                     PC3.Label {
            //                         text: gpuTempSlider.value + " °C"
            //                         horizontalAlignment: Text.AlignRight
            //                         Layout.minimumWidth: 50
            //                         color: textColor
            //                     }
            //                 }
            //                 PC3.Label {
            //                     text: i18n("Sets the target temperature for the GPU. Lower values will cause the fans to spin up sooner and may reduce performance.")
            //                     wrapMode: Text.WordWrap
            //                     Layout.fillWidth: true
            //                     font.italic: true
            //                     opacity: 0.7
            //                     color: textColor
            //                 }
            //             }
            //             // Style for dark theme
            //             background: Rectangle {
            //                 color: backgroundColor
            //                 border.color: disabledTextColor
            //                 border.width: 0
            //                 radius: 2
            //             }
            //             label: PC3.Label {
            //                 text: parent.title
            //                 color: textColor
            //                 font.bold: true
            //             }
            //         }
            //         Item {
            //             Layout.fillHeight: true
            //         }
            //     }
            // }

            Layout.fillWidth: true
            Layout.fillHeight: true
            Layout.margins: 12 // Use a fixed value instead of Kirigami.Units
            currentIndex: tabBar.currentIndex

            // CPU Controls Tab
            Item {
                ColumnLayout {
                    anchors.fill: parent
                    spacing: 12 // Use a fixed value

                    // CPU Boost Control
                    QQC2.GroupBox {
                        title: i18n(" CPU Boost Control")
                        Layout.fillWidth: true

                        ColumnLayout {
                            anchors.fill: parent

                            PC3.Label {
                                text: i18n("Current status: %1", cpuBoostEnabled ? i18n("Enabled") : i18n("Disabled"))
                                font.bold: true
                                color: textColor
                            }

                            RowLayout {
                                Layout.fillWidth: true
                                spacing: 8 // Use a fixed value

                                PC3.Button {
                                    text: i18n("Enable")
                                    icon.name: "arrow-up"
                                    highlighted: cpuBoostEnabled
                                    enabled: !cpuBoostEnabled  // Always enabled when not already in this state
                                    Layout.fillWidth: true
                                    onClicked: {
                                        // Optimistic UI update for instant feedback
                                        cpuBoostEnabled = true;
                                        runCommandFunc("turbo", "1");
                                    }
                                }

                                PC3.Button {
                                    text: i18n("Disable")
                                    icon.name: "arrow-down"
                                    highlighted: !cpuBoostEnabled
                                    enabled: cpuBoostEnabled  // Always enabled when not already in this state
                                    Layout.fillWidth: true
                                    onClicked: {
                                        // Optimistic UI update for instant feedback
                                        cpuBoostEnabled = false;
                                        runCommandFunc("turbo", "0");
                                    }
                                }

                            }

                            PC3.Label {
                                text: i18n("Disabling CPU boost can reduce heat and power consumption, but may impact performance.")
                                wrapMode: Text.WordWrap
                                Layout.fillWidth: true
                                font.italic: true
                                opacity: 0.7
                                color: textColor
                            }

                        }

                        // Style for dark theme
                        background: Rectangle {
                            color: backgroundColor
                            border.color: disabledTextColor
                            border.width: 0
                            radius: 2
                        }

                        label: PC3.Label {
                            text: parent.title
                            color: textColor
                            font.bold: true
                        }

                    }

                    // CPU Power Limits
                    QQC2.GroupBox {
                        title: i18n(" CPU Power Limits")
                        Layout.fillWidth: true

                        ColumnLayout {
                            anchors.fill: parent
                            spacing: 8 // Use a fixed value

                            PC3.Label {
                                text: i18n("PL1 (Sustained Power Limit)")
                                font.bold: true
                                color: textColor
                            }

                            RowLayout {
                                Layout.fillWidth: true

                                QQC2.Slider {
                                    id: pl1Slider

                                    Layout.fillWidth: true
                                    from: minPowerLimit
                                    to: maxPowerLimit
                                    stepSize: 5
                                    value: currentPL1
                                    enabled: true  // Always enabled for immediate interaction
                                    onPressedChanged: {
                                        if (pressed) {
                                            isPL1Dragging = true;
                                        } else {
                                            isPL1Dragging = false;
                                            if (value !== currentPL1 || pl2Slider.value !== currentPL2) {
                                                // Optimistic UI update for instant feedback
                                                currentPL1 = value;
                                                currentPL2 = pl2Slider.value;
                                                runCommandFunc("set-power-limits", value + " " + pl2Slider.value);
                                            }
                                        }
                                    }
                                }

                                PC3.Label {
                                    text: pl1Slider.value + " W"
                                    horizontalAlignment: Text.AlignRight
                                    Layout.minimumWidth: 50
                                    color: textColor
                                }

                            }

                            PC3.Label {
                                text: i18n("PL2 (Burst Power Limit)")
                                font.bold: true
                                Layout.topMargin: 12 // Use a fixed value
                                color: textColor
                            }

                            RowLayout {
                                Layout.fillWidth: true

                                QQC2.Slider {
                                    id: pl2Slider

                                    Layout.fillWidth: true
                                    from: minPowerLimit
                                    to: maxPowerLimit
                                    stepSize: 5
                                    value: currentPL2
                                    enabled: true  // Always enabled for immediate interaction
                                    onPressedChanged: {
                                        if (pressed) {
                                            isPL2Dragging = true;
                                        } else {
                                            isPL2Dragging = false;
                                            if (value !== currentPL2 || pl1Slider.value !== currentPL1) {
                                                // Optimistic UI update for instant feedback
                                                currentPL1 = pl1Slider.value;
                                                currentPL2 = value;
                                                runCommandFunc("set-power-limits", pl1Slider.value + " " + value);
                                            }
                                        }
                                    }
                                }

                                PC3.Label {
                                    text: pl2Slider.value + " W"
                                    horizontalAlignment: Text.AlignRight
                                    Layout.minimumWidth: 50
                                    color: textColor
                                }

                            }

                            PC3.Label {
                                text: i18n("PL1 is the sustained power limit. PL2 is the short-term burst limit.")
                                wrapMode: Text.WordWrap
                                Layout.fillWidth: true
                                font.italic: true
                                opacity: 0.7
                                color: textColor
                            }

                        }

                        // Style for dark theme
                        background: Rectangle {
                            color: backgroundColor
                            border.color: disabledTextColor
                            border.width: 0
                            radius: 2
                        }

                        label: PC3.Label {
                            text: parent.title
                            color: textColor
                            font.bold: true
                        }

                    }

                    Item {
                        Layout.fillHeight: true
                    }

                }

            }

            // Settings Tab (LED Power/Modes)
            Item {
                ColumnLayout {
                    anchors.fill: parent
                    spacing: 12

                    QQC2.GroupBox {
                        title: i18n("Keyboard LED Power States")
                        Layout.fillWidth: true

                        ColumnLayout {
                            anchors.fill: parent

                            GridLayout {
                                columns: 2
                                rowSpacing: 8
                                columnSpacing: 16

                                QQC2.CheckBox {
                                    id: bootLedCheckbox

                                    text: i18n("Boot")
                                    checked: ledBoot
                                    onCheckedChanged: {
                                        if (!isUpdatingLedStates)
                                            setLedPowerStates();

                                    }
                                }

                                QQC2.CheckBox {
                                    id: awakeLedCheckbox

                                    text: i18n("Awake")
                                    checked: ledAwake
                                    onCheckedChanged: {
                                        if (!isUpdatingLedStates)
                                            setLedPowerStates();

                                    }
                                }

                                QQC2.CheckBox {
                                    id: sleepLedCheckbox

                                    text: i18n("Sleep")
                                    checked: ledSleep
                                    onCheckedChanged: {
                                        if (!isUpdatingLedStates)
                                            setLedPowerStates();

                                    }
                                }

                                QQC2.CheckBox {
                                    id: shutdownLedCheckbox

                                    text: i18n("Shutdown")
                                    checked: ledShutdown
                                    onCheckedChanged: {
                                        if (!isUpdatingLedStates)
                                            setLedPowerStates();

                                    }
                                }

                            }

                            PC3.Label {
                                text: i18n("Configure when the keyboard backlight is on.")
                                wrapMode: Text.WordWrap
                                opacity: 0.7
                                color: textColor
                            }

                        }

                        background: Rectangle {
                            color: backgroundColor
                            border.color: disabledTextColor
                            border.width: 0
                            radius: 2
                        }

                        label: PC3.Label {
                            text: parent.title
                            color: textColor
                            font.bold: true
                        }

                    }

                    Item {
                        Layout.fillHeight: true
                    }

                }

            }

        }

    }

}
