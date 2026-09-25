import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  // COMMET: the call controls in the Dock menu (issue #146). The Dock asks
  // each time it opens the menu.
  override func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
    return VoiceDockMenu.shared.menu()
  }
}

/// COMMET: the call controls in the Dock menu (issue #146): Mute / Unmute,
/// Deafen / Undeafen and Disconnect while in a call, nothing otherwise.
///
/// Dart decides the items (lib/utils/voice_controls/dock_menu.dart) and
/// sends them whenever the call changes; the menu is built from the last
/// ones, since the Dock needs its answer straight away. Choosing an item
/// does not bring the window forward.
final class VoiceDockMenu: NSObject {
  static let shared = VoiceDockMenu()

  private var channel: FlutterMethodChannel?
  private var items: [(id: Int, title: String)] = []

  func attach(to messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: "chat.commet.commetapp/dock", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard call.method == "setItems" else {
        result(FlutterMethodNotImplemented)
        return
      }
      let sent = call.arguments as? [[String: Any]] ?? []
      self?.items = sent.compactMap { item in
        guard let id = item["id"] as? Int, let title = item["title"] as? String
        else { return nil }
        return (id: id, title: title)
      }
      result(nil)
    }
    self.channel = channel
  }

  func menu() -> NSMenu? {
    if items.isEmpty {
      return nil
    }
    let menu = NSMenu()
    for item in items {
      let menuItem = NSMenuItem(
        title: item.title, action: #selector(itemChosen(_:)), keyEquivalent: "")
      menuItem.target = self
      menuItem.tag = item.id
      menu.addItem(menuItem)
    }
    return menu
  }

  @objc private func itemChosen(_ sender: NSMenuItem) {
    channel?.invokeMethod("onItemClicked", arguments: ["id": sender.tag])
  }
}
