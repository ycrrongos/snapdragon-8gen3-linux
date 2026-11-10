#!/usr/bin/env python3
"""Cerro 蜂窝网络控制 (GTK3 + ModemManager D-Bus).

在手机上直接运行：cerro-cellular-gui
功能：
  - 查看调制解调器状态 / 注册 / 接入技术 / 信号 / 运营商 / IMEI
  - 开关无线电（Enable）
  - 首选网络模式（自动5G / 4G优先 / 仅4G / 仅5G）
  - 数据连接：APN + 连接 / 断开（CreateBearer + Bearer.Connect）
出错（如 polkit 拒绝）会显示在底部状态栏。
"""

import sys
import traceback

import dbus
import dbus.mainloop.glib

import gi

gi.require_version("Gtk", "3.0")
from gi.repository import GLib, Gtk  # noqa: E402

MM_BUS = "org.freedesktop.ModemManager1"
MM_ROOT = "/org/freedesktop/ModemManager1"
IF_MODEM = "org.freedesktop.ModemManager1.Modem"
IF_PROPS = "org.freedesktop.DBus.Properties"
# MM 1.24 重命名了接口（Modem3GPP -> Modem.Modem3gpp、Sim -> Sim2），
# 两套名字都列出，运行时按 GetManagedObjects 实际存在的选。
IF_3GPP_CANDIDATES = [
    "org.freedesktop.ModemManager1.Modem3GPP",
    "org.freedesktop.ModemManager1.Modem.Modem3gpp",
]
IF_SIM_CANDIDATES = [
    "org.freedesktop.ModemManager1.Sim",
    "org.freedesktop.ModemManager1.Sim2",
]
IF_BEARER = "org.freedesktop.ModemManager1.Bearer"

MODEM_STATE = {
    -1: "失败", 0: "未知", 1: "初始化中", 2: "已启用",
    3: "关闭中", 4: "已关闭", 5: "注册中", 6: "注销中",
    7: "连接中", 8: "已连接",
}
POWER_STATE = {0: "未知", 1: "关闭", 2: "低功耗", 3: "开启"}
REG_STATE = {
    0: "未注册", 1: "本地网注册", 2: "搜网中", 3: "被拒绝",
    4: "未知", 5: "漫游注册",
}
ACCESS_TECH = {
    0: "未知", 1: "模拟", 2: "GPRS", 3: "EDGE", 4: "UMTS",
    5: "HSDPA", 6: "HSUPA", 7: "HSPA", 8: "HSPA+", 9: "LTE",
    10: "1xRTT", 11: "EVDO0", 12: "EVDOA", 13: "EVDOB",
    14: "5GNR", 15: "5GNR-NSA",
}
MODE_PRESETS = [
    # (名称, allowed 掩码, preferred)；ANY=0x8000，其余按 (1<<tech)
    ("自动（5G 优先）", 0x8000, 14),
    ("自动（4G 优先）", 0x8000, 9),
    ("仅 4G (LTE)", 1 << 9, 9),
    ("仅 5G (NR)", 1 << 14, 14),
    ("2G/3G/4G（4G 优先）", sum(1 << t for t in range(1, 10)), 9),
]
IP_TYPE = {0: "未知", 1: "IPv4", 2: "IPv6", 3: "IPv4v6"}


def tech_names(mask):
    names = [name for bit, name in ACCESS_TECH.items() if mask & (1 << bit)]
    return "+".join(names) if names else str(mask)


def s(value):
    return str(value) if value not in (None, "") else "—"


class CellularGui:
    def __init__(self):
        dbus.mainloop.glib.DBusGMainLoop(set_as_default=True)
        self.bus = dbus.SystemBus()
        self.mm = self.bus.get_object(MM_BUS, MM_ROOT)
        self.mm_obj = dbus.Interface(self.mm, "org.freedesktop.DBus.ObjectManager")
        self.modem_path = None
        self.bearer_path = None
        self.if_3gpp = IF_3GPP_CANDIDATES[0]
        self.if_sim = IF_SIM_CANDIDATES[0]
        self._busy = False

        self.build_ui()
        GLib.timeout_add_seconds(3, self.auto_refresh)
        GLib.idle_add(self.refresh)

    # ---------- UI ----------
    def build_ui(self):
        self.window = Gtk.Window(title="蜂窝网络控制 — Cerro")
        self.window.set_default_size(440, 720)
        self.window.connect("destroy", Gtk.main_quit)

        outer = Gtk.ScrolledWindow()
        outer.set_policy(Gtk.PolicyType.NEVER, Gtk.PolicyType.AUTOMATIC)
        self.window.add(outer)

        box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=8)
        box.set_border_width(12)
        outer.add(box)

        # 无线电开关
        top = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        self.power_switch = Gtk.Switch()
        self.power_switch.set_valign(Gtk.Align.CENTER)
        self.power_switch.connect("notify::active", self.on_power_toggled)
        top.pack_start(Gtk.Label(label="无线电"), False, False, 0)
        top.pack_start(self.power_switch, False, False, 0)
        self.state_label = Gtk.Label(label="读取中…")
        self.state_label.set_halign(Gtk.Align.END)
        top.pack_end(self.state_label, False, False, 0)
        box.pack_start(top, False, False, 0)

        # 状态区
        status = Gtk.Frame(label="状态")
        grid = Gtk.Grid(column_spacing=12, row_spacing=4)
        grid.set_border_width(8)
        self.status_entries = {}
        rows = [
            ("modem", "调制解调器"), ("power", "电源"),
            ("reg", "注册"), ("operator", "运营商"),
            ("tech", "接入技术"), ("imei", "IMEI"),
            ("sim", "SIM"), ("cfg", "运营商配置"),
        ]
        for idx, (key, label) in enumerate(rows):
            name = Gtk.Label(label=label + ":")
            name.set_halign(Gtk.Align.START)
            value = Gtk.Label(label="—")
            value.set_halign(Gtk.Align.START)
            value.set_selectable(True)
            value.set_line_wrap(True)
            grid.attach(name, 0, idx, 1, 1)
            grid.attach(value, 1, idx, 1, 1)
            self.status_entries[key] = value
        self.signal_bar = Gtk.ProgressBar()
        self.signal_bar.set_show_text(True)
        grid.attach(Gtk.Label(label="信号:"), 0, len(rows), 1, 1)
        grid.attach(self.signal_bar, 1, len(rows), 1, 1)
        status.add(grid)
        box.pack_start(status, False, False, 0)

        # 网络模式
        mode = Gtk.Frame(label="首选网络模式")
        mbox = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        mbox.set_border_width(8)
        self.mode_combo = Gtk.ComboBoxText()
        for name, _, _ in MODE_PRESETS:
            self.mode_combo.append_text(name)
        self.mode_combo.set_active(0)
        mbox.pack_start(self.mode_combo, True, True, 0)
        apply_btn = Gtk.Button(label="应用")
        apply_btn.connect("clicked", self.on_apply_mode)
        mbox.pack_start(apply_btn, False, False, 0)
        mode.add(mbox)
        box.pack_start(mode, False, False, 0)

        # 数据连接
        data = Gtk.Frame(label="数据连接")
        dbox = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=6)
        dbox.set_border_width(8)
        row = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        row.pack_start(Gtk.Label(label="APN"), False, False, 0)
        self.apn_entry = Gtk.Entry()
        self.apn_entry.set_text("cmnet")
        row.pack_start(self.apn_entry, True, True, 0)
        dbox.pack_start(row, False, False, 0)
        brow = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        self.connect_btn = Gtk.Button(label="连接")
        self.connect_btn.connect("clicked", self.on_connect)
        self.disconnect_btn = Gtk.Button(label="断开")
        self.disconnect_btn.connect("clicked", self.on_disconnect)
        self.disconnect_btn.set_sensitive(False)
        brow.pack_start(self.connect_btn, True, True, 0)
        brow.pack_start(self.disconnect_btn, True, True, 0)
        dbox.pack_start(brow, False, False, 0)
        self.bearer_label = Gtk.Label(label="未连接")
        self.bearer_label.set_halign(Gtk.Align.START)
        self.bearer_label.set_line_wrap(True)
        self.bearer_label.set_selectable(True)
        dbox.pack_start(self.bearer_label, False, False, 0)
        data.add(dbox)
        box.pack_start(data, False, False, 0)

        # 底部：刷新 + 状态栏
        bottom = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        refresh_btn = Gtk.Button(label="立即刷新")
        refresh_btn.connect("clicked", lambda *_: self.refresh())
        bottom.pack_start(refresh_btn, False, False, 0)
        self.statusbar = Gtk.Label(label="就绪")
        self.statusbar.set_halign(Gtk.Align.START)
        self.statusbar.set_line_wrap(True)
        bottom.pack_start(self.statusbar, True, True, 0)
        box.pack_start(bottom, False, False, 0)

        self.window.show_all()

    def set_status(self, text):
        self.statusbar.set_text(text)

    # ---------- D-Bus helpers ----------
    def find_modem(self):
        managed = self.mm_obj.GetManagedObjects()
        for path, ifaces in managed.items():
            if IF_MODEM in ifaces:
                # 按本机 MM 版本选定 3GPP / Sim 接口名
                self.if_3gpp = next(
                    (i for i in IF_3GPP_CANDIDATES if i in ifaces),
                    IF_3GPP_CANDIDATES[0])
                self.if_sim = next(
                    (i for i in IF_SIM_CANDIDATES if i in ifaces),
                    IF_SIM_CANDIDATES[0])
                return path
        return None

    def props(self, path, iface):
        obj = self.bus.get_object(MM_BUS, path)
        return dbus.Interface(obj, IF_PROPS).GetAll(iface)

    # ---------- 刷新 ----------
    def auto_refresh(self):
        if not self._busy:
            self.refresh()
        return True

    def refresh(self):
        try:
            if self.modem_path is None:
                self.modem_path = self.find_modem()
                if self.modem_path is None:
                    self.state_label.set_text("未发现调制解调器")
                    return True
            modem = self.props(self.modem_path, IF_MODEM)
            gpp = self.props(self.modem_path, self.if_3gpp)

            state = int(modem.get("State", 0))
            power = int(modem.get("PowerState", 0))
            self.state_label.set_text(
                f"{MODEM_STATE.get(state, state)} / {POWER_STATE.get(power, power)}"
            )
            self.power_switch.handler_block_by_func(self.on_power_toggled)
            self.power_switch.set_active(power == 3 or state >= 2)
            self.power_switch.handler_unblock_by_func(self.on_power_toggled)

            self.status_entries["modem"].set_text(
                s(modem.get("Manufacturer", "")) + " / " + s(modem.get("Model", ""))
            )
            self.status_entries["power"].set_text(POWER_STATE.get(power, str(power)))
            reg = int(gpp.get("RegistrationState", 4))
            self.status_entries["reg"].set_text(REG_STATE.get(reg, str(reg)))
            self.status_entries["operator"].set_text(
                f"{s(gpp.get('OperatorName', ''))} ({s(gpp.get('OperatorCode', ''))})"
            )
            self.status_entries["tech"].set_text(tech_names(int(modem.get("AccessTechnologies", 0))))
            self.status_entries["imei"].set_text(s(modem.get("EquipmentIdentifier", "")))
            self.status_entries["cfg"].set_text(s(modem.get("CarrierConfiguration", "")))

            sim_path = modem.get("Sim")
            sim_name = "—"
            if sim_path and str(sim_path) != "/":
                try:
                    sim = self.props(sim_path, self.if_sim)
                    sim_name = s(sim.get("OperatorName", "")) or s(sim.get("Identifier", ""))
                except Exception:
                    pass
            self.status_entries["sim"].set_text(sim_name)

            quality_recent = modem.get("SignalQuality", (0, False))
            quality = int(quality_recent[0])
            self.signal_bar.set_fraction(quality / 100.0)
            self.signal_bar.set_text(f"{quality}%" + ("（近期）" if quality_recent[1] else ""))

            self.refresh_bearer(modem)
        except Exception as exc:
            self.modem_path = None
            self.state_label.set_text("ModemManager 不可用")
            self.set_status(f"刷新失败: {exc}")
            traceback.print_exc()
        return True

    def refresh_bearer(self, modem):
        bearers = [str(b) for b in modem.get("Bearers", [])]
        if not bearers:
            self.bearer_path = None
            self.bearer_label.set_text("未连接（无 bearer）")
            self.disconnect_btn.set_sensitive(False)
            return
        # 取第一个 bearer 的状态
        path = bearers[0]
        try:
            bearer = self.props(path, IF_BEARER)
        except Exception:
            self.bearer_label.set_text(f"bearer: {path}（读取失败）")
            return
        self.bearer_path = path
        connected = bool(bearer.get("Connected", False))
        iface = s(bearer.get("Interface", ""))
        lines = [f"状态: {'已连接' if connected else '未连接'}    接口: {iface}"]
        for cfg_key in ("Ip4Config", "Ip6Config"):
            cfg = bearer.get(cfg_key)
            if cfg:
                method = int(cfg.get("method", 0))
                addrs = cfg.get("address-data", [])
                addr_text = ", ".join(a.get("address", "?") for a in addrs) if addrs else "—"
                lines.append(f"{cfg_key}: method={method} 地址: {addr_text}")
        self.bearer_label.set_text("\n".join(lines))
        self.disconnect_btn.set_sensitive(connected)

    # ---------- 动作 ----------
    def guard_modem(self):
        if self.modem_path is None:
            self.modem_path = self.find_modem()
        if self.modem_path is None:
            self.set_status("未发现调制解调器，无法操作")
            return None
        obj = self.bus.get_object(MM_BUS, self.modem_path)
        return dbus.Interface(obj, IF_MODEM)

    def on_power_toggled(self, switch, _param):
        modem = self.guard_modem()
        if modem is None:
            return
        want = switch.get_active()
        self._busy = True
        self.set_status(f"正在{'开启' if want else '关闭'}无线电…")

        def done(*_):
            self._busy = False
            self.set_status("无线电操作已提交")
            self.refresh()

        def failed(exc):
            self._busy = False
            self.set_status(f"无线电操作失败: {exc}")
            self.refresh()

        modem.Enable(want, reply_handler=done, error_handler=failed)

    def on_apply_mode(self, _btn):
        modem = self.guard_modem()
        if modem is None:
            return
        idx = self.mode_combo.get_active()
        if idx < 0:
            return
        _, allowed, preferred = MODE_PRESETS[idx]
        self._busy = True
        self.set_status("正在设置网络模式…")

        def done(*_):
            self._busy = False
            self.set_status("网络模式已设置")
            self.refresh()

        def failed(exc):
            self._busy = False
            self.set_status(f"设置网络模式失败: {exc}")

        modem.SetCurrentModes((dbus.UInt32(allowed), dbus.UInt32(preferred)),
                              reply_handler=done, error_handler=failed)

    def on_connect(self, _btn):
        modem = self.guard_modem()
        if modem is None:
            return
        apn = self.apn_entry.get_text().strip() or "cmnet"
        self._busy = True
        self.connect_btn.set_sensitive(False)
        self.set_status(f"正在创建 bearer（APN={apn}）…")
        props = {
            "apn": dbus.String(apn),
            "ip-type": dbus.UInt32(3),  # IPv4v6
            "allow-roaming": dbus.Boolean(True),
        }

        def bearer_created(path):
            self.bearer_path = str(path)
            self.set_status("bearer 已创建，正在连接…")
            obj = self.bus.get_object(MM_BUS, self.bearer_path)
            bearer = dbus.Interface(obj, IF_BEARER)

            def connected(*_):
                self._busy = False
                self.connect_btn.set_sensitive(True)
                self.set_status("数据连接成功")
                self.refresh()

            def connect_failed(exc):
                self._busy = False
                self.connect_btn.set_sensitive(True)
                self.set_status(f"bearer 连接失败: {exc}")
                self.refresh()

            bearer.Connect(reply_handler=connected, error_handler=connect_failed)

        def create_failed(exc):
            self._busy = False
            self.connect_btn.set_sensitive(True)
            self.set_status(f"创建 bearer 失败: {exc}")

        modem.CreateBearer(props, reply_handler=bearer_created, error_handler=create_failed)

    def on_disconnect(self, _btn):
        if not self.bearer_path:
            self.set_status("没有可断开的 bearer")
            return
        obj = self.bus.get_object(MM_BUS, self.bearer_path)
        bearer = dbus.Interface(obj, IF_BEARER)
        self._busy = True
        self.set_status("正在断开…")

        def done(*_):
            self._busy = False
            self.set_status("已断开")
            self.refresh()

        def failed(exc):
            self._busy = False
            self.set_status(f"断开失败: {exc}")

        bearer.Disconnect(reply_handler=done, error_handler=failed)


def main():
    if not Gtk.init_check([]):
        print(
            "无法初始化 GTK 图形环境：请在 KDE 图形会话里运行"
            "（如 Konsole / 应用菜单），不要在串口控制台运行。",
            file=sys.stderr,
        )
        return 1
    CellularGui()
    Gtk.main()
    return 0


if __name__ == "__main__":
    sys.exit(main())
