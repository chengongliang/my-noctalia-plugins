import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Qt5Compat.GraphicalEffects
import Quickshell
import qs.Commons
import qs.Modules.Bar.Extras
import qs.Services.UI
import qs.Widgets

Item {
  id: root

  property var pluginApi: null
  property ShellScreen screen
  property string widgetId: ""
  property string section: ""
  property int sectionWidgetIndex: -1
  property int sectionWidgetsCount: 0

  readonly property var mainInstance: pluginApi?.mainInstance
  readonly property int tick: mainInstance?.refreshNonce ?? 0
  readonly property string displayMode: mainInstance?.displayMode ?? "text"
  readonly property string panelPosition: mainInstance?.panelPosition ?? "center"

  // 轮播状态。barWatchList 由 Main 保证是 watchList 的子集且按 watchList 排序。
  readonly property var barAssets: mainInstance?.barWatchList ?? []
  readonly property int scrollIntervalMs: Math.max(2, Math.min(60, mainInstance?.barScrollInterval ?? 5)) * 1000
  property int currentIndex: 0
  readonly property string currentAsset: barAssets.length > 0 ? String(barAssets[Math.min(currentIndex, barAssets.length - 1)]) : ""
  readonly property var currentView: assetView(currentAsset)
  readonly property bool currentIsFaulted: currentView.status === "error" || currentView.status === "unavailable"

  function tr(key) {
    const t = tick;
    return mainInstance ? mainInstance.tr(key) : key;
  }

  // 把 marketData 与 per-instrument 的 quoteStates 收敛成单个资产的渲染视图。
  // 逐资产解析是关键：单条资产失败只影响它自己那一帧，不会让整个小部件变成错误态。
  function assetView(reference) {
    const t = tick;
    const text = String(reference ?? "");
    if (text === "") {
      return { "symbol": "", "data": undefined, "status": "empty", "message": "" };
    }

    const id = mainInstance?.getInstrumentId(text) ?? text;
    const symbol = mainInstance?.getInstrumentDisplaySymbol(text) ?? text.toUpperCase();
    const data = mainInstance?.marketData[id];
    const state = mainInstance?.quoteStates[id];

    // 有报价就优先显示（stale 也算），网络暂时失败不该把已有价格抹掉。
    let status = "loading";
    if (data) {
      status = "ready";
    } else if (state?.errorCode === "unavailable") {
      status = "unavailable";
    } else if (state?.status === "error") {
      status = "error";
    }

    return {
      "symbol": symbol,
      "data": data,
      "status": status,
      "message": state?.errorMessage || mainInstance?.errorMessage || ""
    };
  }

  implicitWidth: scrollClip.implicitWidth
  implicitHeight: scrollClip.implicitHeight

  // 裁剪盒：pill 靠 y 位移滑出/滑入，超出部分被裁掉。
  // 只用一个 BarPill 实例，点击、右键和工具提示的绑定不需要复制。
  Item {
    id: scrollClip

    anchors.fill: parent
    clip: true
    implicitWidth: pill.implicitWidth
    implicitHeight: pill.implicitHeight

    // 资产切换时文字宽度会突变。此刻 pill 正好在裁剪区外不可见，
    // 平滑 implicit 尺寸是为了让状态栏里的邻居部件让位时不跳。
    Behavior on implicitWidth {
      enabled: scrollAnimation.running
      NumberAnimation {
        duration: Style.animationFast
        easing.type: Easing.OutCubic
      }
    }

    Behavior on implicitHeight {
      enabled: scrollAnimation.running
      NumberAnimation {
        duration: Style.animationFast
        easing.type: Easing.OutCubic
      }
    }

    BarPill {
      id: pill
      screen: root.screen
      oppositeDirection: BarService.getPillDirection(root)
      icon: ""
      text: {
        const view = root.currentView;
        const mode = root.displayMode;

        if (view.status === "ready") {
          const price = mainInstance?.formatPrice(view.data.close) ?? "--";
          return mode === "text" ? `${view.symbol} ${price}` : price;
        }

        const marker = view.status === "unavailable" ? "✕" : view.status === "error" ? "⚠" : view.status === "empty" ? "--" : "...";
        return mode === "text" && view.symbol !== "" ? `${view.symbol} ${marker}` : marker;
      }
      suffix: {
        const view = root.currentView;
        if (view.status !== "ready") return "";
        return view.data.isRising ? "↑" : "↓";
      }
      autoHide: false
      forceOpen: true
      tooltipText: {
        const view = root.currentView;

        if (view.status === "ready") {
          const priceLabel = root.tr("panel.price");
          const changeLabel = root.tr("panel.change");
          return `${view.symbol}\n${priceLabel}: ${mainInstance?.formatPrice(view.data.close)}\n${changeLabel}: ${mainInstance?.formatChange(view.data.change)}`;
        }
        if (view.status === "unavailable") return `${view.symbol} — ${root.tr("settings.unavailable")}`;
        if (view.status === "error") {
          const detail = view.message !== "" ? `: ${view.message}` : "";
          return `${view.symbol} — ${root.tr("panel.error")}${detail}`;
        }
        if (view.status === "empty") return root.tr("panel.noData");
        return root.tr("panel.loading");
      }
      customBackgroundColor: root.currentIsFaulted ? "#3a3a3a" : "transparent"
      customTextIconColor: root.currentIsFaulted ? "#888888" : "transparent"

      onClicked: togglePanel()
      onRightClicked: PanelService.showContextMenu(contextMenu, pill, screen)
    }
  }

  // 单条资产时不启动定时器，保持静态展示。
  Timer {
    interval: root.scrollIntervalMs
    repeat: true
    running: root.barAssets.length > 1
    onTriggered: if (!scrollAnimation.running) scrollAnimation.restart()
  }

  // 上滑移出 → 在不可见处换内容 → 从下方滑入。
  // Style.animationFast 在用户关闭动画或性能模式下为 0，届时退化为瞬时切换。
  SequentialAnimation {
    id: scrollAnimation

    ParallelAnimation {
      NumberAnimation {
        target: pill
        property: "y"
        to: -scrollClip.height
        duration: Style.animationFast
        easing.type: Easing.InCubic
      }
      NumberAnimation {
        target: pill
        property: "opacity"
        to: 0
        duration: Style.animationFast
        easing.type: Easing.InCubic
      }
    }

    ScriptAction {
      script: {
        const count = root.barAssets.length;
        root.currentIndex = count > 0 ? (root.currentIndex + 1) % count : 0;
        pill.y = scrollClip.height;
      }
    }

    ParallelAnimation {
      NumberAnimation {
        target: pill
        property: "y"
        to: 0
        duration: Style.animationFast
        easing.type: Easing.OutCubic
      }
      NumberAnimation {
        target: pill
        property: "opacity"
        to: 1
        duration: Style.animationFast
        easing.type: Easing.OutCubic
      }
    }
  }

  // 用户在设置页改动轮播列表时复位，避免动画停在半路或索引越界。
  onBarAssetsChanged: {
    scrollAnimation.stop();
    pill.y = 0;
    pill.opacity = 1;
    if (root.currentIndex >= root.barAssets.length) root.currentIndex = 0;
  }

  // 右键菜单
  NPopupContextMenu {
    id: contextMenu

    model: [
      {
        "label": "📊 " + root.tr("barWidget.openPanel"),
        "action": "open-panel"
      },
      {
        "label": "🔤 " + (root.displayMode === "text" ? root.tr("barWidget.switchCompact") : root.tr("barWidget.switchFull")),
        "action": "toggle-mode"
      },
      {
        "label": "⚙️ " + root.tr("panel.settings"),
        "action": "settings"
      },
      {
        "label": "🔄 " + root.tr("panel.refreshNow"),
        "action": "refresh"
      }
    ]

    onTriggered: action => {
      contextMenu.close();
      PanelService.closeContextMenu(screen);

      if (action === "open-panel") {
        togglePanel();
      } else if (action === "toggle-mode" && pluginApi) {
        const newMode = root.displayMode === "text" ? "compact" : "text";
        pluginApi.pluginSettings.displayMode = newMode;
        if (mainInstance) mainInstance.displayMode = newMode;
        pluginApi.saveSettings();
      } else if (action === "settings" && pluginApi) {
        BarService.openPluginSettings(screen, pluginApi.manifest);
      } else if (action === "refresh") {
        // barWatchList 是 watchList 的子集，遍历 watchList 已覆盖状态栏所有资产。
        mainInstance?.watchList.forEach(function(coin) {
          mainInstance?.fetchMarketData(coin);
        });
      }
    }
  }

  function togglePanel() {
    if (pluginApi) {
      if (root.panelPosition === "click") {
        pluginApi.togglePanel(screen, root);
      } else {
        pluginApi.togglePanel(screen);
      }
    }
  }
}
