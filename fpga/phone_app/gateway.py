"""Local phone-to-UART demo gateway. A write is never reported as FPGA acceptance."""
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from pathlib import Path
from urllib.parse import urlparse, parse_qs
from fractions import Fraction
import argparse,json,secrets,threading,time,socket,sys

HERE=Path(__file__).resolve().parent
sys.path.insert(0,str(HERE/'vendor'))
def encode_score(data):
    if not isinstance(data,dict):raise ValueError('曲谱必须是 JSON 对象')
    bpm=data.get('bpm',120);events=data.get('events');tpq=data.get('ticks_per_quarter',12)
    if type(bpm)!=int or not 40<=bpm<=240:raise ValueError('BPM 须为 40–240 的整数')
    if type(tpq)!=int or tpq<=0:raise ValueError('ticks_per_quarter 须为正整数')
    if not isinstance(events,list) or not 1<=len(events)<=255:raise ValueError('每首曲谱须为 1–255 个事件')
    result=bytearray([0x55,0x4c,len(events),bpm])
    for i,e in enumerate(events):
        if not isinstance(e,dict):raise ValueError(f'事件 {i} 格式无效')
        note=e.get('note')
        if type(note)!=int or (note!=0 and not 60<=note<=83):raise ValueError(f'事件 {i} 音高须为休止 0 或 MIDI 60–83')
        if 'length' in e:ln=e['length']
        else:
            ticks=e.get('ticks',tpq)
            if type(ticks)!=int or ticks<=0:raise ValueError(f'事件 {i} ticks 须为正整数')
            scaled=Fraction(ticks*4,tpq)
            if scaled.denominator!=1:raise ValueError(f'事件 {i} 时值不能精确表示，请使用四分之一拍的整数倍')
            ln=int(scaled)
        if type(ln)!=int or not 1<=ln<=15:raise ValueError(f'事件 {i} length 须为 1–15，长音请拆分')
        result.extend([0x55,0x57,i,note,ln])
    result.extend([0x55,0x43])
    return bytes(result)

ALL_NOTES_OFF=b''.join(bytes([0x80,n,0]) for n in range(60,84))

class KeyboardBusy(ValueError):
    pass

class Gateway:
    def __init__(self,port=None,baud=9600,*,lease_seconds=2.0,clock=time.monotonic):
        self.lock=threading.RLock();self.serial=None;self.port=port;self.count=0;self.last='尚未发送';self.held=set()
        self.owner=None;self.clock=clock;self.lease_seconds=lease_seconds;self.last_contact=clock()
        self.error=None;self.release_pending=False;self.auto_releases=0;self.closed=False
        self.stop_event=threading.Event();self.watchdog=None
        self.baud=baud
        if port:
            import serial
            self.serial=serial.Serial(port,baud,timeout=0.5,write_timeout=2)

    @staticmethod
    def ports():
        from serial.tools.list_ports import comports
        return [{'device':p.device,'description':p.description} for p in comports()]

    def connect(self,port,baud):
        if type(baud)!=int or baud not in (9600,19200,38400,57600,115200):
            raise ValueError('不支持的波特率')
        if not isinstance(port,str) or port not in [p['device'] for p in self.ports()]:
            raise ValueError('请选择本机枚举到的串口；蓝牙需先在 Windows 配对')
        with self.lock:
            if self.closed:raise OSError('网关已关闭')
            if self.serial:raise ValueError('请先断开当前串口')
            import serial
            opened=serial.Serial(port,baud,timeout=0.5,write_timeout=2)
            self.serial=opened;self.port=port;self.baud=baud
            self.held.clear();self.owner=None;self.error=None;self.release_pending=False
            self.last='串口已打开；无线链路和 FPGA 接收仍需板上核对'
            return self.status()

    def disconnect(self):
        with self.lock:
            failure=None
            try:
                if self.serial or self.held:self.panic()
            except Exception as e:failure=str(e)
            finally:
                if self.serial:
                    try:self.serial.close()
                    except Exception as e:failure=str(e)
                self.serial=None;self.port=None;self.held.clear();self.owner=None
                self.error=None;self.release_pending=False
            self.last=('串口已关闭，最后释音失败，请复位 FPGA：'+failure if failure
                       else '串口已断开，已切换为协议预演')
            return self.status()|{'disconnect_warning':failure}

    def _write(self,payload):
        """Caller holds lock. A bounded write is not a hardware acknowledgement."""
        if self.closed:raise OSError('网关已关闭')
        try:
            if self.serial:
                n=self.serial.write(payload)
                if n!=len(payload):raise OSError('串口未完整写入')
                # Do not flush here: some unplugged drivers can wait indefinitely
                # for their output queue. Serial.write has a two-second timeout.
        except Exception as e:
            self.error=str(e);self.release_pending=True;self.last_contact=self.clock()
            self.last='串口故障，释音尚未确认；请检查连接，必要时复位 FPGA'
            raise
        self.count+=len(payload)
        self.last='已写入串口，请在 FPGA 屏幕核对' if self.serial else '协议预演完成，未发送到 FPGA'
        return self.status()|{'bytes':len(payload),'hex':payload.hex(' ')}

    def write(self,payload):
        with self.lock:return self._write(payload)

    def status(self):
        with self.lock:
            return {'mode':'uart' if self.serial else 'preview','port':self.port,'baud':self.baud,
                    'sent_bytes':self.count,'message':self.last,'acknowledged':False,
                    'held_notes':sorted(self.held),'keyboard_owner':self.owner,
                    'lease_seconds':self.lease_seconds,'auto_releases':self.auto_releases,
                    'serial_error':self.error,'release_pending':self.release_pending,'closed':self.closed}

    def note(self,note,velocity,client):
        with self.lock:
            if velocity:
                if self.error:raise OSError('串口故障未恢复，请先检查连接并执行全部释音')
                if self.held and self.owner!=client:raise KeyboardBusy('另一页面正在演奏，请等待释音或点击全部释音')
                # Track intent before writing: a flush/driver failure may occur
                # after the physical receiver has already seen the Note On.
                self.owner=client;self.held.add(note);self.last_contact=self.clock()
            elif self.owner is not None and self.owner!=client:
                raise KeyboardBusy('该音符由另一页面控制')
            result=self._write(bytes([0x90 if velocity else 0x80,note,velocity]))
            if not velocity:
                self.held.discard(note)
                if not self.held:self.owner=None
            return result|self.status()

    def heartbeat(self,client):
        with self.lock:
            active=bool(self.held) and self.owner==client and not self.error
            if active:self.last_contact=self.clock()
            return self.status()|{'lease_active':active}

    def panic(self,automatic=False):
        with self.lock:
            result=self._write(ALL_NOTES_OFF)
            self.held.clear();self.owner=None;self.release_pending=False;self.error=None
            if automatic:
                self.auto_releases+=1
                self.last=('演奏心跳超时，已写入释音指令，请核对 FPGA' if self.serial
                           else '演奏心跳超时，已生成释音指令；当前为协议预演')
            return result|self.status()

    def score(self,data):
        payload=encode_score(data)
        with self.lock:
            if self.error:raise OSError('串口故障未恢复，请先检查连接并执行全部释音')
            result=self._write(ALL_NOTES_OFF+payload)
            self.held.clear();self.owner=None;self.release_pending=False
            return result|self.status()

    def expire_notes(self):
        with self.lock:
            if self.closed or not (self.held or self.release_pending):return False
            if self.clock()-self.last_contact<self.lease_seconds:return False
            try:self.panic(automatic=True)
            except Exception:return False  # Error stays visible; retry after lease_seconds.
            return True

    def start_watchdog(self):
        with self.lock:
            if self.watchdog is not None:return
            def run():
                while not self.stop_event.wait(0.1):self.expire_notes()
            self.watchdog=threading.Thread(target=run,name='phone-note-watchdog',daemon=True)
            self.watchdog.start()

    def close(self):
        self.stop_event.set()
        if self.watchdog:self.watchdog.join(timeout=3)
        with self.lock:
            if self.closed:return
            try:
                if self.serial or self.held:self.panic()
            except Exception as e:print('关闭时释音发送失败，请检查 FPGA：'+str(e),file=sys.stderr)
            finally:
                self.closed=True
                if self.serial:self.serial.close()

def serve(gateway,host,port,token):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self,*a):pass
        def reply(self,code,value):
            raw=json.dumps(value,ensure_ascii=False).encode();self.send_response(code)
            self.send_header('Content-Type','application/json; charset=utf-8');self.send_header('Content-Length',str(len(raw)));self.end_headers();self.wfile.write(raw)
        def allowed(self):
            key=self.headers.get('X-Demo-Token','') or parse_qs(urlparse(self.path).query).get('token',[''])[0]
            return secrets.compare_digest(key,token)
        def do_GET(self):
            if not self.allowed():return self.reply(403,{'error':'请打开带访问码的完整地址'})
            if urlparse(self.path).path=='/api/status':return self.reply(200,gateway.status())
            if urlparse(self.path).path=='/api/ports':
                try:return self.reply(200,{'ports':gateway.ports()})
                except Exception as e:return self.reply(503,{'error':str(e)})
            if urlparse(self.path).path in ('/game.js','/game.css','/rhythm-core.js'):
                name=urlparse(self.path).path[1:];raw=(HERE/name).read_bytes()
                self.send_response(200);self.send_header('Content-Type','text/css' if name.endswith('.css') else 'text/javascript')
                self.send_header('Content-Length',str(len(raw)));self.end_headers();self.wfile.write(raw);return
            if urlparse(self.path).path!='/':return self.reply(404,{'error':'不存在'})
            raw=(HERE/'index.html').read_bytes();self.send_response(200);self.send_header('Content-Type','text/html; charset=utf-8');self.send_header('Content-Length',str(len(raw)));self.end_headers();self.wfile.write(raw)
        def do_POST(self):
            if not self.allowed():return self.reply(403,{'error':'访问码错误'})
            try:
                size=int(self.headers.get('Content-Length','0'))
                if not 0<size<=65536:raise ValueError('请求大小无效')
                data=json.loads(self.rfile.read(size));path=urlparse(self.path).path
                if not isinstance(data,dict):raise ValueError('请求必须是 JSON 对象')
                client=data.get('client','legacy')
                if not isinstance(client,str) or not 1<=len(client)<=64:raise ValueError('页面标识无效')
                if path=='/api/score':
                    result=gateway.score(data)
                elif path=='/api/note':
                    note=data.get('note');vel=data.get('velocity',0)
                    if type(note)!=int or not 60<=note<=83 or type(vel)!=int or not 0<=vel<=127:raise ValueError('音高或力度无效')
                    result=gateway.note(note,vel,client)
                elif path=='/api/panic':result=gateway.panic()
                elif path=='/api/heartbeat':result=gateway.heartbeat(client)
                elif path=='/api/connect':result=gateway.connect(data.get('port'),data.get('baud',9600))
                elif path=='/api/disconnect':result=gateway.disconnect()
                else:return self.reply(404,{'error':'不存在'})
                self.reply(200,result)
            except KeyboardBusy as e:self.reply(409,{'error':str(e)})
            except (ValueError,KeyError,TypeError) as e:self.reply(400,{'error':str(e)})
            except Exception as e:self.reply(503,{'error':'串口发送失败：'+str(e)})
    http=ThreadingHTTPServer((host,port),Handler)
    gateway.start_watchdog()
    return http

def main():
    ap=argparse.ArgumentParser();ap.add_argument('--port',help='USB 串口或已配对的 SPP 串口，例如 COM5；省略则仅协议预演')
    ap.add_argument('--baud',type=int,default=9600);ap.add_argument('--host',default='0.0.0.0');ap.add_argument('--http-port',type=int,default=8765)
    args=ap.parse_args();g=Gateway(args.port,args.baud);token=secrets.token_urlsafe(12);http=serve(g,args.host,args.http_port,token)
    try:ip=socket.gethostbyname(socket.gethostname())
    except OSError:ip='电脑局域网IP'
    print('手机和电脑连接同一个 Wi-Fi，浏览器打开：',flush=True)
    print(f'http://{ip}:{args.http_port}/?token={token}',flush=True)
    print(f'电脑预览：http://127.0.0.1:{args.http_port}/?token={token}',flush=True)
    print('模式：'+('UART 实际发送，硬件验收以屏幕变化为准' if args.port else '协议预演，未连接 FPGA'),flush=True)
    try:http.serve_forever()
    except KeyboardInterrupt:pass
    finally:http.server_close();g.close()
if __name__=='__main__':main()
