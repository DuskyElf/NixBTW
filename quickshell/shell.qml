import Quickshell
import Quickshell.Io
import QtQuick

// Wallpaper overlay, Google TV "spotlight" style: soft black gradient scrim
// at the bottom with the clock and photo caption in the bottom-right corner;
// systemd timers as a small dim readout top-right. Sits on the layer-shell
// bottom layer, so it renders above the awww wallpaper (background layer)
// but below windows, only visible on an empty workspace.
//
// The window color MUST be transparent or the default opaque white surface
// covers the wallpaper.

Scope {
  id: root

  property string captionText: ""
  property string timersUserText: ""
  property string timersAllText: ""
  property string captionLoc: ""
  property string captionDesc: ""
  property bool timersHover: false

  // caption.txt is "LOCATION: description" or bare "description". Split the
  // location off so it can be styled as an accent.
  function splitCaption() {
    var i = root.captionText.indexOf(": ")
    if (i > 0) {
      root.captionLoc = root.captionText.slice(0, i)
      root.captionDesc = root.captionText.slice(i + 2)
    } else {
      root.captionLoc = ""
      root.captionDesc = root.captionText
    }
  }
  function esc(s) {
    return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
  }

  PanelWindow {
    id: win
    anchors {
      top: true
      left: true
      right: true
      bottom: true
    }
    color: "transparent"
    surfaceFormat.opaque: false
    aboveWindows: false
    focusable: false
    exclusionMode: ExclusionMode.Ignore

    // Google TV spotlight scrim: dark fading up from the bottom so the text
    // stays readable over any photo.
    Rectangle {
      anchors {
        left: parent.left
        right: parent.right
        bottom: parent.bottom
      }
      height: parent.height * 0.5
      gradient: Gradient {
        GradientStop { position: 0.0; color: "#00000000" }
        GradientStop { position: 0.7; color: "#50000000" }
        GradientStop { position: 1.0; color: "#d4000000" }
      }
    }

    // Right-to-left blackish gradient down the whole right edge, so text on
    // both corners reads against a darker backdrop.
    Rectangle {
      anchors {
        top: parent.top
        bottom: parent.bottom
        right: parent.right
      }
      width: parent.width * 0.7
      gradient: Gradient {
        orientation: Qt.Horizontal
        GradientStop { position: 0.0; color: "#00000000" }
        GradientStop { position: 0.5; color: "#40000000" }
        GradientStop { position: 1.0; color: "#cc000000" }
      }
    }

    // Bottom-right: hero clock over the caption.
    Column {
      anchors {
        right: parent.right
        bottom: parent.bottom
        rightMargin: 36
        bottomMargin: 32
      }
      spacing: 12

      Text {
        anchors.right: parent.right
        text: Qt.formatDateTime(clock.date, "HH:mm")
        font.family: "JetBrainsMono Nerd Font"
        font.pixelSize: 56
        font.weight: Font.Bold
        color: "#ebdbb2"
      }

      // Location above the description, styled as an orange accent.
      Text {
        id: captionLoc
        visible: root.captionLoc !== ""
        anchors.right: parent.right
        text: root.esc(root.captionLoc)
        textFormat: Text.RichText
        font.family: "JetBrainsMono Nerd Font"
        font.pixelSize: 17
        font.weight: Font.Bold
        color: "#e78a4e"
        horizontalAlignment: Text.AlignRight
        lineHeight: 1.25
      }

      Text {
        id: caption
        anchors.right: parent.right
        width: Math.min(1100, win.width * 0.95)
        text: root.esc(root.captionDesc)
        textFormat: Text.RichText
        font.family: "JetBrainsMono Nerd Font"
        font.pixelSize: 17
        color: "#d4be98"
        wrapMode: Text.Wrap
        maximumLineCount: 3
        elide: Text.ElideRight
        horizontalAlignment: Text.AlignRight
        lineHeight: 1.25
      }
    }

    // Top-right: faint scrim + small timers readout.
    Rectangle {
      anchors {
        top: parent.top
        left: parent.left
        right: parent.right
      }
      height: parent.height * 0.24
      gradient: Gradient {
        GradientStop { position: 0.0; color: "#6b000000" }
        GradientStop { position: 1.0; color: "#00000000" }
      }
    }
    // Fixed-size hover box (decoupled from the text size) so the trigger
    // region never moves under the cursor; otherwise the expand/collapse
    // resize feeds back into enter/exit and flickers.
    Item {
      id: timersBox
      anchors {
        top: parent.top
        right: parent.right
        margins: 32
      }
      width: 460
      height: 340
      // Both states cached by their own 60s poll; hover just toggles which
      // one is visible, so there is no process-restart race to flicker.
      Text {
        id: timersText
        visible: !root.timersHover
        anchors {
          top: parent.top
          right: parent.right
        }
        text: root.timersUserText
        textFormat: Text.RichText
        font.family: "JetBrainsMono Nerd Font"
        font.pixelSize: 16
        color: "#d4be98"
        horizontalAlignment: Text.AlignRight
        lineHeight: 1.5
      }
      Text {
        visible: root.timersHover
        anchors {
          top: parent.top
          right: parent.right
        }
        text: root.timersAllText
        textFormat: Text.RichText
        font.family: "JetBrainsMono Nerd Font"
        font.pixelSize: 16
        color: "#d4be98"
        horizontalAlignment: Text.AlignRight
        lineHeight: 1.5
      }
      MouseArea {
        anchors.fill: parent
        hoverEnabled: true
        onEntered: root.timersHover = true
        onExited: root.timersHover = false
      }
    }

    SystemClock {
      id: clock
      precision: SystemClock.Minutes
    }
  }

  onCaptionTextChanged: root.splitCaption()

  // Caption: wallpaper.sh writes this file on every wallpaper change.
  Process {
    id: captionProc
    command: [ "sh", "-c", "cat ~/.cache/wallpaper-guardian/caption.txt" ]
    running: true
    stdout: StdioCollector {
      onStreamFinished: root.captionText = text.trim()
    }
  }
  Timer {
    interval: 5000
    running: true
    repeat: true
    onTriggered: captionProc.running = true
  }

  // Timers: USER always cached, USER+SYSTEM cached on the same 60s tick.
  // Hover only flips visibility, so it is deterministic (no command swap).
  Process {
    id: userProc
    command: [ "sh", "-c", "~/.config/scripts/timers.mjs" ]
    running: true
    stdout: StdioCollector {
      onStreamFinished: root.timersUserText = text
    }
  }
  Process {
    id: allProc
    command: [ "sh", "-c", "~/.config/scripts/timers.mjs all" ]
    running: true
    stdout: StdioCollector {
      onStreamFinished: root.timersAllText = text
    }
  }
  Timer {
    interval: 60000
    running: true
    repeat: true
    onTriggered: {
      userProc.running = true
      allProc.running = true
    }
  }
}
