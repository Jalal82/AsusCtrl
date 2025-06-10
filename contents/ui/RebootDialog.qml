/*
    SPDX-FileCopyrightText: 2023 Your Name <your.email@example.com>
    SPDX-License-Identifier: MPL-2.0
*/

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import org.kde.kirigami as Kirigami
import org.kde.plasma.components as PlasmaComponents
import org.kde.plasma.plasma5support 2.0 as P5Support

Window {
    id: rebootDialog
    title: i18n("Reboot Required")
    
    // Fixed size
    width: Kirigami.Units.gridUnit * 20
    height: Kirigami.Units.gridUnit * 10
    
    // Center on screen
    x: (Screen.width - width) / 2
    y: (Screen.height - height) / 2
    
    // Make it modal-like
    flags: Qt.Dialog | Qt.WindowStaysOnTopHint
    
    // Main content
    Rectangle {
        anchors.fill: parent
        color: Kirigami.Theme.backgroundColor
        
        ColumnLayout {
            anchors.fill: parent
            anchors.margins: Kirigami.Units.largeSpacing
            spacing: Kirigami.Units.largeSpacing
            
            // Header
            RowLayout {
                spacing: Kirigami.Units.smallSpacing
                Layout.fillWidth: true
                
                Kirigami.Icon {
                    source: "system-log-out"
                    width: Kirigami.Units.iconSizes.medium
                    height: width
                }
                
                Label {
                    text: rebootDialog.title
                    elide: Label.ElideRight
                    font.bold: true
                    Layout.fillWidth: true
                    color: Kirigami.Theme.textColor
                }
            }
            
            // Content
            Label {
                text: i18n("GPU mode has been changed. You need to log out for the changes to take effect.")
                wrapMode: Text.WordWrap
                Layout.fillWidth: true
                color: Kirigami.Theme.textColor
            }
            
            Label {
                text: i18n("Would you like to log out now?")
                font.bold: true
                Layout.fillWidth: true
                color: Kirigami.Theme.textColor
            }
            
            // Buttons
            RowLayout {
                Layout.alignment: Qt.AlignRight
                spacing: Kirigami.Units.smallSpacing
                
                Button {
                    text: i18n("OK")
                    onClicked: {
                        rebootDialog.close();
                    }
                }
                
                // Button {
                //     text: i18n("Yes")
                //     highlighted: true
                //     onClicked: {
                //         // Execute KDE reboot command
                //         var cmd = "qdbus org.kde.ksmserver /KSMServer reboot 0 1 0";
                //         var dataSource = Qt.createQmlObject(
                //             'import org.kde.plasma.plasma5support 2.0; DataSource { engine: "executable"; connectedSources: ["' + cmd + '"] }',
                //             rebootDialog
                //         );
                //         rebootDialog.close();
                //     }
                // }
            }
        }
    }
}
