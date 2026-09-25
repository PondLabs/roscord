// CSS cursor names for CEF cursor types, shared by the CEF hosts.
//
// Include after CEF's include/internal/cef_types.h.  The names are the CSS
// `cursor` keywords the app maps to Flutter's SystemMouseCursors.

#ifndef BROWSER_SURFACE_NATIVE_CEF_CURSOR_NAMES_H_
#define BROWSER_SURFACE_NATIVE_CEF_CURSOR_NAMES_H_

namespace browser_surface {

inline const char* CssCursorName(cef_cursor_type_t type) {
  switch (type) {
    case CT_POINTER:
      return "default";
    case CT_CROSS:
      return "crosshair";
    case CT_HAND:
      return "pointer";
    case CT_IBEAM:
      return "text";
    case CT_WAIT:
      return "wait";
    case CT_HELP:
      return "help";
    case CT_EASTRESIZE:
      return "e-resize";
    case CT_NORTHRESIZE:
      return "n-resize";
    case CT_NORTHEASTRESIZE:
      return "ne-resize";
    case CT_NORTHWESTRESIZE:
      return "nw-resize";
    case CT_SOUTHRESIZE:
      return "s-resize";
    case CT_SOUTHEASTRESIZE:
      return "se-resize";
    case CT_SOUTHWESTRESIZE:
      return "sw-resize";
    case CT_WESTRESIZE:
      return "w-resize";
    case CT_NORTHSOUTHRESIZE:
      return "ns-resize";
    case CT_EASTWESTRESIZE:
      return "ew-resize";
    case CT_NORTHEASTSOUTHWESTRESIZE:
      return "nesw-resize";
    case CT_NORTHWESTSOUTHEASTRESIZE:
      return "nwse-resize";
    case CT_COLUMNRESIZE:
      return "col-resize";
    case CT_ROWRESIZE:
      return "row-resize";
    case CT_MIDDLEPANNING:
    case CT_EASTPANNING:
    case CT_NORTHPANNING:
    case CT_NORTHEASTPANNING:
    case CT_NORTHWESTPANNING:
    case CT_SOUTHPANNING:
    case CT_SOUTHEASTPANNING:
    case CT_SOUTHWESTPANNING:
    case CT_WESTPANNING:
    case CT_MIDDLE_PANNING_VERTICAL:
    case CT_MIDDLE_PANNING_HORIZONTAL:
      return "all-scroll";
    case CT_MOVE:
      return "move";
    case CT_VERTICALTEXT:
      return "vertical-text";
    case CT_CELL:
      return "cell";
    case CT_CONTEXTMENU:
      return "context-menu";
    case CT_ALIAS:
      return "alias";
    case CT_PROGRESS:
      return "progress";
    case CT_NODROP:
    case CT_DND_NONE:
      return "no-drop";
    case CT_COPY:
    case CT_DND_COPY:
      return "copy";
    case CT_DND_MOVE:
      return "move";
    case CT_NONE:
      return "none";
    case CT_NOTALLOWED:
      return "not-allowed";
    case CT_ZOOMIN:
      return "zoom-in";
    case CT_ZOOMOUT:
      return "zoom-out";
    case CT_GRAB:
      return "grab";
    case CT_GRABBING:
      return "grabbing";
    default:
      return "default";
  }
}

}  // namespace browser_surface

#endif  // BROWSER_SURFACE_NATIVE_CEF_CURSOR_NAMES_H_
