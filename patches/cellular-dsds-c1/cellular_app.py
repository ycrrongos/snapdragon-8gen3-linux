#!/usr/bin/env python3
import concurrent.futures,datetime,json,os,socket
import gi
gi.require_version('Gtk','3.0')
from gi.repository import Gtk,GLib

SOCK='/run/cerro-cellular/control.sock'
POOL=concurrent.futures.ThreadPoolExecutor(max_workers=2)

def request(action,**values):
    with socket.socket(socket.AF_UNIX,socket.SOCK_STREAM) as s:
        s.settimeout(100);s.connect(SOCK);s.sendall((json.dumps(dict(action=action,**values))+'\n').encode())
        raw=s.makefile('rb').readline(1024*1024)
    result=json.loads(raw)
    if not result.get('ok'):raise RuntimeError(result.get('error','操作未完成'))
    return result['result']

class App(Gtk.Window):
    def __init__(self):
        super().__init__(title='SIM 与短信')
        self.set_default_size(380,720);self.set_border_width(12);self.refreshing=False;self.closed=False;self.busy=False;self.last_messages=None
        self.connect('destroy',self.quit)
        root=Gtk.Box(orientation=Gtk.Orientation.VERTICAL,spacing=10);self.add(root)
        title=Gtk.Label(label='SIM 与短信',xalign=0);title.get_style_context().add_class('title');root.pack_start(title,False,False,0)
        self.info=Gtk.Label(label='正在读取手机状态…',xalign=0);self.info.set_line_wrap(True);root.pack_start(self.info,False,False,0)
        self.book=Gtk.Notebook();root.pack_start(self.book,True,True,0)
        mobile=Gtk.Box(orientation=Gtk.Orientation.VERTICAL,spacing=16);mobile.set_border_width(12)
        self.cards=[]
        for i in (1,2):
            frame=Gtk.Frame(label=f'SIM{i}');label=Gtk.Label(label='正在读取…',xalign=0);label.set_margin_start(12);label.set_margin_end(12);label.set_margin_top(10);label.set_margin_bottom(10);label.set_line_wrap(True);frame.add(label);mobile.pack_start(frame,False,False,0);self.cards.append(label)
        mobile.pack_start(Gtk.Label(label='移动数据使用哪张卡',xalign=0),False,False,0)
        self.data=Gtk.ComboBoxText();self.data.append('0','关闭移动数据');self.data.append('1','SIM1');self.data.append('2','SIM2');self.data.set_active_id('1');mobile.pack_start(self.data,False,False,0)
        self.apply=Gtk.Button(label='应用移动数据选择');self.apply.connect('clicked',self.select_data);mobile.pack_start(self.apply,False,False,0)
        hint=Gtk.Label(label='两张卡同时待机。Wi-Fi 可用时，系统优先使用 Wi-Fi。',xalign=0);hint.set_line_wrap(True);mobile.pack_start(hint,False,False,0)
        self.book.append_page(mobile,Gtk.Label(label='移动网络'))
        sms=Gtk.Box(orientation=Gtk.Orientation.VERTICAL,spacing=8);sms.set_border_width(8)
        form=Gtk.Box(spacing=8);self.sender=Gtk.ComboBoxText();self.sender.append('1','SIM1 发送');self.sender.append('2','SIM2 发送');self.sender.set_active_id('1');form.pack_start(self.sender,False,False,0)
        self.number=Gtk.Entry();self.number.set_placeholder_text('收件人号码');self.number.set_input_purpose(Gtk.InputPurpose.PHONE);form.pack_start(self.number,True,True,0);sms.pack_start(form,False,False,0)
        self.text=Gtk.TextView();self.text.set_wrap_mode(Gtk.WrapMode.WORD_CHAR);self.text.get_buffer().connect('changed',self.count_text)
        compose=Gtk.ScrolledWindow();compose.set_min_content_height(88);compose.add(self.text);sms.pack_start(compose,False,False,0)
        controls=Gtk.Box(spacing=8);self.count=Gtk.Label(label='输入短信内容',xalign=0);controls.pack_start(self.count,True,True,0)
        self.send=Gtk.Button(label='发送');self.send.connect('clicked',self.send_sms);controls.pack_start(self.send,False,False,0);sms.pack_start(controls,False,False,0)
        refresh=Gtk.Button(label='刷新短信');refresh.connect('clicked',lambda *_:self.load_messages());sms.pack_start(refresh,False,False,0)
        self.list=Gtk.ListBox();self.list.set_selection_mode(Gtk.SelectionMode.NONE);scroll=Gtk.ScrolledWindow();scroll.add(self.list);sms.pack_start(scroll,True,True,0)
        self.book.append_page(sms,Gtk.Label(label='短信'));self.book.connect('switch-page',self.page)
        self.show_all();GLib.timeout_add_seconds(5,self.refresh_status);GLib.timeout_add_seconds(12,self.refresh_messages);self.refresh_status();self.load_messages()
        if os.environ.get('CERRO_CELLULAR_UI_AUDIT')=='1':GLib.timeout_add_seconds(5,self.audit)
    def audit(self):
        self.book.set_current_page(1)
        def result():
            allocation=self.get_allocation()
            print(json.dumps({'window_mapped':self.get_mapped(),'width':allocation.width,'height':allocation.height,'cards':len(self.cards),'messages_rendered':len(self.list.get_children()),'sms_page_mapped':self.book.get_nth_page(1).get_mapped(),'root_width':self.get_child().get_allocated_width()},ensure_ascii=False),flush=True)
            return False
        GLib.timeout_add_seconds(2,result)
        return False
    def quit(self,*_):self.closed=True;Gtk.main_quit()
    def async_call(self,action,callback,**values):
        future=POOL.submit(request,action,**values)
        def finished(f):
            try:value=f.result();error=None
            except Exception as e:value=None;error=str(e) if isinstance(e,RuntimeError) else '暂时无法连接手机网络服务'
            if not self.closed:GLib.idle_add(callback,value,error)
        future.add_done_callback(finished)
    def refresh_status(self):
        if self.closed:return False
        if self.refreshing or self.busy:return True
        self.refreshing=True;self.async_call('status',self.status_done);return True
    def status_done(self,value,error):
        self.refreshing=False
        if error:self.info.set_text(error);return
        for row in value['slots']:
            text=(row['number'] or '号码暂未读取')+'\n'+('已注册' if row['registered'] else '正在搜索网络')
            if row.get('operator'):text+=' · '+row['operator']
            if row.get('technology'):text+='\n'+row['technology']
            self.cards[row['slot']-1].set_text(text)
        selected=value['data_slot'];self.data.set_active_id(str(selected))
        self.info.set_text(('移动数据已关闭' if selected==0 else f'移动数据：SIM{selected}') if value['ready'] else '双卡正在初始化…')
    def select_data(self,*_):
        if self.busy:return
        self.busy=True;self.apply.set_sensitive(False);self.info.set_text('正在切换移动数据…')
        self.async_call('select_data',self.data_done,slot=int(self.data.get_active_id()))
    def data_done(self,value,error):
        self.busy=False;self.apply.set_sensitive(True);self.info.set_text(error or '移动数据选择已应用');self.refresh_status()
    def body(self):
        b=self.text.get_buffer();return b.get_text(b.get_start_iter(),b.get_end_iter(),True)
    def count_text(self,*_):
        size=len(self.body().encode('utf-16-be'));parts=1 if size<=140 else (size+133)//134
        self.count.set_text(f'{len(self.body())} 字 · {parts} 条短信')
    def send_sms(self,*_):
        if self.busy:return
        number=self.number.get_text().strip();text=self.body()
        if not number or not text.strip():self.info.set_text('请填写收件人和短信内容');return
        self.busy=True;self.send.set_sensitive(False);self.info.set_text('正在发送短信…')
        self.async_call('send_sms',self.send_done,slot=int(self.sender.get_active_id()),number=number,text=text)
    def send_done(self,value,error):
        self.busy=False;self.send.set_sensitive(True);self.info.set_text(error or '短信已发送')
        if not error:self.text.get_buffer().set_text('');self.load_messages()
    def page(self,book,page,index):
        if index==1:self.load_messages()
    def refresh_messages(self):
        if self.closed:return False
        if self.book.get_current_page()==1 and not self.busy:self.load_messages()
        return True
    def load_messages(self):self.async_call('messages',self.messages_done)
    def messages_done(self,value,error):
        if error:
            if self.book.get_current_page()==1:self.info.set_text(error)
            return
        key=json.dumps(value,ensure_ascii=False)
        if key==self.last_messages:return
        self.last_messages=key
        for row in self.list.get_children():self.list.remove(row)
        for item in value:
            box=Gtk.Box(orientation=Gtk.Orientation.VERTICAL,spacing=6);box.set_border_width(10)
            header=f"SIM{item['slot']} · "+('发给 ' if item['direction']=='out' else '来自 ')+item['number']
            if item.get('time'):header+=' · '+datetime.datetime.fromtimestamp(item['time']).strftime('%m-%d %H:%M')
            h=Gtk.Label(label=header,xalign=0);h.set_line_wrap(True);h.set_max_width_chars(36);h.set_line_wrap_mode(2);box.pack_start(h,False,False,0)
            body=Gtk.Label(label=item['text'],xalign=0);body.set_selectable(True);body.set_line_wrap(True);body.set_line_wrap_mode(2);body.set_max_width_chars(36);box.pack_start(body,False,False,0);self.list.add(box)
        if not value:self.list.add(Gtk.Label(label='还没有短信'))
        self.list.show_all()

App();Gtk.main()
