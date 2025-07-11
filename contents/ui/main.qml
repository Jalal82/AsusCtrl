/*
SPDX-FileCopyrightText: 2023 Your Name <your.email@example.com>
SPDX-FileCopyrightText: 2021 Janghyub Seo <jhyub06@gmail.com> // Original template author
SPDX-License-Identifier: MPL-2.0
 plasmawindowed org.kde.plasma.asustufcontrol
*/
// End PlasmoidItem

import QtQuick
import QtQuick.Controls
import QtQuick.Controls 2.15 as QQC2
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import org.kde.ksvg as KSvg
import org.kde.plasma.components as PlasmaComponents
import org.kde.plasma.components 3.0 as PC3
import org.kde.plasma.core as PlasmaCore
import org.kde.plasma.extras as PlasmaExtras
import org.kde.plasma.plasma5support 2.0 as P5Support
import org.kde.plasma.plasmoid

PlasmoidItem {
    id: root

    property int minChargeLimit: 50 // Sensible minimum
    readonly property int maxChargeLimit: 100
    // --- State Properties ---
    property string currentPowerProfile: "Balanced"
    // Default assumption
    property string currentGpuMode: "hybrid"
    // Default assumption
    property string ui_profile: "Balanced"
    property int currentChargeLimit: 100 // Default assumption
    property bool commandsRunning: false
    property bool needsLogout: false
    property string cpuFanSpeed: "N/A"
    property string gpuFanSpeed: "N/A"
    property string cpuTemp: "N/A"
    // Add these properties to the PlasmoidItem
    property bool cpuBoostEnabled: true
    property int currentPL1: 45
    property int currentPL2: 65
    property int gpuClockOffset: 0
    property int gpuMemOffset: 0
    property int gpuTargetTemp: 85
    property var advancedControlsWindow: null
    // Add these properties to the PlasmoidItem section at the top
    property int minPowerLimit: 5
    property int maxPowerLimit: 95
    // Display settings properties
    property bool panelOverdrive: false
    property int chargeMode: 1
    property int batteryChargingStatus: 0  // 0=discharging, 1=AC charging, 2=Type-C charging, 3=fully charged, 4=plugged but not charging
    property var supportedRefreshRates: [60, 120, 144]
    property int currentRefreshRate: 60
    property bool autoDisplayMode: false
    property var previousChargeMode: -1
    // Add service status properties
    property string asusctlStatus: "2"  // 1=active, 0=inactive, 2=not found
    property string supergfxdStatus: "2"
    property string nvidiaPowardStatus: "2"
    // Add path resolution property
    readonly property string scriptPath: "/home/hazer/.local/share/plasma/plasmoids/org.kde.plasma.asustufcontrol/contents/scripts/helper.py"
    // Add command queue management
    property var commandQueue: []
    property bool isProcessingCommand: false
    property var currentCommand: null
    // Add property to store dialog reference
    property var logoutDialogInstance: null
    // Add debug logging function near the top properties with enhanced null protection
    property bool debugMode: {
        try {
            return (plasmoid.configuration && plasmoid.configuration.debugMode !== undefined) 
                   ? plasmoid.configuration.debugMode : false;
        } catch (e) {
            console.log("Error accessing plasmoid.configuration.debugMode, defaulting to false");
            return false;
        }
    }
    property var statusUpdateTimer: null
    property var dbusWatcher: null
    // Add UI update debouncing
    property var uiUpdateTimer: null
    readonly property var powerProfileReverseMap: ({
        "Silent": 'power-saver',
        "Balanced": 'balanced',
        "Performance": 'performance'
    })
    readonly property var gpuModeReverseMap: ({
        "hybrid": 'Hybrid',
        "integrated": 'Integrated',
        "vfio": 'Vfio',
        "asusmuxdiscreet": 'Asusmuxdiscreet',
        "egpu": 'Egpu',
        "asusmuxdgpu": 'Dedicated'
    })
    // Add this to the properties section at the top
    signal advancedControlsUpdated()
    
    // Add property to track initial system state loading
    property bool isInitialStartup: true
    // Add properties for optimistic UI updates with rollback capability
    property string previousPowerProfile: ""
    property string previousGpuMode: ""
    property int previousChargeLimit: -1
    property bool previousCpuBoostEnabled: false
    property int previousPL1: -1
    property int previousPL2: -1
    property bool pendingUIRevert: false
    property var revertTimer: null

    // Handle widget expand/collapse to optimize CPU usage
    onExpandedChanged: {
        log("Widget expanded state changed to: " + expanded);
        
        if (expanded) {
            // Widget is being opened - start status updates
            log("Widget expanded, starting status updates");
            if (statusUpdateTimer && !statusUpdateTimer.running) {
                statusUpdateTimer.start();
                // Also trigger an immediate status update when opening
                Qt.callLater(updateStatus);
            }
        } else {
            // Widget is being minimized - stop status updates to save CPU
            log("Widget collapsed, stopping status updates to save CPU");
            if (statusUpdateTimer && statusUpdateTimer.running) {
                statusUpdateTimer.stop();
            }
        }
    }

    // Add this helper function before the DataSource
    function cleanStatusValue(line) {
        // Extract everything after the colon and trim
        let match = line.match(/:\s*(.*)/);
        return match ? match[1].trim() : "";
    }

    function processNextCommand() {
        if (isProcessingCommand || commandQueue.length === 0)
            return;

        log("Processing next command from queue. Queue length: " + commandQueue.length);
        isProcessingCommand = true;
        currentCommand = commandQueue.shift();
        
        // Ensure we don't have hanging connections
        try {
            statusSource.connectSource(currentCommand);
            commandTimeoutTimer.restart();
        } catch (error) {
            log("Error connecting to source: " + error);
            // Reset state and try next command
            isProcessingCommand = false;
            currentCommand = null;
            Qt.callLater(processNextCommand);
        }
    }

    function queueCommand(cmd) {
        // Prevent duplicate commands in queue and limit queue size to prevent memory issues
        if (commandQueue.indexOf(cmd) === -1 && commandQueue.length < 10) {
            commandQueue.push(cmd);
            log("Command queued: " + cmd + " (Queue size: " + commandQueue.length + ")");
        } else if (commandQueue.length >= 10) {
            log("Command queue full, dropping command: " + cmd);
        }
    }

    function runCommand(type, value) {
        // Store previous state before making optimistic update
        storePreviousState(type, value);
        
        // Apply optimistic UI update immediately
        applyOptimisticUpdate(type, value);
        
        if (commandsRunning) {
            // Add command to queue instead of ignoring it
            log("Command already running, queuing: " + type);
            let queueCmd;
            if (type === "status") {
                queueCmd = "/usr/bin/python3 " + root.scriptPath + " status";
            } else if (type === "profile") {
                const systemProfile = powerProfileReverseMap[value] || value.toLowerCase();
                queueCmd = "/usr/bin/pkexec /usr/bin/python3 " + root.scriptPath + " profile " + systemProfile;
            } else if (type === "refresh-rate" || type === "auto-refresh-panel" || type === "panel-overdrive") {
                queueCmd = "/usr/bin/python3 " + root.scriptPath + " " + type + " " + value;
            } else {
                queueCmd = "/usr/bin/pkexec /usr/bin/python3 " + root.scriptPath + " " + type + " " + value;
            }
            queueCommand(queueCmd);
            return;
        }

        commandsRunning = true;
        let cmd;
        if (type === "status") {
            cmd = "/usr/bin/python3 " + root.scriptPath + " status";
        } else if (type === "profile") {
            // Map UI profile name to system profile name
            const systemProfile = powerProfileReverseMap[value] || value.toLowerCase();
            cmd = "/usr/bin/pkexec /usr/bin/python3 " + root.scriptPath + " profile " + systemProfile;
        } else if (type === "refresh-rate" || type === "auto-refresh-panel" || type === "panel-overdrive") {
            // Display commands that don't require elevated privileges
            cmd = "/usr/bin/python3 " + root.scriptPath + " " + type + " " + value;
        } else {
            cmd = "/usr/bin/pkexec /usr/bin/python3 " + root.scriptPath + " " + type + " " + value;
        }
        log("Full command: " + cmd);
        currentCommand = cmd;
        
        try {
            statusSource.connectSource(cmd);
            commandTimeoutTimer.restart();
            
            // Start revert timer as fallback (7 seconds)
            startRevertTimer();
        } catch (error) {
            log("Error executing command: " + error);
            // Revert UI immediately on command error
            revertOptimisticUpdate();
            // Reset state on command failure
            commandsRunning = false;
            currentCommand = null;
            Qt.callLater(processNextCommand);
        }
    }
    
    function storePreviousState(type, value) {
        if (type === "profile") {
            previousPowerProfile = currentPowerProfile;
        } else if (type === "gpu") {
            previousGpuMode = currentGpuMode;
        } else if (type === "charge") {
            previousChargeLimit = currentChargeLimit;
        } else if (type === "turbo") {
            previousCpuBoostEnabled = cpuBoostEnabled;
        } else if (type === "set-power-limits") {
            previousPL1 = currentPL1;
            previousPL2 = currentPL2;
        }
        // Note: LED commands don't need rollback since they're visual-only and fast
    }
    
    function applyOptimisticUpdate(type, value) {
        log("Applying optimistic UI update: " + type + " = " + value);
        
        if (type === "profile") {
            currentPowerProfile = value;
            // Update UI profile mapping
            if (value === "power-saver") {
                ui_profile = "Silent";
            } else if (value === "balanced") {
                ui_profile = "Balanced";
            } else if (value === "performance") {
                ui_profile = "Performance";
            }
        } else if (type === "gpu") {
            currentGpuMode = value;
            // Show logout requirement for GPU changes
            if (value !== previousGpuMode) {
                needsLogout = true;
            }
        } else if (type === "charge") {
            currentChargeLimit = parseInt(value, 10);
        } else if (type === "turbo") {
            cpuBoostEnabled = (value === "1");
        } else if (type === "set-power-limits") {
            let parts = value.split(" ");
            if (parts.length >= 2) {
                currentPL1 = parseInt(parts[0], 10);
                currentPL2 = parseInt(parts[1], 10);
                advancedControlsUpdated();
            }
        }
        // LED commands get immediate visual feedback without rollback needed
        else if (type === "ledmode") {
            ledMode = parseInt(value, 10);
        } else if (type === "brightness") {
            keyboard_light = parseInt(value, 10);
        }
        // Service status controls
        else if (type === "nvidia-powerd") {
            nvidiaPowardStatus = value;
        }
        // Screen refresh and panel overdrive commands  
        else if (type === "panel-overdrive") {
            panelOverdrive = (value === "1");
        }
        else if (type === "refresh-rate") {
            currentRefreshRate = parseInt(value, 10);
        }
        // Note: charge-mode is read-only, no setting functionality
        // Note: auto-refresh-panel updates multiple settings at once
        
        // Set flag to indicate we have a pending change (except for LED and fast commands)
        if (type !== "ledmode" && type !== "brightness" && type !== "ledpower" && 
            type !== "panel-overdrive" && type !== "refresh-rate" && type !== "auto-refresh-panel" && 
            type !== "nvidia-powerd") {
            pendingUIRevert = true;
        }
    }
    
    function revertOptimisticUpdate() {
        if (!pendingUIRevert) return;
        
        log("Reverting optimistic UI update due to command failure");
        
        // Revert to previous state
        if (previousPowerProfile !== "") {
            currentPowerProfile = previousPowerProfile;
            // Update UI profile mapping
            if (previousPowerProfile === "power-saver") {
                ui_profile = "Silent";
            } else if (previousPowerProfile === "balanced") {
                ui_profile = "Balanced";
            } else if (previousPowerProfile === "performance") {
                ui_profile = "Performance";
            }
        }
        
        if (previousGpuMode !== "") {
            currentGpuMode = previousGpuMode;
        }
        
        if (previousChargeLimit !== -1) {
            currentChargeLimit = previousChargeLimit;
        }
        
        if (previousCpuBoostEnabled !== cpuBoostEnabled) {
            cpuBoostEnabled = previousCpuBoostEnabled;
        }
        
        if (previousPL1 !== -1 && previousPL2 !== -1) {
            currentPL1 = previousPL1;
            currentPL2 = previousPL2;
            advancedControlsUpdated();
        }
        
        // Clear pending state
        pendingUIRevert = false;
        clearPreviousState();
    }
    
    function confirmOptimisticUpdate() {
        if (!pendingUIRevert) return;
        
        log("Confirming optimistic UI update - command succeeded");
        pendingUIRevert = false;
        clearPreviousState();
        
        // Stop revert timer
        if (revertTimer) {
            revertTimer.stop();
        }
    }
    
    function clearPreviousState() {
        previousPowerProfile = "";
        previousGpuMode = "";
        previousChargeLimit = -1;
        previousCpuBoostEnabled = false;
        previousPL1 = -1;
        previousPL2 = -1;
        // Keep isInitialStartup as true during widget initialization
    }
    
    function startRevertTimer() {
        // Stop existing timer
        if (revertTimer) {
            revertTimer.stop();
        }
        
        // Create or restart revert timer
        if (!revertTimer) {
            try {
                revertTimer = Qt.createQmlObject(`
                    import QtQuick 2.0
                    Timer {
                        interval: 7000  // 7 seconds
                        running: false
                        repeat: false
                        onTriggered: {
                            log("Revert timer triggered - falling back to status refresh");
                            // Force a status update to get current state
                            if (!commandsRunning) {
                                runCommand("status");
                            }
                            pendingUIRevert = false;
                        }
                    }
                `, root);
            } catch (error) {
                console.error("Error creating revert timer:", error);
            }
        }
        
        if (revertTimer) {
            revertTimer.restart();
        }
    }

    // Function to show logout dialog
    function showLogoutDialog() {
        // Check if dialog already exists
        if (logoutDialogInstance) {
            logoutDialogInstance.raise();
            logoutDialogInstance.requestActivate();
            return;
        }
        
        var component = Qt.createComponent("LogoutDialog.qml");
        if (component.status === Component.Ready) {
            // Store reference to prevent garbage collection
            logoutDialogInstance = component.createObject(null);
            // Create with no parent for a separate window
            logoutDialogInstance.visible = true;
            // Connect to the closed signal to clean up the reference
            logoutDialogInstance.closing.connect(function() {
                logoutDialogInstance.destroy();
                logoutDialogInstance = null;
            });
        } else {
            if (debugMode)
                console.error("Error loading dialog:", component.errorString());
        }
        component.destroy(); // Clean up component
    }

    // Function to show reboot dialog
    function showRebootDialog() {
        // Check if dialog already exists
        if (logoutDialogInstance) {
            logoutDialogInstance.raise();
            logoutDialogInstance.requestActivate();
            return;
        }
        
        var component = Qt.createComponent("RebootDialog.qml");
        if (component.status === Component.Ready) {
            // Store reference to prevent garbage collection
            logoutDialogInstance = component.createObject(null);
            // Create with no parent for a separate window
            logoutDialogInstance.visible = true;
            // Connect to the closed signal to clean up the reference
            logoutDialogInstance.closing.connect(function() {
                logoutDialogInstance.destroy();
                logoutDialogInstance = null;
            });
        } else {
            if (debugMode)
                console.error("Error loading dialog:", component.errorString());
        }
        component.destroy(); // Clean up component
    }

    // Add this function to the PlasmoidItem
    function openAdvancedControls() {
        if (!advancedControlsWindow) {
            var component = Qt.createComponent("AdvancedControlsWindow.qml");
            if (component.status === Component.Ready) {
                var advancedRunCommand = function(type, value, callback) {
                    let cmd;
                    if (type === "power-limits") {
                        cmd = "/usr/bin/python3 " + root.scriptPath + " power-limits";
                        commandQueue.push(cmd);
                        processNextCommand();
                    } else if (type === "set-power-limits") {
                        let parts = value.split(" ");
                        cmd = "/usr/bin/pkexec /usr/bin/python3 " + root.scriptPath + " set-power-limits " + parts[0] + " " + parts[1];
                        commandQueue.push(cmd);
                        processNextCommand();
                        // Update local properties immediately for responsiveness
                        currentPL1 = parseInt(parts[0], 10);
                        currentPL2 = parseInt(parts[1], 10);
                    } else if (type === "ledpower" || type === "ledmode") {
                        runLedCommand(type, value);
                    } else {
                        runCommand(type, value);
                    }
                };
                // console.log(root.currentPL1, root.currentPL2);
               

                // Create the window with initial values instead of bindings
                advancedControlsWindow = component.createObject(null, {
                    "cpuBoostEnabled": root.cpuBoostEnabled,
                    "currentPL1": root.currentPL1,
                    "currentPL2": root.currentPL2,
                    "gpuClockOffset": root.gpuClockOffset,
                    "gpuMemOffset": root.gpuMemOffset,
                    "gpuTargetTemp": root.gpuTargetTemp,
                    "commandsRunning": root.commandsRunning,
                    "ledBoot": root.ledBoot,
                    "ledAwake": root.ledAwake,
                    "ledSleep": root.ledSleep,
                    "ledShutdown": root.ledShutdown,
                    "ledMode": root.ledMode,
                    "runCommandFunc": advancedRunCommand,
                    "minPowerLimit": minPowerLimit,
                    "maxPowerLimit": maxPowerLimit,
                    "rootItem": root
                });
                // Position it
                advancedControlsWindow.x = root.x;
                advancedControlsWindow.y = root.y;
                // Connect to the windowClosed signal
                advancedControlsWindow.windowClosed.connect(function() {
                    advancedControlsWindow = null;
                });
                advancedControlsWindow.show();
                // Ensure values are updated immediately after showing
                advancedControlsWindow.updateValues();
                // Add a connection to update the window when needed
                root.advancedControlsUpdated.connect(advancedControlsWindow.updateValues);
                // Request LED status in background (non-blocking)
                Qt.callLater(function() {
                    advancedRunCommand("ledstatus", "");
                });
            } else {
                if (debugMode)
                    console.error("Error loading advanced controls window:", component.errorString());

            }
        } else {
            // If window exists, just bring it to front
            advancedControlsWindow.raise();
            advancedControlsWindow.requestActivate();
        }
    }


    function updateStatus() {
        log("Status update timer triggered");
        // Don't run status if commands are already running to prevent blocking
        if (commandsRunning) {
            log("Commands already running, skipping status update");
            return;
        }
        // Only run the status command, not power-limits or ledstatus
        runCommand("status");
    }

    function loadSupportedRefreshRates() {
        log("Loading supported refresh rates...");
        statusSource.connectSource("/usr/bin/python3 " + scriptPath + " get-supported-rates");
    }

    function updateAutoModeTooltip() {
        // Update tooltip text based on charge mode and supported rates
        var maxRate = Math.max(...supportedRefreshRates);
        var tooltipText = i18n("Auto mode based on battery status:\n• Discharging: 60Hz + Panel Overdrive OFF\n• Charging/Charged: %1Hz + Panel Overdrive ON\n(Uses charge mode status to determine power profile)", maxRate);
        return tooltipText;
    }

    function checkAutoDisplayModeChange() {
        // Check if auto mode is enabled and battery charging status has changed
        if (autoDisplayMode && batteryChargingStatus !== previousChargeMode && previousChargeMode !== -1) {
            log("Auto mode: Battery charging status changed from " + previousChargeMode + " to " + batteryChargingStatus + ", triggering auto refresh");
            runCommand("auto-refresh-panel", "");
        }
        previousChargeMode = batteryChargingStatus;
    }

    // Enhanced debug logging function with robust null/undefined handling
    function log(message) {
        if (debugMode) {
            var logMessage;
            try {
                if (message === undefined) {
                    logMessage = "[undefined]";
                } else if (message === null) {
                    logMessage = "[null]";
                } else if (typeof message === "object") {
                    logMessage = "[object: " + JSON.stringify(message) + "]";
                } else {
                    logMessage = String(message);
                }
            } catch (e) {
                logMessage = "[error converting message: " + e + "]";
            }
            console.log("qml:", logMessage);
        }
    }

    // Helper functions for service status
    function getStatusColor(status) {
        if (status === "1") return "#4CAF50"; // Green for active
        if (status === "0") return "#F44336"; // Red for inactive
        return "#9E9E9E"; // Gray for not found
    }

    function getStatusText(status) {
        if (status === "1") return i18n("Active");
        if (status === "0") return i18n("Inactive");
        return i18n("Not Found");
    }

    function readPowerLimits() {
        log("Reading power limits");
        let cmd = "/usr/bin/python3 " + root.scriptPath + " power-limits";
        // commandQueue.push(cmd);
        // processNextCommand();
        currentCommand = cmd;
        statusSource.connectSource(cmd);
        // runCommand("power-limits", "");
    }

    // Add LED state properties
    property bool ledBoot: true
    property bool ledAwake: true
    property bool ledSleep: true
    property bool ledShutdown: true
    property int ledMode: 0 // 0: static, 1: breath, 10: fast
    property int keyboard_light: 0 // Default to off
    property bool keyboardLightUserChange: false
    // Add LED command handler
    function runLedCommand(type, value) {
        // Apply optimistic update immediately for LED commands
        if (type === "ledmode") {
            ledMode = parseInt(value, 10);
        } else if (type === "brightness") {
            keyboard_light = parseInt(value, 10);
        }
        
        let cmd = "";
        if (type === "ledpower") {
            // value: "true true false true"
            cmd = "/usr/bin/pkexec /usr/bin/python3 " + root.scriptPath + " ledpower " + value;
        } else if (type === "ledmode") {
            cmd = "/usr/bin/pkexec /usr/bin/python3 " + root.scriptPath + " ledmode " + value;
        }
        else if (type === "brightness") {
            // value: 0, 1, 2, 3
            cmd = "/usr/bin/pkexec /usr/bin/python3 " + root.scriptPath + " ledbrightness " + value;
        }
        log("LED command: " + cmd);
        
        if (commandsRunning) {
            log("Command already running, queuing LED command: " + type);
            queueCommand(cmd);
            return;
        }
        
        commandsRunning = true;
        currentCommand = cmd;
        
        try {
            statusSource.connectSource(cmd);
            commandTimeoutTimer.restart();
        } catch (error) {
            log("Error executing LED command: " + error);
            // Reset state on command failure
            commandsRunning = false;
            currentCommand = null;
            Qt.callLater(processNextCommand);
        }
    }

    // Parse LED status from helper output
    function parseLedStatus(stdout) {
        try {
            // Expecting: led_mode:<int>\nled_power:<boot> <awake> <sleep> <shutdown>
            let lines = stdout.trim().split('\n');
            let ledStatus = {};
            lines.forEach(function(line) {
                if (line.startsWith("led_mode:")) {
                    let value = parseInt(line.split(":")[1].trim());
                    if (!isNaN(value)) {
                        ledStatus.led_mode = value;
                    }
                } else if (line.startsWith("led_power:")) {
                    let parts = line.split(":")[1].trim().split(" ");
                    if (parts.length >= 4) {
                        ledStatus.led_power = {
                            boot: parts[0] === "1",
                            awake: parts[1] === "1",
                            sleep: parts[2] === "1",
                            shutdown: parts[3] === "1"
                        }
                    }
                }
            });
            return ledStatus;
        } catch (error) {
            log("Error parsing LED status: " + error);
            return {};
        }
    }

    Component.onCompleted: {
        log("Widget loading with proper system status initialization...");
        
        // Initialize previous state variables
        clearPreviousState();
        
        // Fast initialization with minimal startup commands
        try {
            initializeHealthCheck();
        } catch (error) {
            console.error("Error initializing health check:", error);
        }
        
        // Create timers first for faster UI responsiveness
        try {
            statusUpdateTimer = Qt.createQmlObject(`
                import QtQuick 2.0
                Timer {
                    interval: 3000  // Optimized to 3 seconds for better responsiveness vs performance
                    running: false  // Will be started only when widget is expanded
                    repeat: true
                    onTriggered: {
                        // Only update status if widget is expanded to save CPU
                        if (root.expanded) {
                            root.updateStatus();
                            // Also check for auto display mode changes periodically
                            if (root.autoDisplayMode) {
                                root.checkAutoDisplayModeChange();
                            }
                        }
                    }
                }
            `, root);
            
            uiUpdateTimer = Qt.createQmlObject(`
                import QtQuick 2.0
                Timer {
                    interval: 50  // Reduced to 50ms for faster UI updates
                    running: false
                    repeat: false
                    property var pendingUpdate: null
                    onTriggered: {
                        if (pendingUpdate) {
                            pendingUpdate();
                            pendingUpdate = null;
                        }
                    }
                }
            `, root);
        } catch (error) {
            console.error("Error creating timers:", error);
        }
        
        // Startup sequence: First read system status to initialize UI state properly
        var startupTimer = Qt.createQmlObject(`
            import QtQuick 2.0
            Timer {
                interval: 50  // Very short delay to avoid blocking UI
                running: true
                repeat: false
                property int step: 0
                property bool systemStatusLoaded: false
                onTriggered: {
                    try {
                        switch(step) {
                            case 0:
                                // Step 0: Read main system status first to initialize UI state
                                log("Startup Step 0: Reading system status to initialize UI state");
                                statusSource.connectSource("/usr/bin/python3 " + root.scriptPath + " status");
                                step = 1;
                                interval = 500;  // Give more time for initial status load
                                restart();
                                break;
                            case 1:
                                // Step 1: Read power limits
                                log("Startup Step 1: Reading power limits");
                                statusSource.connectSource("/usr/bin/python3 " + root.scriptPath + " power-limits");
                                step = 2;
                                interval = 200;
                                restart();
                                break;
                            case 2:
                                // Step 2: Read LED status
                                log("Startup Step 2: Reading LED status");
                                statusSource.connectSource("/usr/bin/python3 " + root.scriptPath + " ledstatus");
                                step = 3;
                                interval = 200;
                                restart();
                                break;
                            case 3:
                                // Step 3: Read LED brightness 
                                log("Startup Step 3: Reading LED brightness");
                                statusSource.connectSource("/usr/bin/python3 " + root.scriptPath + " ledbrightnessstatus");
                                step = 4;
                                interval = 200;
                                restart();
                                break;
                            case 4:
                                // Step 4: Read supported refresh rates and finalize startup
                                log("Startup Step 4: Reading supported refresh rates and finalizing startup");
                                statusSource.connectSource("/usr/bin/python3 " + root.scriptPath + " get-supported-rates");
                                
                                // Only start regular status updates if widget is expanded to save CPU
                                if (statusUpdateTimer && root.expanded) {
                                    statusUpdateTimer.start();
                                    log("Regular status updates started (widget is expanded)");
                                } else {
                                    log("Widget is collapsed, status updates will start when expanded");
                                }
                                
                                // Mark initial startup as complete
                                root.isInitialStartup = false;
                                
                                destroy(); // Clean up startup timer
                                break;
                        }
                    } catch (error) {
                        console.error("Error in startup sequence step " + step + ":", error);
                        // Only start regular updates if widget is expanded
                        if (statusUpdateTimer && !statusUpdateTimer.running && root.expanded) {
                            statusUpdateTimer.start();
                        }
                        // Mark startup as complete even if it failed
                        root.isInitialStartup = false;
                        destroy();
                    }
                }
            }
        `, root);
    }

    // Add command timeout timer
    Timer {
        id: commandTimeoutTimer

        interval: 8000 // Reduced from 10 to 8 seconds for better responsiveness
        repeat: false
        onTriggered: {
            log("Command timed out: " + currentCommand);
            
            // Revert optimistic update on timeout
            revertOptimisticUpdate();
            
            // Cleanup timed-out command
            var timedOutCommand = currentCommand;
            commandsRunning = false;
            isProcessingCommand = false;
            currentCommand = null;
            
            // Disconnect the timed-out source to prevent hanging connections
            if (timedOutCommand) {
                try {
                    statusSource.disconnectSource(timedOutCommand);
                } catch (error) {
                    log("Error disconnecting timed-out source: " + error);
                }
            }
            
            // Force a status update to get correct state after timeout
            Qt.callLater(function() {
                if (!commandsRunning) {
                    updateStatus();
                }
            });
            
            // Process next command after cleanup
            Qt.callLater(processNextCommand);
        }
    }

    // --- Data Source for getting status ---
    P5Support.DataSource {
        id: statusSource

        engine: "executable"
        interval: 0  // Disable automatic polling, we'll control it manually
        connectedSources: []
        
        // Enhanced cleanup to prevent QProcess issues
        Component.onDestruction: {
            log("DataSource being destroyed, cleaning up processes...");
            
            // Stop any pending operations first
            try {
                // Force interrupt any running commands by sending a termination signal
                connectSource("terminate_all_processes");
                
                // Give a small delay for processes to terminate
                var cleanupTimer = Qt.createQmlObject(
                    'import QtQuick 2.15; Timer { interval: 100; repeat: false; }',
                    statusSource,
                    "cleanupTimer"
                );
                
                cleanupTimer.triggered.connect(function() {
                    try {
                        // Make a copy of connected sources to avoid modification during iteration
                        var sourcesToDisconnect = connectedSources.slice();
                        
                        // Disconnect each source individually
                        for (var i = 0; i < sourcesToDisconnect.length; i++) {
                            try {
                                disconnectSource(sourcesToDisconnect[i]);
                            } catch (e) {
                                console.log("Error disconnecting source during cleanup:", e);
                            }
                        }
                        
                        // Clear the sources array
                        connectedSources = [];
                        
                        cleanupTimer.destroy();
                    } catch (error) {
                        console.log("Error during delayed DataSource cleanup:", error);
                    }
                });
                
                cleanupTimer.start();
                
            } catch (error) {
                console.log("Error during DataSource cleanup:", error);
                
                // Fallback immediate cleanup
                try {
                    var sourcesToDisconnect = connectedSources.slice();
                    for (var i = 0; i < sourcesToDisconnect.length; i++) {
                        try {
                            disconnectSource(sourcesToDisconnect[i]);
                        } catch (e) {
                            // Silent fallback
                        }
                    }
                    connectedSources = [];
                } catch (fallbackError) {
                    // Silent fallback
                }
            }
        }
       
        onNewData: (sourceName, data) => {
            try {
                log("Received data from: " + sourceName);
                
                // Validate data object to prevent undefined access
                if (!data) {
                    log("No data received from source: " + sourceName);
                    disconnectSource(sourceName);
                    return;
                }
                
                if (data.stdout)
                    log("STDOUT: " + (data.stdout || "empty"));

                if (data.stderr)
                    log("STDERR: " + (data.stderr || "empty"));

                // Only handle power-limits and ledstatus ONCE at startup
                if (sourceName === ("/usr/bin/python3 " + root.scriptPath + " power-limits") && data.stdout) {
                    let lines = data.stdout.trim().split('\n');
                    if (lines.length >= 2) {
                        let pl1 = parseInt(lines[0], 10);
                        let pl2 = parseInt(lines[1], 10);
                        if (!isNaN(pl1) && !isNaN(pl2)) {
                            if (currentPL1 !== pl1 || currentPL2 !== pl2) {
                                currentPL1 = pl1;
                                currentPL2 = pl2;
                                advancedControlsUpdated();
                            }
                        }
                    }
                    log("Power limits read: " + currentPL1 + ", " + currentPL2);
                    // Disconnect so it doesn't repeat
                    try {
                        disconnectSource(sourceName);
                    } catch (e) {
                        log("Error disconnecting power-limits source: " + e);
                    }
                    return;
                }
                if (sourceName === ("/usr/bin/python3 " + root.scriptPath + " ledstatus") && data.stdout) {
                    let ledStatus = parseLedStatus(data.stdout);
                    if (ledStatus.led_power) {
                        ledBoot = ledStatus.led_power.boot;
                        ledAwake = ledStatus.led_power.awake;
                        ledSleep = ledStatus.led_power.sleep;
                        ledShutdown = ledStatus.led_power.shutdown;
                    }
                    if (ledStatus.led_mode !== undefined) {
                        ledMode = ledStatus.led_mode;
                        // Force update the LED mode combo box on startup (only if UI is loaded)
                        try {
                            if (typeof mainLedModeCombo !== 'undefined' && mainLedModeCombo) {
                                let newIndex = 0;
                                if (ledMode === 0) newIndex = 0;
                                else if (ledMode === 1) newIndex = 1;
                                else if (ledMode === 10) newIndex = 2;
                                log("Updating LED mode combo box - ledMode: " + ledMode + ", newIndex: " + newIndex);
                                // Prevent user change flag from triggering during startup update
                                mainLedModeCombo.ledModeUserChange = false;
                                mainLedModeCombo.currentIndex = newIndex;
                            } else {
                                log("LED mode combo box not yet available, mode will be set when UI loads");
                            }
                        } catch (error) {
                            log("Error updating LED mode combo box: " + error);
                        }
                    }
                    if (ledStatus.keyboard_light !== undefined) {
                        keyboard_light = ledStatus.keyboard_light;
                    }
                    // Disconnect so it doesn't repeat
                    try {
                        disconnectSource(sourceName);
                    } catch (e) {
                        log("Error disconnecting ledstatus source: " + e);
                    }
                    return;
                }
                // Handle ledbrightnessstatus command at startup
                if (sourceName.endsWith("ledbrightnessstatus") && data.stdout) {
                    let match = data.stdout.match(/led_brightness:(\d+)/);
                    if (match) {
                        keyboard_light = parseInt(match[1], 10);
                        log("LED brightness read: " + keyboard_light);
                        // Update combo box if available
                        try {
                            if (typeof mainKeyBoardLedPowerCombo !== 'undefined' && mainKeyBoardLedPowerCombo) {
                                log("Updating keyboard brightness combo box - brightness: " + keyboard_light);
                                // Prevent user change flag from triggering during startup update
                                root.keyboardLightUserChange = false;
                                mainKeyBoardLedPowerCombo.currentIndex = keyboard_light;
                            } else {
                                log("LED brightness combo box not yet available, will be set when UI loads");
                            }
                        } catch (error) {
                            log("Error updating LED brightness combo: " + error);
                        }
                    }
                    try {
                        disconnectSource(sourceName);
                    } catch (e) {
                        log("Error disconnecting ledbrightnessstatus source: " + e);
                    }
                    return;
                }

                

                // ...existing code for currentCommand, status, ledpower, ledmode...
                
                // Handle status parsing first (regardless of whether it's the current command)
                if (sourceName.endsWith("status")) {
                    if (isInitialStartup) {
                        log("Processing INITIAL system status to initialize UI state");
                    } else {
                        log("Processing regular status update");
                    }
                    
                    if (data.stdout) {
                        var lines = data.stdout.trim().split('\n');
                        log("Status lines: " + lines.length + " " + lines);
                        if (lines.length >= 14) {
                            // Create temporary variables to avoid UI flickering
                            var newProfile = currentPowerProfile;
                            var newGpuMode = currentGpuMode;
                            var newChargeLimit = currentChargeLimit;
                            var newBoostEnabled = cpuBoostEnabled;
                            var newCpuFanSpeed = cpuFanSpeed;
                            var newGpuFanSpeed = gpuFanSpeed;
                            var newCpuTemp = cpuTemp;
                            var stateChanged = false;
                            var isInitialLoad = isInitialStartup;
                            
                            log("Current UI state before parsing - Profile: " + currentPowerProfile + ", CPU Temp: " + cpuTemp + ", CPU Fan: " + cpuFanSpeed + ", GPU Fan: " + gpuFanSpeed);
                            log("Status data received - Profile: " + lines[0] + ", CPU Temp: " + lines[6] + ", CPU Fan: " + lines[4] + ", GPU Fan: " + lines[5]);
                            
                            // Handle power profile
                            if (lines[0].includes("power-saver")) {
                                if (newProfile !== "power-saver" || isInitialLoad) {
                                    newProfile = "power-saver";
                                    stateChanged = true;
                                    log("Power profile changed to: power-saver");
                                }
                            } else if (lines[0].includes("balanced")) {
                                if (newProfile !== "balanced" || isInitialLoad) {
                                    newProfile = "balanced";
                                    stateChanged = true;
                                    log("Power profile changed to: balanced");
                                }
                            } else if (lines[0].includes("performance")) {
                                if (newProfile !== "performance" || isInitialLoad) {
                                    newProfile = "performance";
                                    stateChanged = true;
                                    log("Power profile changed to: performance");
                                }
                            }
                            // Handle GPU mode
                            var gpuMode = "";
                            if (lines[1] === "integrated")
                                gpuMode = "integrated";
                            else if (lines[1] === "hybrid")
                                gpuMode = "hybrid";
                            else if (lines[1] === "asusmuxdgpu")
                                gpuMode = "asusmuxdgpu";
                            if (gpuMode && (gpuMode !== newGpuMode || isInitialLoad)) {
                                newGpuMode = gpuMode;
                                stateChanged = true;
                            }
                            // Handle charge limit
                            var limitMatch = lines[2];
                            if (limitMatch) {
                                var limit = parseInt(limitMatch, 10);
                                if (!isNaN(limit) && limit >= minChargeLimit && limit <= maxChargeLimit && (limit !== newChargeLimit || isInitialLoad)) {
                                    newChargeLimit = limit;
                                    stateChanged = true;
                                }
                            }
                            // Handle turbo status
                            var boostEnabled = (lines[3] === "1");
                            if (boostEnabled !== newBoostEnabled || isInitialLoad) {
                                newBoostEnabled = boostEnabled;
                                stateChanged = true;
                            }
                            // Handle CPU Fan Speed
                            if (lines[4] !== newCpuFanSpeed || isInitialLoad) {
                                log("CPU Fan Speed changed from '" + newCpuFanSpeed + "' to '" + lines[4] + "'");
                                newCpuFanSpeed = lines[4];
                                stateChanged = true;
                            }
                            // Handle GPU Fan Speed
                            if (lines[5] !== newGpuFanSpeed || isInitialLoad) {
                                log("GPU Fan Speed changed from '" + newGpuFanSpeed + "' to '" + lines[5] + "'");
                                newGpuFanSpeed = lines[5];
                                stateChanged = true;
                            }
                            // Handle CPU Temperature
                            if (lines[6] !== newCpuTemp || isInitialLoad) {
                                log("CPU Temperature changed from '" + newCpuTemp + "' to '" + lines[6] + "'");
                                newCpuTemp = lines[6];
                                stateChanged = true;
                            }
                            
                            // Handle Panel Overdrive status
                            var newPanelOverdrive = (lines[7] === "1");
                            if (newPanelOverdrive !== panelOverdrive || isInitialLoad) {
                                log("Panel Overdrive changed to: " + newPanelOverdrive);
                                panelOverdrive = newPanelOverdrive;
                                stateChanged = true;
                            }
                            
                            // Handle Charge Mode status
                            var newChargeMode = parseInt(lines[8], 10);
                            if (!isNaN(newChargeMode) && (newChargeMode !== chargeMode || isInitialLoad)) {
                                log("Charge Mode changed to: " + newChargeMode);
                                chargeMode = newChargeMode;
                                stateChanged = true;
                            }
                            
                            // Handle Battery Charging Status (line 9)
                            var newBatteryChargingStatus = parseInt(lines[9], 10);
                            if (!isNaN(newBatteryChargingStatus) && (newBatteryChargingStatus !== batteryChargingStatus || isInitialLoad)) {
                                log("Battery Charging Status changed to: " + newBatteryChargingStatus);
                                batteryChargingStatus = newBatteryChargingStatus;
                                stateChanged = true;
                            }
                            
                            // Handle Current Refresh Rate status (line 10)
                            var newCurrentRefreshRate = parseInt(lines[10], 10);
                            if (!isNaN(newCurrentRefreshRate) && (newCurrentRefreshRate !== currentRefreshRate || isInitialLoad)) {
                                log("Current Refresh Rate changed to: " + newCurrentRefreshRate + "Hz");
                                currentRefreshRate = newCurrentRefreshRate;
                                stateChanged = true;
                            }
                            
                            // Handle asusctl status (line 11)
                            var newAsusctlStatus = lines[11];
                            if (newAsusctlStatus !== asusctlStatus || isInitialLoad) {
                                log("asusctl status changed to: " + newAsusctlStatus);
                                asusctlStatus = newAsusctlStatus;
                                stateChanged = true;
                            }
                            
                            // Handle supergfxd status (line 12)
                            var newSupergfxdStatus = lines[12];
                            if (newSupergfxdStatus !== supergfxdStatus || isInitialLoad) {
                                log("supergfxd status changed to: " + newSupergfxdStatus);
                                supergfxdStatus = newSupergfxdStatus;
                                stateChanged = true;
                            }
                            
                            // Handle NVIDIA PowerD status (line 13)
                            var newNvidiaPowardStatus = lines[13];
                            if (newNvidiaPowardStatus !== nvidiaPowardStatus || isInitialLoad) {
                                log("NVIDIA PowerD status changed to: " + newNvidiaPowardStatus);
                                nvidiaPowardStatus = newNvidiaPowardStatus;
                                stateChanged = true;
                            }
                            
                            // Only update properties if there are actual changes or this is initial load
                            if (stateChanged) {
                                if (isInitialStartup) {
                                    log("Initializing UI state with system values - Profile: " + newProfile + ", GPU: " + newGpuMode + ", Charge: " + newChargeLimit + ", Boost: " + newBoostEnabled);
                                    isInitialStartup = false; // Mark initial startup as complete
                                } else {
                                    log("Updating UI state with changes");
                                }
                                
                                // Use debounced UI updates to prevent flickering
                                if (uiUpdateTimer) {
                                    uiUpdateTimer.pendingUpdate = function() {
                                        currentPowerProfile = newProfile;
                                        currentGpuMode = newGpuMode;
                                        currentChargeLimit = newChargeLimit;
                                        cpuBoostEnabled = newBoostEnabled;
                                        cpuFanSpeed = newCpuFanSpeed;
                                        gpuFanSpeed = newGpuFanSpeed;
                                        cpuTemp = newCpuTemp;
                                        
                                        // Update UI profile mapping
                                        if (newProfile === "power-saver") {
                                            ui_profile = "Silent";
                                        } else if (newProfile === "balanced") {
                                            ui_profile = "Balanced";
                                        } else if (newProfile === "performance") {
                                            ui_profile = "Performance";
                                        }
                                        
                                        log("UI updated - Profile: " + newProfile + " (" + ui_profile + "), CPU Temp: " + newCpuTemp + ", CPU Fan: " + newCpuFanSpeed);
                                        
                                        // Emit signal to update advanced controls if window is open
                                        if (advancedControlsWindow) {
                                            advancedControlsUpdated();
                                        }
                                        
                                        // Check for auto display mode changes after UI updates
                                        checkAutoDisplayModeChange();
                                    };
                                    if (uiUpdateTimer) {
                                        uiUpdateTimer.restart();
                                    }
                                } else {
                                    // Fallback if timer not ready
                                    Qt.callLater(function() {
                                        currentPowerProfile = newProfile;
                                        currentGpuMode = newGpuMode;
                                        currentChargeLimit = newChargeLimit;
                                        cpuBoostEnabled = newBoostEnabled;
                                        cpuFanSpeed = newCpuFanSpeed;
                                        gpuFanSpeed = newGpuFanSpeed;
                                        cpuTemp = newCpuTemp;
                                        
                                        // Update UI profile mapping
                                        if (newProfile === "power-saver") {
                                            ui_profile = "Silent";
                                        } else if (newProfile === "balanced") {
                                            ui_profile = "Balanced";
                                        } else if (newProfile === "performance") {
                                            ui_profile = "Performance";
                                        }
                                        
                                        log("UI updated (fallback) - Profile: " + newProfile + " (" + ui_profile + "), CPU Temp: " + newCpuTemp + ", CPU Fan: " + newCpuFanSpeed);
                                        
                                        // Emit signal to update advanced controls if window is open
                                        if (advancedControlsWindow) {
                                            advancedControlsUpdated();
                                        }
                                        
                                        // Check for auto display mode changes after UI updates
                                        checkAutoDisplayModeChange();
                                    });
                                }
                            } else if (isInitialStartup) {
                                // Even if no changes detected, mark initial startup as complete
                                log("Initial system state matches current UI state - no changes needed");
                                isInitialStartup = false;
                            }
                        } else {
                            log("Insufficient status data received (expected 14+ lines, got " + lines.length + ")");
                            if (isInitialStartup) {
                                // If initial load fails, still mark as complete to avoid hanging
                                log("Initial status load failed - marking startup as complete anyway");
                                isInitialStartup = false;
                            }
                        }
                    }
                    if (data.stderr) {
                        // Don't log empty stderr
                        if (data.stderr.trim().length > 0)
                            console.error("Error getting status:", data.stderr);

                    }
                    try {
                        disconnectSource(sourceName);
                    } catch (e) {
                        log("Error disconnecting status source: " + e);
                    }
                }
                
                // Handle command completion (after status parsing)
                if (sourceName === currentCommand) {
                    commandTimeoutTimer.stop();
                    
                    // Check for command success or failure
                    var commandSucceeded = true;
                    var errorMessage = "";
                    
                    // Enhanced error handling for authentication
                    if (data.stderr && (data.stderr.includes("sudo") || data.stderr.includes("pkexec"))) {
                        console.error("Authentication error:", data.stderr);
                        commandSucceeded = false;
                        errorMessage = "Authentication failed";
                    } else if (data.stderr && data.stderr.trim().length > 0 && !data.stdout) {
                        // Command failed if there's stderr but no stdout
                        console.error("Command failed:", data.stderr);
                        commandSucceeded = false;
                        errorMessage = data.stderr;
                    }
                    
                    if (commandSucceeded && data.stdout) {
                        // Command succeeded - confirm optimistic update
                        log("Command succeeded, confirming optimistic update");
                        confirmOptimisticUpdate();
                    } else {
                        // Command failed - revert optimistic update
                        log("Command failed (" + errorMessage + "), reverting optimistic update");
                        revertOptimisticUpdate();
                    }

                    // Handle power limits response (only disconnect if this is the startup command)
                    if (sourceName.startsWith("/usr/bin/python3 " + root.scriptPath + " power-limits") && data.stdout) {
                        let lines = data.stdout.trim().split('\n');
                        if (lines.length >= 2) {
                            let pl1 = parseInt(lines[0], 10);
                            let pl2 = parseInt(lines[1], 10);
                            if (!isNaN(pl1) && !isNaN(pl2)) {
                                if (currentPL1 !== pl1 || currentPL2 !== pl2) {
                                    currentPL1 = pl1;
                                    currentPL2 = pl2;
                                    advancedControlsUpdated();
                                }
                            }
                        }
                        log("Power limits read: " + currentPL1 + ", " + currentPL2);
                        disconnectSource(sourceName);
                        commandsRunning = false;
                        isProcessingCommand = false;
                        currentCommand = null;
                        Qt.callLater(processNextCommand);
                        return;
                    }

                    // Handle LED status (only disconnect if this is the startup command)
                    if (sourceName.startsWith("/usr/bin/python3 " + root.scriptPath + " ledstatus") && data.stdout) {
                        let ledStatus = parseLedStatus(data.stdout);
                        if (ledStatus.led_power) {
                            ledBoot = ledStatus.led_power.boot;
                            ledAwake = ledStatus.led_power.awake;
                            ledSleep = ledStatus.led_power.sleep;
                            ledShutdown = ledStatus.led_power.shutdown;
                        }
                        if (ledStatus.led_mode !== undefined) {
                            ledMode = ledStatus.led_mode;
                            // Force update the LED mode combo box when status is loaded
                            if (mainLedModeCombo) {
                                let newIndex = 0;
                                if (ledMode === 0) newIndex = 0;
                                else if (ledMode === 1) newIndex = 1;
                                else if (ledMode === 10) newIndex = 2;
                                log("Updating LED mode combo box during command - ledMode: " + ledMode + ", newIndex: " + newIndex);
                                // Prevent user change flag from triggering during programmatic update
                                mainLedModeCombo.ledModeUserChange = false;
                                mainLedModeCombo.currentIndex = newIndex;
                            }
                        }
                        disconnectSource(sourceName);
                        commandsRunning = false;
                        isProcessingCommand = false;
                        currentCommand = null;
                        Qt.callLater(processNextCommand);
                        return;
                    }

                    // Check if this is a command that modified settings (but not status commands)
                    if (!sourceName.endsWith("status")) {
                        log("Command completed: " + sourceName);
                        // Check if logout is required (for GPU mode changes)
                        if (data.stdout && data.stdout.includes("LOGOUT_REQUIRED")) {
                            log("Logout required detected");
                            needsLogout = true;
                            // Show logout dialog after a short delay
                            Qt.callLater(showLogoutDialog);
                        }
                        if (data.stdout && data.stdout.includes("REBOOT_REQUIRED")) {
                            log("Reboot required detected");
                            needsLogout = true;
                            // Show reboot dialog after a short delay
                            Qt.callLater(showRebootDialog);
                        }
                        
                        // Schedule status update after successful command for confirmation
                        if (commandSucceeded) {
                            log("Scheduling status update after successful command");
                            if (statusUpdateTimer && root.expanded) {
                                statusUpdateTimer.restart();
                            }
                        }
                        
                        // Clean up command state for non-status commands
                        commandsRunning = false;
                        isProcessingCommand = false;
                        currentCommand = null;
                        try {
                            disconnectSource(sourceName);
                        } catch (e) {
                            log("Error disconnecting after command completion: " + e);
                        }
                        Qt.callLater(processNextCommand);
                        return;
                    } else {
                        // For status commands, clean up but let them fall through to status parsing
                        log("Status command completed, cleaning up");
                        commandsRunning = false;
                        isProcessingCommand = false;
                        currentCommand = null;
                        Qt.callLater(processNextCommand);
                        // Don't disconnect here as status parsing already handled it
                        return;
                    }
                }
               
                // Handle LED status
                if (sourceName.endsWith("ledstatus") && data.stdout) {
                    let ledStatus = parseLedStatus(data.stdout);
                    if (ledStatus.led_power) {
                        ledBoot = ledStatus.led_power.boot;
                        ledAwake = ledStatus.led_power.awake;
                        ledSleep = ledStatus.led_power.sleep;
                        ledShutdown = ledStatus.led_power.shutdown;
                    }
                    if (ledStatus.led_mode !== undefined) {
                        ledMode = ledStatus.led_mode;
                        // Force update the LED mode combo box when status is refreshed (only if UI is loaded)
                        try {
                            if (typeof mainLedModeCombo !== 'undefined' && mainLedModeCombo) {
                                let newIndex = 0;
                                if (ledMode === 0) newIndex = 0;
                                else if (ledMode === 1) newIndex = 1;
                                else if (ledMode === 10) newIndex = 2;
                                log("Updating LED mode combo box during refresh - ledMode: " + ledMode + ", newIndex: " + newIndex);
                                // Prevent user change flag from triggering during programmatic update
                                mainLedModeCombo.ledModeUserChange = false;
                                mainLedModeCombo.currentIndex = newIndex;
                            } else {
                                log("LED mode combo box not yet available, mode will be set when UI loads");
                            }
                        } catch (error) {
                            log("Error updating LED mode combo box: " + error);
                        }
                    }
                    disconnectSource(sourceName);
                }
                
                // Handle supported refresh rates response
                if (sourceName.endsWith("get-supported-rates") && data.stdout) {
                    try {
                        var rates = data.stdout.trim().split(',').map(function(rate) {
                            return parseInt(rate.trim(), 10);
                        }).filter(function(rate) {
                            return !isNaN(rate) && rate > 0;
                        });
                        
                        if (rates.length > 0) {
                            supportedRefreshRates = rates;
                            log("Supported refresh rates loaded: " + supportedRefreshRates.join(', ') + "Hz");
                        } else {
                            log("No valid refresh rates found, keeping defaults");
                        }
                    } catch (parseError) {
                        log("Error parsing supported refresh rates: " + parseError + ", keeping defaults");
                    }
                    disconnectSource(sourceName);
                    return;
                }
                
                // Handle LED power/mode set commands
                if ((sourceName.indexOf("ledpower") !== -1 || sourceName.indexOf("ledmode") !== -1 || sourceName.indexOf("ledbrightness") !== -1) && data.stdout) {
                    // After setting, refresh LED status
                    let ledCmd = "/usr/bin/python3 " + root.scriptPath + " ledstatus";
                    statusSource.connectSource(ledCmd);
                    disconnectSource(sourceName);
                    commandsRunning = false;
                    isProcessingCommand = false;
                    currentCommand = null;
                    Qt.callLater(processNextCommand);
                }
            } catch (error) {
                log("Error in onNewData handler: " + error);
                // Reset state on unexpected errors
                commandsRunning = false;
                isProcessingCommand = false;
                currentCommand = null;
                try {
                    disconnectSource(sourceName);
                } catch (disconnectError) {
                    log("Error disconnecting source: " + disconnectError);
                }
                Qt.callLater(processNextCommand);
            }
        }
    }

    MouseArea {
        anchors.fill: parent
        onClicked: {
            if (debugMode)
                console.log("Widget clicked, updating status");

            updateStatus();
        }
    }

    // --- Compact Representation (Icon) ---
    compactRepresentation: MouseArea {
        id: compactViewArea

        hoverEnabled: true
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        onClicked: (mouse) => {
            if (mouse.button === Qt.LeftButton)
                root.expanded = !root.expanded;

        }

        Kirigami.Icon {
            anchors.fill: parent
            // Dynamically change icon based on GPU mode
            source: {
                if (currentGpuMode === "integrated")
                    return Qt.resolvedUrl("../icons/egpu_mode.png");
                else if (currentGpuMode === "hybrid")
                    return Qt.resolvedUrl("../icons/hgpu_mode.png");
                else if (currentGpuMode === "asusmuxdgpu")
                    return Qt.resolvedUrl("../icons/dgpu_mode.png");
                else
                    return "preferences-system-power-management"; // Fallback to default
            }
            opacity: compactViewArea.containsMouse || root.expanded ? 1 : 0.7
        }

        PlasmaComponents.BusyIndicator {
            anchors.centerIn: parent
            running: false
            visible: false
        }

    }

    // --- Full Representation (Main UI) ---
    fullRepresentation: PlasmaExtras.Representation {
        id: mainWindow_full

        Layout.preferredWidth: Kirigami.Units.gridUnit * 25 // Suggest a width
        Layout.preferredHeight: mainColumnLayout.implicitHeight + Kirigami.Units.largeSpacing * 2 // Calculate height dynamically
        // Refresh status when expanded
        Component.onCompleted: {
            // Status updates are now handled by the onExpandedChanged handler
            // This ensures we don't duplicate timer starts
            log("Full representation loaded");
        }

        // Use Item to contain the layout
        contentItem: Item {
            implicitWidth: mainColumnLayout.implicitWidth + Kirigami.Units.largeSpacing * 2
            implicitHeight: mainColumnLayout.implicitHeight + Kirigami.Units.largeSpacing * 2

            ColumnLayout {
                // --- Power Mode Section ---

                id: mainColumnLayout

                anchors.fill: parent
                anchors.margins: Kirigami.Units.largeSpacing // Use larger margins for the main layout
                spacing: Kirigami.Units.smallSpacing // Spacing between sections

                RowLayout {
                    Layout.fillWidth: true
                    spacing: Kirigami.Units.smallSpacing

                    Image {
                        source: Qt.resolvedUrl("../icons/icons8-speed-50 (1).png")
                        sourceSize.width: 25
                        sourceSize.height: 25
                    }

                    Kirigami.Heading {
                        level: 3
                        text: i18n("Power Mode: %1", ui_profile)
                        Layout.fillWidth: true
                        wrapMode: Text.WordWrap // Ensure text wraps if needed
                    }

                    // Add CPU Temperature
                    Kirigami.Heading {
                        level: 6
                        text: i18n("CPU: %1", cpuTemp)
                        Layout.fillWidth: true
                        horizontalAlignment: Text.AlignRight
                        wrapMode: Text.WordWrap
                        visible: cpuTemp !== "N/A"
                    }

                    // Add CPU Fan Speed
                    Kirigami.Heading {
                        level: 6
                        text: i18n("Fan: %1", cpuFanSpeed)
                        Layout.fillWidth: true
                        horizontalAlignment: Text.AlignRight
                        wrapMode: Text.WordWrap
                        visible: cpuFanSpeed !== "N/A"
                    }

                    

                }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: Kirigami.Units.smallSpacing

                    Button {
                        text: i18n("Silent")
                        icon.source: Qt.resolvedUrl("../icons/icons8-bike-24.png")
                        highlighted: currentPowerProfile === "power-saver"
                        enabled: true
                        hoverEnabled: true
                        opacity: currentPowerProfile != "power-saver" ? 1 : 0.5
                        Layout.fillWidth: true
                        onClicked: runCommand("profile", "power-saver")
                    }

                    Button {
                        text: i18n("Balanced")
                        icon.source: Qt.resolvedUrl("../icons/icons8-sedan-50.png")
                        highlighted: currentPowerProfile === "balanced"
                        enabled: true
                        opacity: currentPowerProfile != "balanced" ? 1 : 0.5
                        Layout.fillWidth: true
                        onClicked: runCommand("profile", "balanced")
                    }

                    Button {
                        text: i18n("Performance")
                        icon.source: Qt.resolvedUrl("../icons/icons8-rocket-50.png")
                        highlighted: currentPowerProfile === "performance"
                        enabled: true
                        opacity: currentPowerProfile != "performance" ? 1 : 0.5
                        Layout.fillWidth: true
                        onClicked: runCommand("profile", "performance")
                    }

                }

                Kirigami.Separator {
                    Layout.fillWidth: true
                    Layout.topMargin: Kirigami.Units.smallSpacing
                    Layout.bottomMargin: Kirigami.Units.smallSpacing
                }

                // --- GPU Mode Section ---
                RowLayout {
                    Layout.fillWidth: true
                    spacing: Kirigami.Units.smallSpacing

                    Image {
                        // source: Qt.resolvedUrl("../icons/gpu_switch.png")
                        source: Qt.resolvedUrl("../icons/icons8-gpu-32.png")
                        sourceSize.width: 25
                        sourceSize.height: 25
                    }

                    Kirigami.Heading {
                        level: 3
                        text: i18n("GPU Mode: %1", gpuModeReverseMap[currentGpuMode])
                        Layout.fillWidth: true
                        wrapMode: Text.WordWrap
                    }

                    // Add GPU Fan Speed
                    Kirigami.Heading {
                        level: 6
                        text: i18n("GPU Fan: %1", gpuFanSpeed)
                        Layout.fillWidth: true
                        horizontalAlignment: Text.AlignRight
                        wrapMode: Text.WordWrap
                        visible: gpuFanSpeed !== "N/A"
                    }

                    

                }

                RowLayout {
                    Layout.fillWidth: true
                    spacing: Kirigami.Units.smallSpacing

                    Button {
                        text: i18n("Integrated")
                        icon.source: Qt.resolvedUrl("../icons/icons8-organic-food-50.png")
                        highlighted: currentGpuMode === "integrated"
                        enabled: true // Enable even when commands are running
                        Layout.fillWidth: true
                        opacity: currentGpuMode != "integrated" ? 1 : 0.5
                        hoverEnabled: true
                        onClicked: runCommand("gpu", "integrated")
                    }

                    Button {
                        text: i18n("Hybrid")
                        icon.source: Qt.resolvedUrl("../icons/icons8-affinity-photo-50.png")
                        highlighted: currentGpuMode === "hybrid"
                        opacity: currentGpuMode != "hybrid" ? 1 : 0.5
                        enabled: true // Enable even when commands are running
                        Layout.fillWidth: true
                        onClicked: runCommand("gpu", "hybrid")
                    }

                    Button {
                        text: i18n("Dedicated") // User friendly name
                        icon.source: Qt.resolvedUrl("../icons/icons8-game-controller-64.png")
                        highlighted: currentGpuMode === "asusmuxdgpu"
                        opacity: currentGpuMode != "asusmuxdgpu" ? 1 : 0.5
                        enabled: true // Enable even when commands are running
                        Layout.fillWidth: true
                        onClicked: runCommand("gpu", "asusmuxdgpu")
                    }

                }

                // Add warning about logout requirement for GPU changes
                Label {
                    text: i18n("Note: Changing GPU mode requires logging out to take effect")
                    font.italic: true
                    opacity: 0.7
                    Layout.fillWidth: true
                    wrapMode: Text.WordWrap
                }

                // Add this button to the fullRepresentation's ColumnLayout, after the last section
                Kirigami.Separator {
                    Layout.fillWidth: true
                    Layout.topMargin: Kirigami.Units.smallSpacing
                    Layout.bottomMargin: Kirigami.Units.smallSpacing
                }

                Button {
                    text: i18n("Advanced HW Controls")
                    icon.name: "configure"
                    Layout.fillWidth: true
                    onClicked: openAdvancedControls()
                }

                // Service Status Row
                RowLayout {
                    Layout.fillWidth: true
                    spacing: Kirigami.Units.smallSpacing

                    // asusctl service (read-only)
                    Rectangle {
                        Layout.fillWidth: true
                        Layout.preferredHeight: 40
                        color: "transparent"
                        border.color: getStatusColor(asusctlStatus)
                        border.width: 2
                        radius: 4
                        
                        RowLayout {
                            anchors.fill: parent
                            anchors.margins: 6
                            spacing: 6
                            
                            Rectangle {
                                width: 10
                                height: 10
                                radius: 5
                                color: getStatusColor(asusctlStatus)
                            }
                            
                            Label {
                                text: "asusctl"
                                font.bold: true
                                font.pixelSize: 11
                                Layout.fillWidth: true
                                elide: Text.ElideRight
                            }
                        }
                        
                        MouseArea {
                            anchors.fill: parent
                            hoverEnabled: true
                            
                            ToolTip.text: i18n("asusctl service status: %1\n(Read-only)", getStatusText(asusctlStatus))
                            ToolTip.visible: containsMouse
                            ToolTip.delay: 500
                        }
                    }

                    // supergfxd service (read-only)
                    Rectangle {
                        Layout.fillWidth: true
                        Layout.preferredHeight: 40
                        color: "transparent"
                        border.color: getStatusColor(supergfxdStatus)
                        border.width: 2
                        radius: 4
                        
                        RowLayout {
                            anchors.fill: parent
                            anchors.margins: 6
                            spacing: 6
                            
                            Rectangle {
                                width: 10
                                height: 10
                                radius: 5
                                color: getStatusColor(supergfxdStatus)
                            }
                            
                            Label {
                                text: "supergfxd"
                                font.bold: true
                                font.pixelSize: 11
                                Layout.fillWidth: true
                                elide: Text.ElideRight
                            }
                        }
                        
                        MouseArea {
                            anchors.fill: parent
                            hoverEnabled: true
                            
                            ToolTip.text: i18n("supergfxd service status: %1\n(Read-only)", getStatusText(supergfxdStatus))
                            ToolTip.visible: containsMouse
                            ToolTip.delay: 500
                        }
                    }

                    // nvidia-powerd service (clickable)
                    Rectangle {
                        Layout.fillWidth: true
                        Layout.preferredHeight: 40
                        color: "transparent"
                        border.color: getStatusColor(nvidiaPowardStatus)
                        border.width: 2
                        radius: 4
                        
                        RowLayout {
                            anchors.fill: parent
                            anchors.margins: 6
                            spacing: 6
                            
                            Rectangle {
                                width: 10
                                height: 10
                                radius: 5
                                color: getStatusColor(nvidiaPowardStatus)
                            }
                            
                            Label {
                                text: "nvidia-powerd"
                                font.bold: true
                                font.pixelSize: 11
                                Layout.fillWidth: true
                                elide: Text.ElideRight
                            }
                        }
                        
                        MouseArea {
                            anchors.fill: parent
                            hoverEnabled: true
                            enabled: !commandsRunning && nvidiaPowardStatus !== "2"
                            cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
                            
                            onClicked: {
                                if (nvidiaPowardStatus !== "2") {
                                    var newValue = (nvidiaPowardStatus === "1") ? "0" : "1";
                                    runCommand("nvidia-powerd", newValue);
                                }
                            }
                            
                            ToolTip.text: {
                                if (nvidiaPowardStatus === "2") {
                                    return i18n("nvidia-powerd service: %1\n(Service not available)", getStatusText(nvidiaPowardStatus));
                                } else {
                                    return i18n("nvidia-powerd service: %1\n(Click to %2)", 
                                        getStatusText(nvidiaPowardStatus),
                                        nvidiaPowardStatus === "1" ? i18n("disable") : i18n("enable"));
                                }
                            }
                            ToolTip.visible: containsMouse
                            ToolTip.delay: 500
                        }
                    }
                }

                // Add this to the fullRepresentation's ColumnLayout after the Charge Limit section
                Kirigami.Separator {
                    Layout.fillWidth: true
                    Layout.topMargin: Kirigami.Units.smallSpacing
                    Layout.bottomMargin: Kirigami.Units.smallSpacing
                }// Add LED mode dropdown to main window
       
                RowLayout {
                    Layout.fillWidth: true
                    spacing: Kirigami.Units.smallSpacing
                    Image {
                        source: Qt.resolvedUrl("../icons/icons8-keyboard-50.png")
                        sourceSize.width: 25
                        sourceSize.height: 25
                    }
                    
                    Kirigami.Heading {
                        level: 3
                        text: i18n("Keyboard LED Mode")
                        Layout.fillWidth: false
                    }
                    ComboBox {
                        id: mainLedModeCombo
                        Layout.fillWidth: true
                        Layout.minimumHeight: 32 // Set minimum height
                        model: [
                            {text: "Static", value: 0},
                            {text: "Breath", value: 1},
                            {text: "Fast", value: 10}
                        ]
                        textRole: "text"  // This tells the ComboBox which property to display
                        valueRole: "value" // This tells the ComboBox which property to use as value
                        property bool ledModeUserChange: false
                        currentIndex: {
                            if (ledMode === 0) return 0;
                            if (ledMode === 1) return 1;
                            if (ledMode === 10) return 2;
                            return 0;
                        }
                        onCurrentIndexChanged: {
                            if (ledModeUserChange) {
                                ledMode = model[currentIndex].value
                                runLedCommand("ledmode", ledMode)
                                ledModeUserChange = false
                            }
                        }
                        onPressedChanged: {
                            if (pressed) {
                                ledModeUserChange = true
                            }
                        }
                        delegate: ItemDelegate {
                            width: parent ? parent.width : 200
                            highlighted: mainLedModeCombo.highlightedIndex === index
                            contentItem: Text {
                                text: modelData.text
                                color: "white"
                                font: mainLedModeCombo.font
                                elide: Text.ElideRight
                                verticalAlignment: Text.AlignVCenter
                            }
                        }
                       
                    }
                    ComboBox {
                        id: mainKeyBoardLedPowerCombo
                        Layout.fillWidth: true
                        Layout.minimumHeight: 32 // Set minimum height
                        model: [
                            {text: "Off", value: 0},
                            {text: "Low", value: 1},
                            {text: "Mid", value: 2},
                            {text: "High", value: 3}
                        ]
                        textRole: "text"  // This tells the ComboBox which property to display
                        valueRole: "value" // This tells the ComboBox which property to use as value
                        currentIndex: keyboard_light
                        onCurrentIndexChanged: {
                            if (root.keyboardLightUserChange) {
                                keyboard_light = model[currentIndex].value
                                runLedCommand("brightness", keyboard_light)
                                root.keyboardLightUserChange = false
                            }
                        }
                        onPressedChanged: {
                            if (pressed) {
                                root.keyboardLightUserChange = true
                            }
                        }
                        delegate: ItemDelegate {
                            width: parent ? parent.width : 200
                            highlighted: mainLedModeCombo.highlightedIndex === index
                            contentItem: Text {
                                text: modelData.text
                                color: "white"
                                font: mainLedModeCombo.font
                                elide: Text.ElideRight
                                verticalAlignment: Text.AlignVCenter
                            }
                        }
                       
                    }
                }                Kirigami.Separator {
                    Layout.fillWidth: true
                    Layout.topMargin: Kirigami.Units.smallSpacing
                    Layout.bottomMargin: Kirigami.Units.smallSpacing
                }

                // --- Display Settings Section (moved above battery for G-Helper compatibility) ---
                RowLayout {
                    Layout.fillWidth: true
                    spacing: Kirigami.Units.smallSpacing

                    Image {
                        source: Qt.resolvedUrl("../icons/icons8-laptop-48.png")
                        sourceSize.width: 25
                        sourceSize.height: 25
                    }

                    Kirigami.Heading {
                        level: 3
                        text: {
                            var currentDisplay = currentRefreshRate + "Hz" + (panelOverdrive ? " + OD" : "");
                            var autoStatus = autoDisplayMode ? " (Auto)" : "";
                            return i18n("Display Settings: %1%2", currentDisplay, autoStatus);
                        }
                        Layout.fillWidth: true
                    }
                }

                // Combined Display Controls - Auto, 60Hz, Max Hz + OD in one row
                RowLayout {
                    Layout.fillWidth: true
                    spacing: Kirigami.Units.smallSpacing

                    Button {
                        text: autoDisplayMode ? i18n("Auto: ON") : i18n("Auto: OFF")
                        Layout.fillWidth: true
                        enabled: true
                        highlighted: autoDisplayMode
                        onClicked: {
                            autoDisplayMode = !autoDisplayMode;
                            if (autoDisplayMode) {
                                // When enabling auto mode, trigger an immediate update
                                runCommand("auto-refresh-panel", "");
                                log("Auto display mode enabled");
                            } else {
                                log("Auto display mode disabled - manual control available");
                            }
                        }
                        ToolTip.text: autoDisplayMode ? 
                            i18n("Auto mode is ON - display settings adjust automatically based on charge mode.\nClick to disable auto mode and enable manual controls.") :
                            updateAutoModeTooltip()
                        ToolTip.visible: hovered
                        ToolTip.delay: 1000
                    }

                    Button {
                        text: i18n("60Hz")
                        Layout.fillWidth: true
                        enabled: !autoDisplayMode
                        opacity: autoDisplayMode ? 0.5 : 1.0
                        onClicked: runCommand("refresh-rate", "60")
                    }

                    Button {
                        text: {
                            var maxRate = Math.max(...supportedRefreshRates);
                            return i18n("%1Hz + OD", maxRate);
                        }
                        Layout.fillWidth: true
                        enabled: !autoDisplayMode
                        opacity: autoDisplayMode ? 0.5 : 1.0
                        onClicked: {
                            var maxRate = Math.max(...supportedRefreshRates);
                            runCommand("refresh-rate", maxRate.toString());
                            // Enable panel overdrive after setting max refresh rate
                            Qt.callLater(function() {
                                runCommand("panel-overdrive", "1");
                            });
                        }
                    }
                }

                Kirigami.Separator {
                    Layout.fillWidth: true
                    Layout.topMargin: Kirigami.Units.smallSpacing
                    Layout.bottomMargin: Kirigami.Units.smallSpacing
                }

                // --- Battery Charge Limit Section (moved below display settings) ---
                RowLayout {
                    Layout.fillWidth: true
                    spacing: Kirigami.Units.smallSpacing

                    Kirigami.Icon {
                        source:  Qt.resolvedUrl("../icons/icons8-charging-battery-50.png")
                        width:  20
                        height: 20
                    
                    }

                    Kirigami.Heading {
                        id: chargeLimitLabel
                        level: 3
                        // Dynamically update label text based on slider value
                        text: i18n("Charge Limit: %1%", chargeLimitSlider.value)
                        Layout.fillWidth: false
                    }

                    // Battery Status in the same row
          

                    Label {
                        text: {
                            var circle = ""
                            var status = ""
                            if (batteryChargingStatus === 0) {
                                circle = "🔴"
                                status = i18n("Discharging")
                            } else if (batteryChargingStatus === 1) {
                                circle = "🟢"
                                status = i18n("AC Charging")
                            } else if (batteryChargingStatus === 2) {
                                circle = "🔶"
                                status = i18n("Type-C Charging")
                            } else if (batteryChargingStatus === 3) {
                                circle = "🔵"
                                status = i18n("Fully Charged")
                            } else if (batteryChargingStatus === 4) {
                                circle = "🟡"
                                status = i18n("Plugged (Not Charging)")
                            } else {
                                circle = "⚪"
                                status = i18n("Unknown")
                            }
                            return status + " " + circle
                        }
                        Layout.fillWidth: true
                        color: "white"
                        font.bold: true
                        horizontalAlignment: Text.AlignRight
                    }
                }

                Slider {
                    id: chargeLimitSlider

                    Layout.fillWidth: true
                    from: minChargeLimit
                    to: maxChargeLimit
                    stepSize: 5 // Allow steps of 10 (e.g., 60, 70, 80, 90, 100)
                    value: currentChargeLimit // Bind to the state property
                    enabled: true
                    // Update label while dragging
                    onValueChanged: {
                        chargeLimitLabel.text = i18n("Charge Limit: %1%", value);
                    }
                    // Apply the change when the slider handle is released
                    onPressedChanged: {
                        if (!pressed && value !== currentChargeLimit)
                            runCommand("charge", value);

                    }
                }

                // One-shot charge button
                Button {
                    text: "🔋 " + i18n("One-shot charge to 100%")
                    Layout.fillWidth: true
                    icon.name: "battery-charging"
                    onClicked: runCommand("one-shot-charge", "")
                    ToolTip.text: i18n("Temporarily allows the battery to charge to 100% once, regardless of the charge limit setting. The charge limit will be restored after this charge cycle.")
                    ToolTip.visible: hovered
                    ToolTip.delay: 1000
                }

                // --- Busy Indicator for Full View ---
                PlasmaComponents.BusyIndicator {
                    id: fullViewBusyIndicator

                    running: false
                    visible: false
                    Layout.alignment: Qt.AlignCenter // Center it horizontally
                    Layout.topMargin: Kirigami.Units.smallSpacing
                }

                
            }
            // End contentItem Item

        }

    }

    // Emergency reset function to handle severe blocking situations
    function emergencyReset() {
        log("Emergency reset triggered - clearing all connections and state");
        
        // Stop all timers
        if (commandTimeoutTimer)
            commandTimeoutTimer.stop();
        if (statusUpdateTimer)
            statusUpdateTimer.stop();
        if (uiUpdateTimer)
            uiUpdateTimer.stop();
        if (healthCheckTimer)
            healthCheckTimer.stop();
        
        // Clear all state
        commandsRunning = false;
        isProcessingCommand = false;
        currentCommand = null;
        commandQueue = [];
        
        // Disconnect all sources
        try {
            statusSource.connectedSources = [];
        } catch (error) {
            log("Error clearing connected sources: " + error);
        }
        
        // Restart timers after a delay - only if widget is expanded
        Qt.callLater(function() {
            if (statusUpdateTimer && root.expanded)
                statusUpdateTimer.start();
            log("Emergency reset completed");
        });
    }

    // Add health check timer to detect blocked states
    property var healthCheckTimer: null
    property int healthCheckCounter: 0
    
    // ...existing properties...
    
    function initializeHealthCheck() {
        try {
            healthCheckTimer = Qt.createQmlObject(`
                import QtQuick 2.0
                Timer {
                    interval: 15000  // Increased to 15 seconds to reduce overhead
                    running: true
                    repeat: true
                    onTriggered: root.performHealthCheck()
                }
            `, root);
        } catch (error) {
            console.error("Error creating health check timer:", error);
        }
    }
    
    function performHealthCheck() {
        // Check if commands have been running too long
        if (commandsRunning && currentCommand) {
            healthCheckCounter++;
            if (healthCheckCounter > 3) { // Command running for more than 30 seconds
                log("Health check: Command appears to be stuck, triggering emergency reset");
                emergencyReset();
                healthCheckCounter = 0;
            }
        } else {
            healthCheckCounter = 0;
        }
        
        // Check for orphaned connections
        if (statusSource.connectedSources.length > 5) {
            log("Health check: Too many connected sources, cleaning up");
            try {
                statusSource.connectedSources = [];
            } catch (error) {
                log("Error cleaning up sources: " + error);
            }
        }
        
        // Additional check for widget responsiveness
        try {
            // Test widget responsiveness by checking if properties are accessible
            var testAccess = currentPowerProfile;
            if (!testAccess && testAccess !== "") {
                log("Health check: Widget may be unresponsive, performing light reset");
                // Gentle reset without full emergency - only if widget is expanded
                if (statusUpdateTimer && root.expanded) {
                    statusUpdateTimer.restart();
                }
            }
        } catch (error) {
            log("Health check: Widget accessibility error: " + error);
        }
    }

    Component.onDestruction: {
        log("Widget being destroyed, cleaning up...");
        
        // Set flag to prevent new operations
        isProcessingCommand = true;
        commandsRunning = false;
        
        // Stop all timers first - be more aggressive
        try {
            if (commandTimeoutTimer) {
                commandTimeoutTimer.stop();
                commandTimeoutTimer.running = false;
            }
            if (statusUpdateTimer) {
                statusUpdateTimer.stop();
                statusUpdateTimer.running = false;
            }
            if (uiUpdateTimer) {
                uiUpdateTimer.stop();
                uiUpdateTimer.running = false;
            }
            if (healthCheckTimer) {
                healthCheckTimer.stop();
                healthCheckTimer.running = false;
            }
        } catch (error) {
            console.log("Error stopping timers during destruction:", error);
        }
        
        // Clear all sources and disconnect any running commands
        try {
            // Send termination signal first
            statusSource.connectSource("terminate_all_processes");
            
            // Small delay to allow cleanup
            var destroyTimer = Qt.createQmlObject(
                'import QtQuick 2.15; Timer { interval: 50; repeat: false; }',
                root,
                "destroyTimer"
            );
            
            destroyTimer.triggered.connect(function() {
                try {
                    // Disconnect all sources explicitly
                    var sources = statusSource.connectedSources.slice(); // Make a copy
                    for (var i = 0; i < sources.length; i++) {
                        statusSource.disconnectSource(sources[i]);
                    }
                    statusSource.connectedSources = [];
                    destroyTimer.destroy();
                } catch (error) {
                    console.log("Error in delayed cleanup during destruction:", error);
                }
            });
            
            destroyTimer.start();
            
        } catch (error) {
            console.log("Error clearing sources during destruction:", error);
            // Fallback immediate cleanup
            try {
                var sources = statusSource.connectedSources.slice();
                for (var i = 0; i < sources.length; i++) {
                    statusSource.disconnectSource(sources[i]);
                }
                statusSource.connectedSources = [];
            } catch (fallbackError) {
                // Silent fallback
            }
        }
        
        // Clear command queue and state
        commandQueue = [];
        currentCommand = null;
        
        // Close advanced controls window if open
        if (advancedControlsWindow) {
            try {
                advancedControlsWindow.close();
                advancedControlsWindow = null;
            } catch (error) {
                console.log("Error closing advanced controls window:", error);
            }
        }
    }

    // ...existing code...
}
