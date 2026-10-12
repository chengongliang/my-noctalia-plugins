import QtQuick
import QtQuick.Layouts
import qs.Commons
import qs.Widgets

Rectangle {
  id: root

  property var pluginApi: null
  property var message: ({})

  readonly property string role: message.role || message.type || "assistant"
  readonly property string content: message.content || message.text || ""
  readonly property bool fromUser: role === "user"

  Layout.fillWidth: true
  radius: Style.radiusS
  color: fromUser ? Color.mPrimary : Color.mSurface
  implicitHeight: bubbleLayout.implicitHeight + Style.marginM * 2

  ColumnLayout {
    id: bubbleLayout
    anchors {
      left: parent.left
      right: parent.right
      top: parent.top
      margins: Style.marginM
    }
    spacing: Style.marginXS

    RowLayout {
      Layout.fillWidth: true
      spacing: Style.marginS

      NIcon {
        icon: root.fromUser ? "user" : "sparkles"
        pointSize: Style.fontSizeM
        color: root.fromUser ? Color.mOnPrimary : Color.mPrimary
      }

      NText {
        text: root.fromUser ? (pluginApi?.tr("bubble.you")) : (pluginApi?.tr("bubble.hermes"))
        pointSize: Style.fontSizeS
        font.weight: Style.fontWeightSemiBold
        color: root.fromUser ? Color.mOnPrimary : Color.mOnSurface
        Layout.fillWidth: true
      }
    }

    // Assistant replies are markdown (headings, tables, code fences, links).
    // User messages stay literal so stray `*`/`#` never reinterpret what the
    // user typed.
    MarkdownView {
      pluginApi: root.pluginApi
      Layout.fillWidth: true
      markdown: !root.fromUser
      text: root.content
      basePointSize: Style.fontSizeM
      bodyColor: root.fromUser ? Color.mOnPrimary : Color.mOnSurface
      mutedColor: root.fromUser ? Color.mOnPrimary : Color.mOnSurfaceVariant
      outlineColor: root.fromUser ? Color.mOnPrimary : Color.mOutline
      tableHeaderColor: root.fromUser ? Color.mOnPrimary : Color.mSurfaceVariant
      inlineCodeColor: root.fromUser ? Color.mOnPrimary : Color.mTertiary
      accentColor: root.fromUser ? Color.mOnPrimary : Color.mPrimary
    }
  }
}
