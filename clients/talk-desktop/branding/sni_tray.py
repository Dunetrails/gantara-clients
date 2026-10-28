#!/usr/bin/env python3
"""StatusNotifierItem for Dunetrails Talk.

GNOME AppIndicator talks to the item by unique bus name and parses properties
with GLib. A hand-rolled D-Bus payload can round-trip in a toy test and still
be rejected by Gio.DBusProxy (no icon). This process uses PyGObject so
marshaling matches the shell.

Requires host python3-gi (Ubuntu: apt install python3-gi). Must be spawned
without Electron's LD_LIBRARY_PATH / GI_TYPELIB_PATH.
"""
from __future__ import annotations

import argparse
import os
import struct
import sys
import threading
import traceback

ITEM_IFACE = "org.kde.StatusNotifierItem"
WATCHER_NAMES = (
    "org.kde.StatusNotifierWatcher",
    "org.freedesktop.StatusNotifierWatcher",
)
WATCHER_PATH = "/StatusNotifierWatcher"
ITEM_PATH = "/StatusNotifierItem"
LOG_PATH = "/tmp/dunetrails-talk-sni.log"

# The right-click menu is not part of StatusNotifierItem: hosts read it from a
# separate com.canonical.dbusmenu object named by the item's Menu property.
# GNOME builds the whole menu from GetLayout/GetGroupProperties and never calls
# ContextMenu, so an item without a real dbusmenu has no right-click menu at all.
MENU_PATH = "/MenuBar"
MENU_IFACE = "com.canonical.dbusmenu"
MENU_ROOT_ID = 0
MENU_ITEMS = ((1, "Open"), (2, "Quit"))

MENU_XML = """<node>
  <interface name="com.canonical.dbusmenu">
    <property name="Version" type="u" access="read"/>
    <property name="TextDirection" type="s" access="read"/>
    <property name="Status" type="s" access="read"/>
    <property name="IconThemePath" type="as" access="read"/>
    <method name="GetLayout">
      <arg type="i" name="parentId" direction="in"/>
      <arg type="i" name="recursionDepth" direction="in"/>
      <arg type="as" name="propertyNames" direction="in"/>
      <arg type="u" name="revision" direction="out"/>
      <arg type="(ia{sv}av)" name="layout" direction="out"/>
    </method>
    <method name="GetGroupProperties">
      <arg type="ai" name="ids" direction="in"/>
      <arg type="as" name="propertyNames" direction="in"/>
      <arg type="a(ia{sv})" name="properties" direction="out"/>
    </method>
    <method name="GetProperty">
      <arg type="i" name="id" direction="in"/>
      <arg type="s" name="name" direction="in"/>
      <arg type="v" name="value" direction="out"/>
    </method>
    <method name="Event">
      <arg type="i" name="id" direction="in"/>
      <arg type="s" name="eventId" direction="in"/>
      <arg type="v" name="data" direction="in"/>
      <arg type="u" name="timestamp" direction="in"/>
    </method>
    <method name="EventGroup">
      <arg type="a(isvu)" name="events" direction="in"/>
      <arg type="ai" name="idErrors" direction="out"/>
    </method>
    <method name="AboutToShow">
      <arg type="i" name="id" direction="in"/>
      <arg type="b" name="needUpdate" direction="out"/>
    </method>
    <method name="AboutToShowGroup">
      <arg type="ai" name="ids" direction="in"/>
      <arg type="ai" name="updatesNeeded" direction="out"/>
      <arg type="ai" name="idErrors" direction="out"/>
    </method>
    <signal name="ItemsPropertiesUpdated">
      <arg type="a(ia{sv})" name="updatedProps"/>
      <arg type="a(ias)" name="removedProps"/>
    </signal>
    <signal name="LayoutUpdated">
      <arg type="u" name="revision"/>
      <arg type="i" name="parent"/>
    </signal>
    <signal name="ItemActivationRequested">
      <arg type="i" name="id"/>
      <arg type="u" name="timestamp"/>
    </signal>
  </interface>
</node>
"""

ITEM_XML = """<node>
  <interface name="org.kde.StatusNotifierItem">
    <method name="Activate">
      <arg type="i" name="x" direction="in"/>
      <arg type="i" name="y" direction="in"/>
    </method>
    <method name="ContextMenu">
      <arg type="i" name="x" direction="in"/>
      <arg type="i" name="y" direction="in"/>
    </method>
    <method name="SecondaryActivate">
      <arg type="i" name="x" direction="in"/>
      <arg type="i" name="y" direction="in"/>
    </method>
    <method name="Scroll">
      <arg type="i" name="delta" direction="in"/>
      <arg type="s" name="orientation" direction="in"/>
    </method>
    <signal name="NewTitle"/>
    <signal name="NewIcon"/>
    <signal name="NewAttentionIcon"/>
    <signal name="NewOverlayIcon"/>
    <signal name="NewToolTip"/>
    <signal name="NewStatus">
      <arg type="s" name="status"/>
    </signal>
    <property name="Category" type="s" access="read"/>
    <property name="Id" type="s" access="read"/>
    <property name="Title" type="s" access="read"/>
    <property name="Status" type="s" access="read"/>
    <property name="WindowId" type="i" access="read"/>
    <property name="IconName" type="s" access="read"/>
    <property name="IconThemePath" type="s" access="read"/>
    <property name="IconPixmap" type="a(iiay)" access="read"/>
    <property name="OverlayIconName" type="s" access="read"/>
    <property name="OverlayIconPixmap" type="a(iiay)" access="read"/>
    <property name="AttentionIconName" type="s" access="read"/>
    <property name="AttentionIconPixmap" type="a(iiay)" access="read"/>
    <property name="AttentionMovieName" type="s" access="read"/>
    <property name="ToolTip" type="(sa(iiay)ss)" access="read"/>
    <property name="ItemIsMenu" type="b" access="read"/>
    <property name="Menu" type="o" access="read"/>
  </interface>
</node>
"""


def log(msg: str) -> None:
    line = "sni_tray: " + msg
    sys.stderr.write(line + "\n")
    sys.stderr.flush()
    try:
        with open(LOG_PATH, "a", encoding="utf-8") as fh:
            fh.write(line + "\n")
    except OSError:
        pass


def load_pixmap(path: str | None) -> tuple[int, int, bytes]:
    if not path:
        w = h = 22
        pix = bytes([0xFF, 0x2E, 0x4A, 0x9E]) * (w * h)
        return w, h, pix
    data = open(path, "rb").read()
    if len(data) < 8:
        raise RuntimeError("pixmap file too small")
    w, h = struct.unpack_from("<II", data, 0)
    pixels = data[8:]
    if w <= 0 or h <= 0 or len(pixels) != w * h * 4:
        raise RuntimeError("invalid pixmap file")
    return w, h, pixels


def emit(kind: str) -> None:
    sys.stdout.write("EVENT " + kind + "\n")
    sys.stdout.flush()


def import_gi():
    import gi

    gi.require_version("Gio", "2.0")
    gi.require_version("GLib", "2.0")
    from gi.repository import Gio, GLib

    return Gio, GLib


def icon_pixmap_variant(GLib, width: int, height: int, pixels: bytes):
    try:
        return GLib.Variant("a(iiay)", [(width, height, bytes(pixels))])
    except (TypeError, ValueError):
        return GLib.Variant("a(iiay)", [(width, height, list(pixels))])


def item_props(GLib, title: str, pixmap: tuple[int, int, bytes]) -> dict:
    width, height, pixels = pixmap
    empty: list = []
    return {
        "Category": GLib.Variant("s", "ApplicationStatus"),
        "Id": GLib.Variant("s", "dunetrails-talk"),
        "Title": GLib.Variant("s", title),
        "Status": GLib.Variant("s", "Active"),
        "WindowId": GLib.Variant("i", 0),
        "IconName": GLib.Variant("s", ""),
        "IconThemePath": GLib.Variant("s", ""),
        "IconPixmap": icon_pixmap_variant(GLib, width, height, pixels),
        "OverlayIconName": GLib.Variant("s", ""),
        "OverlayIconPixmap": GLib.Variant("a(iiay)", empty),
        "AttentionIconName": GLib.Variant("s", ""),
        "AttentionIconPixmap": GLib.Variant("a(iiay)", empty),
        "AttentionMovieName": GLib.Variant("s", ""),
        "ToolTip": GLib.Variant("(sa(iiay)ss)", ("", empty, "", "")),
        "ItemIsMenu": GLib.Variant("b", False),
        "Menu": GLib.Variant("o", MENU_PATH),
    }


def menu_item_props(GLib, item_id: int) -> dict:
    if item_id == MENU_ROOT_ID:
        return {"children-display": GLib.Variant("s", "submenu")}
    label = dict(MENU_ITEMS)[item_id]
    return {
        "label": GLib.Variant("s", label),
        "enabled": GLib.Variant("b", True),
        "visible": GLib.Variant("b", True),
        "type": GLib.Variant("s", "standard"),
    }


def menu_layout_variant(GLib):
    """The whole menu as (id, props, children) — GNOME asks for it in one call."""
    children = [
        GLib.Variant("(ia{sv}av)", (item_id, menu_item_props(GLib, item_id), []))
        for item_id, _ in MENU_ITEMS
    ]
    return GLib.Variant(
        "(ia{sv}av)",
        (MENU_ROOT_ID, menu_item_props(GLib, MENU_ROOT_ID), children),
    )


def on_menu_method(Gio, GLib, method, params, invocation) -> None:
    if method == "GetLayout":
        invocation.return_value(
            GLib.Variant.new_tuple(GLib.Variant("u", 1), menu_layout_variant(GLib))
        )
        return
    if method == "GetGroupProperties":
        ids = params.unpack()[0]
        known = [MENU_ROOT_ID] + [i for i, _ in MENU_ITEMS]
        wanted = [i for i in ids if i in known] or known
        invocation.return_value(
            GLib.Variant(
                "(a(ia{sv}))",
                ([(i, menu_item_props(GLib, i)) for i in wanted],),
            )
        )
        return
    if method == "GetProperty":
        item_id, name = params.unpack()
        value = menu_item_props(GLib, item_id).get(name)
        if value is None:
            # The domain is a GQuark, not the error class.
            invocation.return_error_literal(
                Gio.DBusError.quark(), Gio.DBusError.INVALID_ARGS, name
            )
            return
        invocation.return_value(GLib.Variant.new_tuple(GLib.Variant("v", value)))
        return
    if method == "Event":
        item_id, event_id, _data, _ts = params.unpack()
        if event_id == "clicked":
            emit("menu %d" % item_id)
        invocation.return_value(None)
        return
    if method == "EventGroup":
        for item_id, event_id, _data, _ts in params.unpack()[0]:
            if event_id == "clicked":
                emit("menu %d" % item_id)
        invocation.return_value(GLib.Variant("(ai)", ([],)))
        return
    if method == "AboutToShow":
        # The layout is static, so it never needs rebuilding before display.
        invocation.return_value(GLib.Variant("(b)", (False,)))
        return
    if method == "AboutToShowGroup":
        invocation.return_value(GLib.Variant("(aiai)", ([], [])))
        return
    invocation.return_error_literal(
        Gio.DBusError.quark(), Gio.DBusError.UNKNOWN_METHOD, method
    )


def menu_props(GLib) -> dict:
    return {
        "Version": GLib.Variant("u", 3),
        "TextDirection": GLib.Variant("s", "ltr"),
        "Status": GLib.Variant("s", "normal"),
        "IconThemePath": GLib.Variant("as", []),
    }


def register_with_watchers(Gio, GLib, conn, service: str, report) -> list:
    """Register with a StatusNotifierWatcher now and whenever one appears.

    A watcher keeps no state across owner changes, so a one-shot registration
    silently loses the icon every time gnome-shell restarts, the AppIndicator
    extension is toggled, or the shell simply finishes loading after us (an
    autostarted or fast-launching app hits that race). Watching the bus name
    and re-registering on every appearance is what libappindicator does.
    """
    unique = conn.get_unique_name() or ""
    # Path form uses the sender (unique name) + /StatusNotifierItem — that is
    # what GNOME AppIndicator actually talks to. Plasma expects a bus name, so
    # fall back to the well-known and unique names.
    # Never call_sync from a GDBus callback: that deadlocks the main loop
    # and GNOME never sees the item.
    arg_forms = [a for a in (ITEM_PATH, service, unique) if a]
    state = {"registered": False}

    def register(watcher: str, index: int = 0) -> None:
        if index >= len(arg_forms):
            log("every registration form was rejected by %s" % watcher)
            return
        arg = arg_forms[index]

        def on_done(source, result, *_ud):
            try:
                source.call_finish(result)
            except Exception as exc:
                log("register %s via %s failed: %s" % (arg, watcher, exc))
                register(watcher, index + 1)
                return
            log("registered with %s as %s" % (watcher, arg))
            if not state["registered"]:
                state["registered"] = True
                report(True)
            emit_new_icon(GLib, conn)

        conn.call(
            watcher,
            WATCHER_PATH,
            watcher,
            "RegisterStatusNotifierItem",
            GLib.Variant("(s)", (arg,)),
            None,
            Gio.DBusCallFlags.NONE,
            4000,
            None,
            on_done,
            None,
        )

    def on_appeared(_conn, name, _owner):
        log("StatusNotifierWatcher appeared: %s" % name)
        register(name)

    def on_vanished(_conn, name):
        log("StatusNotifierWatcher vanished: %s (will re-register)" % name)

    def report_if_absent() -> bool:
        if not state["registered"]:
            log(
                "no StatusNotifierWatcher on this session — the desktop has no "
                "tray host. GNOME needs the AppIndicator extension (Ubuntu: "
                "gnome-shell-extension-appindicator). Qt apps can still show a "
                "tray icon here via the legacy XEmbed protocol, which Electron "
                "does not implement."
            )
            report(False)
        return False

    GLib.timeout_add_seconds(5, report_if_absent)

    return [
        Gio.bus_watch_name_on_connection(
            conn,
            name,
            Gio.BusNameWatcherFlags.NONE,
            on_appeared,
            on_vanished,
        )
        for name in WATCHER_NAMES
    ]


def emit_new_icon(GLib, conn) -> None:
    try:
        conn.emit_signal(None, ITEM_PATH, ITEM_IFACE, "NewIcon", None)
        conn.emit_signal(
            None,
            ITEM_PATH,
            ITEM_IFACE,
            "NewStatus",
            GLib.Variant("(s)", ("Active",)),
        )
    except Exception as exc:
        log("emit NewIcon failed: %s" % exc)


def serve_gi(title: str, pixmap: tuple[int, int, bytes]) -> int:
    Gio, GLib = import_gi()
    service = "org.kde.StatusNotifierItem-%d-1" % os.getpid()
    props = item_props(GLib, title, pixmap)
    iface_info = Gio.DBusNodeInfo.new_for_xml(ITEM_XML).interfaces[0]
    menu_iface_info = Gio.DBusNodeInfo.new_for_xml(MENU_XML).interfaces[0]
    menu_properties = menu_props(GLib)
    loop = GLib.MainLoop()
    state = {"conn": None, "reg": 0, "menu_reg": 0, "watch": []}

    def on_method(_conn, _sender, _path, _iface, method, params, invocation):
        if method in ("Activate", "SecondaryActivate"):
            emit("activate")
            invocation.return_value(None)
            return
        if method == "ContextMenu":
            emit("context")
            invocation.return_value(None)
            return
        if method == "Scroll":
            invocation.return_value(None)
            return
        invocation.return_error_literal(
            Gio.DBusError.quark(),
            Gio.DBusError.UNKNOWN_METHOD,
            method,
        )

    def on_get_property(_conn, _sender, _path, _iface, name):
        return props.get(name)

    def on_bus_acquired(conn, _name):
        state["conn"] = conn
        state["reg"] = conn.register_object(
            ITEM_PATH,
            iface_info,
            on_method,
            on_get_property,
            None,
        )
        if not state["reg"]:
            log("register_object failed")
            loop.quit()
            return
        state["menu_reg"] = conn.register_object(
            MENU_PATH,
            menu_iface_info,
            lambda _c, _s, _p, _i, method, params, invocation: on_menu_method(
                Gio, GLib, method, params, invocation
            ),
            lambda _c, _s, _p, _i, name: menu_properties.get(name),
            None,
        )
        if not state["menu_reg"]:
            log("dbusmenu register_object failed — no right-click menu")
        log("exported %s unique=%s" % (ITEM_PATH, conn.get_unique_name()))

    def on_name_acquired(conn, _name):
        unique = conn.get_unique_name() or ""
        # READY means "the helper is alive and exporting the item", which is
        # what the caller needs to know before it stops waiting on us. Whether
        # a watcher picked the item up is reported separately and may arrive
        # much later (or never, on a desktop with no tray host).
        sys.stdout.write("READY unique=%s name=%s\n" % (unique, service))
        sys.stdout.flush()
        log("READY unique=%s name=%s" % (unique, service))

        def report(ok: bool) -> None:
            sys.stdout.write("WATCHER %s\n" % ("ok" if ok else "none"))
            sys.stdout.flush()

        state["watch"] = register_with_watchers(Gio, GLib, conn, service, report)

    def on_name_lost(_conn, _name):
        log("lost bus name " + service)
        loop.quit()

    owner = Gio.bus_own_name(
        Gio.BusType.SESSION,
        service,
        Gio.BusNameOwnerFlags.NONE,
        on_bus_acquired,
        on_name_acquired,
        on_name_lost,
    )

    # EOF means Talk is gone (quit, crash or kill); leaving the item registered would
    # keep a dead icon in the panel until logout.
    def stdin_loop() -> None:
        for line in sys.stdin:
            if line.strip() == "QUIT":
                break
        GLib.idle_add(loop.quit)

    threading.Thread(target=stdin_loop, daemon=True).start()
    try:
        loop.run()
    finally:
        for watch_id in state["watch"]:
            try:
                Gio.bus_unwatch_name(watch_id)
            except Exception:
                pass
        Gio.bus_unown_name(owner)
        for key in ("reg", "menu_reg"):
            if state["conn"] and state[key]:
                try:
                    state["conn"].unregister_object(state[key])
                except Exception:
                    pass
    return 0


def diagnose() -> int:
    """Report whether this session can host a tray icon at all.

    Runs on the affected machine against the copy shipped inside the AppImage,
    so "the helper is broken" and "this desktop has no tray host" can be told
    apart without a rebuild.
    """
    try:
        Gio, GLib = import_gi()
    except Exception as exc:
        print("FAIL python3-gi is missing: %s" % exc)
        print("     Ubuntu/Debian: apt install python3-gi")
        print("     Fedora: dnf install python3-gobject-base")
        return 1
    print("OK   python3-gi is available")

    try:
        conn = Gio.bus_get_sync(Gio.BusType.SESSION, None)
    except Exception as exc:
        print("FAIL no session D-Bus: %s" % exc)
        return 1
    print("OK   session D-Bus is reachable")

    try:
        names = conn.call_sync(
            "org.freedesktop.DBus",
            "/org/freedesktop/DBus",
            "org.freedesktop.DBus",
            "ListNames",
            None,
            GLib.VariantType("(as)"),
            Gio.DBusCallFlags.NONE,
            3000,
            None,
        ).unpack()[0]
    except Exception as exc:
        print("FAIL could not list bus names: %s" % exc)
        return 1

    found = [n for n in WATCHER_NAMES if n in names]
    if not found:
        print("FAIL no StatusNotifierWatcher on the session bus")
        print("     This desktop has no tray host, so no Electron app can show")
        print("     a tray icon. GNOME needs the AppIndicator extension")
        print("     (Ubuntu: gnome-shell-extension-appindicator).")
        print("     Qt apps like the sync client can still show one over the")
        print("     legacy XEmbed protocol, which Electron does not implement.")
        return 1

    for name in found:
        print("OK   %s is running" % name)
        try:
            items = conn.call_sync(
                name,
                WATCHER_PATH,
                "org.freedesktop.DBus.Properties",
                "Get",
                GLib.Variant("(ss)", (name, "RegisteredStatusNotifierItems")),
                GLib.VariantType("(v)"),
                Gio.DBusCallFlags.NONE,
                3000,
                None,
            ).unpack()[0]
            print("     registered items: %s" % (list(items) or "none"))
        except Exception as exc:
            print("     could not read RegisteredStatusNotifierItems: %s" % exc)
    return 0


def self_test() -> int:
    w, h, pix = load_pixmap(None)
    if w != 22 or len(pix) != 22 * 22 * 4:
        print("FAIL default pixmap")
        return 1
    print("OK pixmap %dx%d bytes=%d" % (w, h, len(pix)))
    try:
        Gio, GLib = import_gi()
        v = icon_pixmap_variant(GLib, w, h, pix)
        unpacked = v.unpack()
        if not unpacked or unpacked[0][0] != w:
            print("FAIL GLib.Variant unpack")
            return 1
        print("OK Gio/GLib IconPixmap variant")
    except Exception as exc:
        print("FAIL python3-gi is required for the GNOME tray:", exc)
        return 1
    return 0


def self_test_bus() -> int:
    global emit
    Gio, GLib = import_gi()
    clicks: list = []
    real_emit, emit = emit, clicks.append
    width, height, pixels = load_pixmap(None)
    service = "org.kde.StatusNotifierItem-%d-1" % os.getpid()
    iface_info = Gio.DBusNodeInfo.new_for_xml(ITEM_XML).interfaces[0]
    menu_iface_info = Gio.DBusNodeInfo.new_for_xml(MENU_XML).interfaces[0]
    menu_properties = menu_props(GLib)
    props = item_props(GLib, "Dunetrails Talk", (width, height, pixels))
    loop = GLib.MainLoop()
    result = {"rc": 1}

    def on_method(_c, _s, _p, _i, method, _params, invocation):
        invocation.return_value(None)

    def on_get(_c, _s, _p, _i, name):
        return props.get(name)

    def on_bus_acquired(conn, _name):
        rid = conn.register_object(ITEM_PATH, iface_info, on_method, on_get, None)
        mid = conn.register_object(
            MENU_PATH,
            menu_iface_info,
            lambda _c, _s, _p, _i, method, params, invocation: on_menu_method(
                Gio, GLib, method, params, invocation
            ),
            lambda _c, _s, _p, _i, name: menu_properties.get(name),
            None,
        )
        if not rid or not mid:
            print("FAIL register_object")
            result["rc"] = 1
            loop.quit()

    def on_acquired(conn, _name):
        unique = conn.get_unique_name()

        def worker():
            err = None
            try:
                client = Gio.bus_get_sync(Gio.BusType.SESSION, None)
                for prop in ("Id", "Menu", "IconPixmap"):
                    reply = client.call_sync(
                        unique,
                        ITEM_PATH,
                        "org.freedesktop.DBus.Properties",
                        "Get",
                        GLib.Variant("(ss)", (ITEM_IFACE, prop)),
                        GLib.VariantType("(v)"),
                        Gio.DBusCallFlags.NONE,
                        3000,
                        None,
                    )
                    value = reply.unpack()[0]
                    if prop == "Id" and value != "dunetrails-talk":
                        raise RuntimeError("bad Id " + repr(value))
                    if prop == "Menu" and value != MENU_PATH:
                        raise RuntimeError("bad Menu " + repr(value))
                    if prop == "IconPixmap" and (not value or value[0][0] != width):
                        raise RuntimeError("bad IconPixmap")
                all_props = client.call_sync(
                    unique,
                    ITEM_PATH,
                    "org.freedesktop.DBus.Properties",
                    "GetAll",
                    GLib.Variant("(s)", (ITEM_IFACE,)),
                    GLib.VariantType("(a{sv})"),
                    Gio.DBusCallFlags.NONE,
                    3000,
                    None,
                ).unpack()[0]
                if all_props.get("Id") != "dunetrails-talk" or "IconPixmap" not in all_props:
                    raise RuntimeError("bad GetAll " + repr(list(all_props)))

                # Exactly the call GNOME makes to build the right-click menu.
                _revision, root = client.call_sync(
                    unique,
                    MENU_PATH,
                    MENU_IFACE,
                    "GetLayout",
                    GLib.Variant("(iias)", (0, -1, ["type", "children-display"])),
                    GLib.VariantType("(u(ia{sv}av))"),
                    Gio.DBusCallFlags.NONE,
                    3000,
                    None,
                ).unpack()
                root_id, root_props, children = root
                labels = [c[1].get("label") for c in children]
                if root_id != MENU_ROOT_ID:
                    raise RuntimeError("bad menu root id " + repr(root_id))
                if root_props.get("children-display") != "submenu":
                    raise RuntimeError("root is not a submenu " + repr(root_props))
                if labels != [label for _, label in MENU_ITEMS]:
                    raise RuntimeError("bad menu labels " + repr(labels))

                groups = client.call_sync(
                    unique,
                    MENU_PATH,
                    MENU_IFACE,
                    "GetGroupProperties",
                    GLib.Variant("(aias)", ([i for i, _ in MENU_ITEMS], [])),
                    GLib.VariantType("(a(ia{sv}))"),
                    Gio.DBusCallFlags.NONE,
                    3000,
                    None,
                ).unpack()[0]
                grouped = {i: p.get("label") for i, p in groups}
                if grouped != dict(MENU_ITEMS):
                    raise RuntimeError("bad GetGroupProperties " + repr(grouped))

                # Clicking an entry is the whole point; if Event stops reporting
                # back, the menu renders but Open/Quit silently do nothing.
                for item_id, _ in MENU_ITEMS:
                    client.call_sync(
                        unique,
                        MENU_PATH,
                        MENU_IFACE,
                        "Event",
                        GLib.Variant(
                            "(isvu)",
                            (item_id, "clicked", GLib.Variant("i", 0), 0),
                        ),
                        GLib.VariantType("()"),
                        Gio.DBusCallFlags.NONE,
                        3000,
                        None,
                    )
                expected = ["menu %d" % i for i, _ in MENU_ITEMS]
                if clicks != expected:
                    raise RuntimeError("clicks not reported " + repr(clicks))
            except Exception as exc:
                err = str(exc)

            def finish():
                if err:
                    print("FAIL unique-name Get: %s" % err)
                    result["rc"] = 1
                else:
                    print("OK unique-name Get/GetAll Id/Menu/IconPixmap via Gio")
                    print("OK dbusmenu GetLayout/GetGroupProperties/Event for %s"
                          % ", ".join(label for _, label in MENU_ITEMS))
                    result["rc"] = 0
                loop.quit()
                return False

            GLib.idle_add(finish)

        threading.Thread(target=worker, daemon=True).start()

    def on_lost(_conn, _name):
        if result["rc"] != 0:
            print("FAIL lost name before Get")
        loop.quit()

    Gio.bus_own_name(
        Gio.BusType.SESSION,
        service,
        Gio.BusNameOwnerFlags.NONE,
        on_bus_acquired,
        on_acquired,
        on_lost,
    )
    GLib.timeout_add_seconds(5, loop.quit)
    try:
        loop.run()
    finally:
        emit = real_emit
    return result["rc"]


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--icon")
    parser.add_argument("--title", default="Dunetrails Talk")
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--self-test-bus", action="store_true")
    parser.add_argument("--diagnose", action="store_true")
    args = parser.parse_args()
    if args.diagnose:
        return diagnose()
    if args.self_test:
        return self_test()
    if args.self_test_bus:
        return self_test_bus()
    try:
        pixmap = load_pixmap(args.icon)
    except Exception as exc:
        log("icon load failed (%s), using built-in pixmap" % exc)
        pixmap = load_pixmap(None)
    try:
        return serve_gi(args.title, pixmap)
    except Exception:
        log("fatal:\n" + traceback.format_exc())
        return 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(0)
