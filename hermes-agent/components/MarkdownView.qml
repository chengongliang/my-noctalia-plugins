import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.Commons
import qs.Widgets
import "../MarkdownLogic.js" as MarkdownLogic

// MarkdownView — block-aware markdown renderer for chat transcripts.
//
// Renders a document as a ColumnLayout of blocks:
//   * headings — sized/bolder rich text
//   * paragraphs, lists, tables, quotes, rules — one rich-text block each,
//     using Qt's HTML subset (tables with bordercolor/bgcolor, nested lists,
//     <hr>, <s>, <a>)
//   * fenced code — a slab with a language tag and a copy button
//
// Colours are baked into the generated HTML, which is why `signature` includes
// them: a theme switch re-parses. Parsing is deferred with Qt.callLater so a
// streaming message reparses once per event-loop turn, not once per delta.
//
// Text is rendered with read-only TextEdits rather than NText: Qt 6 dropped
// Text.selectByMouse, and transcripts need to be selectable. They are also the
// only way to use Qt's full rich-text layout (QTextDocument) for tables.
//
// With `markdown: false` the component degrades to plain wrapping text, used
// for user messages so literal `*`/`#` are never reinterpreted.
ColumnLayout {
  id: root

  property var pluginApi: null
  property string text: ""
  property bool markdown: true

  property color bodyColor: Color.mOnSurface
  property color mutedColor: Color.mOnSurfaceVariant
  property color outlineColor: Color.mOutline
  property color tableHeaderColor: Color.mSurfaceVariant
  property color inlineCodeColor: Color.mTertiary
  property color accentColor: Color.mPrimary
  property color codeBackgroundColor: Qt.alpha(Color.mShadow, 0.55)

  property real basePointSize: Style.fontSizeM
  property string fontFamily: Settings.data.ui.fontDefault
  property bool selectable: true

  spacing: Style.marginS

  readonly property real uiFontScale: (Settings.data.ui.fontDefaultScale || 1) * Style.uiScaleRatio
  readonly property real monoFontScale: (Settings.data.ui.fontFixedScale || 1) * Style.uiScaleRatio

  // ---- parsing ------------------------------------------------------------

  readonly property string signature: [
    text,
    markdown,
    colorString(bodyColor),
    colorString(mutedColor),
    colorString(outlineColor),
    colorString(tableHeaderColor),
    colorString(inlineCodeColor)
  ].join("\u0000")

  property string parsedSignature: ""
  property var blocks: []

  function colorString(c) {
    if (c === undefined || c === null) return "#000000";
    return Qt.rgba(c.r, c.g, c.b, 1).toString();
  }

  function headingPointSize(level) {
    var factors = [1.55, 1.32, 1.16, 1.06, 1.0, 1.0];
    var index = Math.min(Math.max(level, 1), 6) - 1;
    return Math.max(1, root.basePointSize * factors[index] * root.uiFontScale);
  }

  function tr(key, fallback) {
    if (root.pluginApi && typeof root.pluginApi.tr === "function") {
      var value = root.pluginApi.tr(key);
      if (value !== undefined && value !== null && value !== "") return value;
    }
    return fallback;
  }

  function escapeFallback(value) {
    return String(value === undefined || value === null ? "" : value)
      .replace(/&/g, "&amp;")
      .replace(/</g, "&lt;")
      .replace(/>/g, "&gt;")
      .replace(/\n/g, "<br>");
  }

  function parseNow() {
    if (root.signature === root.parsedSignature) return;
    root.parsedSignature = root.signature;

    if (!root.markdown) {
      root.blocks = [];
      return;
    }
    try {
      root.blocks = MarkdownLogic.parseBlocks(root.text, {
        text: colorString(root.bodyColor),
        muted: colorString(root.mutedColor),
        outline: colorString(root.outlineColor),
        tableHeader: colorString(root.tableHeaderColor),
        code: colorString(root.inlineCodeColor)
      });
    } catch (error) {
      // Never blank the transcript because of a parser bug.
      root.blocks = [{ kind: "rich", muted: false, html: escapeFallback(root.text) }];
    }
  }

  onSignatureChanged: Qt.callLater(parseNow)
  Component.onCompleted: parseNow()

  function openLink(url) {
    if (url && String(url) !== "") Qt.openUrlExternally(url);
  }

  // Blocks size themselves through contentHeight; the Loader wrapper in the
  // Repeater forwards that to the layout (see blockHeight()).
  function blockHeight(item) {
    if (!item) return 0;
    if (item.contentHeight !== undefined) return item.contentHeight;
    return item.implicitHeight;
  }

  // ---- plain-text fallback (user messages) --------------------------------

  TextEdit {
    visible: !root.markdown
    Layout.fillWidth: true
    Layout.preferredWidth: 0
    Layout.preferredHeight: contentHeight
    text: root.text
    textFormat: TextEdit.PlainText
    color: root.bodyColor
    wrapMode: TextEdit.Wrap
    readOnly: true
    selectByMouse: root.selectable
    persistentSelection: true
    cursorVisible: false
    selectionColor: Qt.alpha(root.accentColor, 0.45)
    selectedTextColor: Color.mOnSurface
    font.family: root.fontFamily
    font.pointSize: Math.max(1, root.basePointSize * root.uiFontScale)
  }

  // ---- markdown blocks ----------------------------------------------------

  Repeater {
    model: root.markdown ? root.blocks : []

    delegate: Loader {
      id: blockLoader
      property var blockData: modelData

      sourceComponent: {
        if (!blockData) return richComponent;
        if (blockData.kind === "code") return codeComponent;
        if (blockData.kind === "heading") return headingComponent;
        return richComponent;
      }

      Layout.fillWidth: true
      Layout.preferredWidth: 0
      Layout.preferredHeight: root.blockHeight(item)
    }
  }

  Component {
    id: richComponent

    TextEdit {
      text: blockData && blockData.html !== undefined ? blockData.html : ""
      textFormat: TextEdit.RichText
      color: blockData && blockData.muted ? root.mutedColor : root.bodyColor
      wrapMode: TextEdit.Wrap
      readOnly: true
      selectByMouse: root.selectable
      persistentSelection: true
      cursorVisible: false
      selectionColor: Qt.alpha(root.accentColor, 0.45)
      selectedTextColor: Color.mOnSurface
      font.family: root.fontFamily
      font.pointSize: Math.max(1, root.basePointSize * root.uiFontScale)
      onLinkActivated: function(url) { root.openLink(url); }
    }
  }

  Component {
    id: headingComponent

    TextEdit {
      text: blockData && blockData.html !== undefined ? blockData.html : ""
      textFormat: TextEdit.RichText
      color: root.bodyColor
      wrapMode: TextEdit.Wrap
      readOnly: true
      selectByMouse: root.selectable
      persistentSelection: true
      cursorVisible: false
      selectionColor: Qt.alpha(root.accentColor, 0.45)
      selectedTextColor: Color.mOnSurface
      font.family: root.fontFamily
      font.weight: Font.Bold
      font.pointSize: root.headingPointSize(blockData && blockData.level ? blockData.level : 1)
      onLinkActivated: function(url) { root.openLink(url); }
    }
  }

  Component {
    id: codeComponent

    Rectangle {
      id: codeSlab

      implicitHeight: codeColumn.implicitHeight + Style.marginS * 2
      radius: Style.radiusS
      color: root.codeBackgroundColor
      border.width: Style.borderS
      border.color: Qt.alpha(root.outlineColor, 0.7)

      ColumnLayout {
        id: codeColumn
        anchors {
          left: parent.left
          right: parent.right
          top: parent.top
          margins: Style.marginS
        }
        spacing: Style.marginXS

        RowLayout {
          Layout.fillWidth: true
          spacing: Style.marginS

          NText {
            Layout.fillWidth: true
            text: blockData && blockData.lang ? blockData.lang : root.tr("bubble.code", "code")
            pointSize: Style.fontSizeXS
            font.weight: Style.fontWeightSemiBold
            family: "monospace"
            color: root.mutedColor
          }

          Rectangle {
            id: copyButton
            property bool flashed: false

            implicitWidth: copyRow.implicitWidth + Style.marginM
            implicitHeight: copyRow.implicitHeight + Style.marginXXS * 2
            radius: height / 2
            color: copyArea.containsMouse ? Color.mHover : "transparent"
            border.width: Style.borderS
            border.color: Qt.alpha(root.outlineColor, copyArea.containsMouse ? 0.9 : 0.45)

            Behavior on color {
              ColorAnimation { duration: Style.animationFast }
            }

            RowLayout {
              id: copyRow
              anchors.centerIn: parent
              spacing: Style.marginXXS

              NIcon {
                icon: copyButton.flashed ? "check" : "copy"
                pointSize: Style.fontSizeXS
                color: copyButton.flashed ? Color.mPrimary : root.mutedColor
              }

              NText {
                text: copyButton.flashed
                      ? root.tr("bubble.copied", "Copied")
                      : root.tr("bubble.copy", "Copy")
                pointSize: Style.fontSizeXS
                color: copyButton.flashed ? Color.mPrimary : root.mutedColor
              }
            }

            MouseArea {
              id: copyArea
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: {
                Quickshell.clipboardText = blockData && blockData.text ? blockData.text : "";
                copyButton.flashed = true;
                flashTimer.restart();
              }
            }

            Timer {
              id: flashTimer
              interval: 1200
              onTriggered: copyButton.flashed = false
            }
          }
        }

        TextEdit {
          Layout.fillWidth: true
          Layout.preferredWidth: 0
          Layout.preferredHeight: contentHeight
          text: blockData && blockData.text !== undefined ? blockData.text : ""
          textFormat: TextEdit.PlainText
          color: root.bodyColor
          wrapMode: TextEdit.WrapAnywhere
          readOnly: true
          selectByMouse: root.selectable
          persistentSelection: true
          cursorVisible: false
          selectionColor: Qt.alpha(root.accentColor, 0.45)
          selectedTextColor: Color.mOnSurface
          font.family: "monospace"
          font.pointSize: Math.max(1, Style.fontSizeS * root.monoFontScale)
        }
      }
    }
  }
}
