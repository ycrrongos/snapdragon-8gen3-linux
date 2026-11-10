#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-only
"""Cerro local same-slot Android restore GUI; backend runs through polkit."""
import concurrent.futures
from pathlib import Path
import subprocess
import gi

gi.require_version('Gtk', '3.0')
from gi.repository import Gtk, GLib

BACKEND = '/usr/local/libexec/cerro-switch/switch-backend.sh'
POOL = concurrent.futures.ThreadPoolExecutor(max_workers=1)

class App(Gtk.Window):
    def __init__(self):
        super().__init__(title='系统切换')
        self.set_default_size(400, 640)
        self.set_border_width(20)
        self.working = False
        self.writing = False
        self.connect('delete-event', self.close)
        root = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=14)
        self.add(root)
        title = Gtk.Label(label='Linux → Android', xalign=0)
        title.set_markup('<span size="xx-large" weight="bold">Linux → Android</span>')
        root.pack_start(title, False, False, 0)
        hint = Gtk.Label(label='从已校验的另一槽恢复 Android 的 boot 和 dtbo。\n保持当前活动槽，全部读回验证后重启。', xalign=0)
        hint.set_line_wrap(True)
        root.pack_start(hint, False, False, 0)
        self.status = Gtk.Label(label='点击读取计划后，再确认切换。', xalign=0)
        self.status.set_line_wrap(True)
        root.pack_start(self.status, False, False, 0)
        self.switch = Gtk.Button(label='预览并切换到 Android')
        self.switch.set_size_request(-1, 52)
        self.switch.connect('clicked', lambda *_: self.job(('plan-android',), self.confirm))
        root.pack_start(self.switch, False, False, 0)
        self.import_button = Gtk.Button(label='导入电脑端互切清单…')
        self.import_button.connect('clicked', self.import_manifest)
        root.pack_start(self.import_button, False, False, 0)
        scroller = Gtk.ScrolledWindow()
        scroller.set_policy(Gtk.PolicyType.AUTOMATIC, Gtk.PolicyType.AUTOMATIC)
        self.output = Gtk.TextView(editable=False, cursor_visible=False, wrap_mode=Gtk.WrapMode.WORD_CHAR)
        self.output.get_buffer().set_text('构建版，尚未实机测试。\n\n若当前 Linux 由电脑端脚本切入，可先导入电脑备份目录里的 state.json；应用会核对设备、槽位、Linux 根分区和 Android 缓存。\n\n机内备份和状态保存在 /var/lib/cerro-dualboot-device，保留全部备份以便恢复。')
        scroller.add(self.output)
        root.pack_start(scroller, True, True, 0)

    def append(self, text):
        buffer = self.output.get_buffer()
        buffer.insert(buffer.get_end_iter(), text)
        return False

    def enabled(self):
        self.switch.set_sensitive(not self.working)
        self.import_button.set_sensitive(not self.working)

    def job(self, arguments, after=None, writing=False):
        if self.working:
            return
        self.working, self.writing = True, writing
        self.enabled()
        self.status.set_text('正在执行已确认的切换，请勿关机。' if writing else '正在授权并核对状态…')
        self.output.get_buffer().set_text('')
        def work():
            lines = []
            process = subprocess.Popen(['pkexec', BACKEND, *arguments], stdout=subprocess.PIPE,
                                       stderr=subprocess.STDOUT, text=True, bufsize=1)
            for line in process.stdout:
                lines.append(line)
                GLib.idle_add(self.append, line)
            result = process.wait()
            return result, ''.join(lines)
        def done(future):
            try:
                result, output = future.result()
                error = None if result == 0 else f'操作停止（退出码 {result}），没有继续重启。'
            except Exception as exception:
                error, output = str(exception), ''
            def finish():
                self.working = self.writing = False
                self.enabled()
                self.status.set_text(error or ('操作完成' if writing else '已核对，尚未改写分区'))
                if error:
                    self.append('\n' + error + '\n')
                elif after:
                    after(output)
                return False
            GLib.idle_add(finish)
        POOL.submit(work).add_done_callback(done)

    def confirm(self, plan):
        dialog = Gtk.MessageDialog(transient_for=self, modal=True, message_type=Gtk.MessageType.QUESTION,
                                   buttons=Gtk.ButtonsType.NONE, text='切换到 Android？')
        dialog.format_secondary_text(plan + '\n会先备份当前两槽 boot/dtbo，再恢复清单指定的 Android 两文件。验证后重启，活动槽不变。')
        dialog.add_buttons('取消', Gtk.ResponseType.CANCEL, '备份、恢复并重启', Gtk.ResponseType.OK)
        response = dialog.run()
        dialog.destroy()
        if response == Gtk.ResponseType.OK:
            self.job(('switch-android',), writing=True)

    def import_manifest(self, *_):
        dialog = Gtk.FileChooserDialog(title='选择电脑端互切备份的 state.json', transient_for=self,
                                       action=Gtk.FileChooserAction.OPEN)
        dialog.add_buttons('取消', Gtk.ResponseType.CANCEL, '核对并导入', Gtk.ResponseType.OK)
        file_filter = Gtk.FileFilter()
        file_filter.set_name('JSON 清单')
        file_filter.add_pattern('*.json')
        dialog.add_filter(file_filter)
        response = dialog.run()
        filename = dialog.get_filename()
        dialog.destroy()
        if response == Gtk.ResponseType.OK and filename:
            self.job(('import-host', filename), lambda _: self.status.set_text('清单已验证并导入，尚未改写分区'))

    def close(self, *_):
        if self.writing:
            self.status.set_text('正在执行切换，请等待写入和校验结束。')
            return True
        Gtk.main_quit()
        return False

if __name__ == '__main__':
    app = App()
    app.show_all()
    Gtk.main()
