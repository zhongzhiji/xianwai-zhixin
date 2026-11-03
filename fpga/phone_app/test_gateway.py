"""Gateway fault tests use an in-memory serial port; never open physical hardware."""
import json,threading,time,unittest,urllib.request,urllib.error
from unittest.mock import patch
from contextlib import contextmanager
from gateway import Gateway,ALL_NOTES_OFF,KeyboardBusy,encode_score,serve

class Clock:
    def __init__(self):self.now=0.0
    def __call__(self):return self.now
    def advance(self,seconds):self.now+=seconds

class MemorySerial:
    def __init__(self):self.writes=[];self.failure=False;self.partial=False;self.closed=False
    def write(self,payload):
        if self.failure:raise OSError('simulated cable removal')
        self.writes.append(bytes(payload))
        return len(payload)-1 if self.partial else len(payload)
    def flush(self):raise AssertionError('unbounded flush must not be used')
    def close(self):self.closed=True

class GatewayTests(unittest.TestCase):
    def setUp(self):
        self.clock=Clock();self.g=Gateway(clock=self.clock);self.serial=MemorySerial()
        self.g.serial=self.serial;self.g.port='MEMORY_ONLY'
    def tearDown(self):
        self.serial.failure=False;self.serial.partial=False;self.g.close()

    def test_note_bytes_and_release(self):
        self.g.note(60,100,'A');self.g.note(60,0,'A')
        self.assertEqual(self.serial.writes,[bytes.fromhex('90 3c 64'),bytes.fromhex('80 3c 00')])
        self.assertEqual(self.g.status()['held_notes'],[])
        self.assertFalse(self.g.status()['acknowledged'])

    def test_disconnect_sends_release_before_close(self):
        self.g.note(60,100,'A');result=self.g.disconnect()
        self.assertEqual(self.serial.writes[-1],ALL_NOTES_OFF)
        self.assertTrue(self.serial.closed);self.assertEqual(result['mode'],'preview')
        self.assertEqual(result['held_notes'],[]);self.assertIsNone(result['port'])

    def test_disconnect_failure_preserves_warning(self):
        self.serial.failure=True
        result=self.g.disconnect()
        self.assertTrue(result['disconnect_warning']);self.assertEqual(result['mode'],'preview')
        self.assertTrue(self.serial.closed)

    def test_connect_validates_then_opens_default_jdy_baud(self):
        self.g.disconnect()
        with patch.object(Gateway,'ports',return_value=[{'device':'COM_TEST'}]),patch('serial.Serial',return_value=MemorySerial()) as constructor:
            with self.assertRaises(ValueError):self.g.connect('COM_OTHER',9600)
            with self.assertRaises(ValueError):self.g.connect('COM_TEST',12345)
            constructor.assert_not_called()
            result=self.g.connect('COM_TEST',9600)
            constructor.assert_called_once_with('COM_TEST',9600,timeout=.5,write_timeout=2)
            self.assertEqual(result['baud'],9600);self.assertFalse(result['acknowledged'])
            with self.assertRaises(ValueError):self.g.connect('COM_TEST',9600)

    def test_preview_to_real_does_not_replay_preview_keys(self):
        self.g.disconnect();self.g.note(60,100,'A')
        serial=MemorySerial()
        with patch.object(Gateway,'ports',return_value=[{'device':'COM_TEST'}]),patch('serial.Serial',return_value=serial):
            self.g.connect('COM_TEST',9600)
            self.assertEqual(serial.writes,[]);self.assertEqual(self.g.status()['held_notes'],[])

    def test_expiry_sends_all_notes_off_once(self):
        self.g.note(64,100,'A');self.clock.advance(1.99)
        self.assertFalse(self.g.expire_notes());self.clock.advance(.02)
        self.assertTrue(self.g.expire_notes());self.assertEqual(self.serial.writes[-1],ALL_NOTES_OFF)
        self.assertEqual(self.g.auto_releases,1);self.assertFalse(self.g.expire_notes())

    def test_heartbeat_keeps_long_note_alive(self):
        self.g.note(64,100,'A')
        for _ in range(10):
            self.clock.advance(.5);self.assertTrue(self.g.heartbeat('A')['lease_active'])
            self.assertFalse(self.g.expire_notes())
        self.assertEqual(len(self.serial.writes),1)

    def test_other_page_cannot_renew_lease(self):
        self.g.note(60,100,'A');self.clock.advance(1.5)
        self.assertFalse(self.g.heartbeat('B')['lease_active']);self.clock.advance(.6)
        self.assertTrue(self.g.expire_notes())

    def test_other_page_cannot_steal_or_release_note(self):
        self.g.note(60,100,'A')
        with self.assertRaises(KeyboardBusy):self.g.note(64,100,'B')
        with self.assertRaises(KeyboardBusy):self.g.note(60,0,'B')
        self.assertEqual(len(self.serial.writes),1)

    def test_panic_allows_new_controller(self):
        self.g.note(60,100,'A');self.g.panic();self.g.note(64,100,'B')
        self.assertEqual(self.g.status()['keyboard_owner'],'B')

    def test_score_sends_atomic_release_and_complete_frame(self):
        self.g.note(60,100,'A');score={'bpm':140,'events':[{'note':64,'length':4}]}
        self.g.score(score)
        self.assertEqual(self.serial.writes[-1],ALL_NOTES_OFF+encode_score(score))
        self.assertEqual(self.g.status()['held_notes'],[])

    def test_invalid_score_does_not_write(self):
        self.g.note(60,100,'A')
        with self.assertRaises(ValueError):self.g.score({'events':[]})
        self.assertEqual(len(self.serial.writes),1)

    def test_failed_note_retains_uncertain_state(self):
        self.serial.failure=True
        with self.assertRaises(OSError):self.g.note(60,100,'A')
        self.assertTrue(self.g.status()['release_pending']);self.assertTrue(self.g.status()['serial_error'])
        self.assertEqual(self.g.status()['held_notes'],[60]);self.assertEqual(self.g.count,0)

    def test_partial_write_is_not_success(self):
        self.serial.partial=True
        with self.assertRaises(OSError):self.g.note(60,100,'A')
        self.assertEqual(self.g.count,0);self.assertTrue(self.g.status()['release_pending'])

    def test_failure_retries_are_spaced_and_recover(self):
        self.g.note(60,100,'A');self.serial.failure=True;self.clock.advance(2.1)
        self.assertFalse(self.g.expire_notes());self.clock.advance(.1)
        self.assertFalse(self.g.expire_notes());self.serial.failure=False;self.clock.advance(2)
        self.assertTrue(self.g.expire_notes());self.assertIsNone(self.g.status()['serial_error'])
        self.assertFalse(self.g.status()['release_pending'])

    def test_fault_blocks_new_music_until_panic(self):
        self.serial.failure=True
        with self.assertRaises(OSError):self.g.note(60,100,'A')
        self.serial.failure=False
        with self.assertRaises(OSError):self.g.note(64,100,'A')
        with self.assertRaises(OSError):self.g.score({'events':[{'note':60,'length':4}]})
        self.g.panic();self.g.note(64,100,'A')
        self.assertEqual(self.serial.writes[-1],bytes.fromhex('90 40 64'))

    def test_preview_expiry_does_not_claim_hardware(self):
        g=Gateway(clock=self.clock);g.note(60,100,'A');self.clock.advance(2.1)
        self.assertTrue(g.expire_notes());s=g.status()
        self.assertEqual(s['mode'],'preview');self.assertFalse(s['acknowledged'])
        self.assertIn('预演',s['message']);g.close()

    @contextmanager
    def http(self):
        server=serve(self.g,'127.0.0.1',0,'test-token')
        worker=threading.Thread(target=server.serve_forever,daemon=True);worker.start()
        try:yield 'http://127.0.0.1:'+str(server.server_port)
        finally:server.shutdown();server.server_close();worker.join();self.g.close()

    def call(self,url,data,token='test-token'):
        request=urllib.request.Request(url,data=json.dumps(data).encode(),headers={'X-Demo-Token':token,'Content-Type':'application/json'})
        try:
            with urllib.request.urlopen(request,timeout=3) as r:return r.status,json.load(r)
        except urllib.error.HTTPError as e:return e.code,json.load(e)

    def test_http_validates_body_token_and_ownership(self):
        with self.http() as base:
            self.assertEqual(self.call(base+'/api/note',[])[0],400)
            self.assertEqual(self.call(base+'/api/note',{},token='wrong')[0],403)
            self.assertEqual(self.call(base+'/api/heartbeat',{'client':[]} )[0],400)
            self.assertEqual(self.call(base+'/api/note',{'client':'A','note':60,'velocity':100})[0],200)
            self.assertEqual(self.call(base+'/api/note',{'client':'B','note':64,'velocity':100})[0],409)
            self.assertFalse(self.call(base+'/api/heartbeat',{'client':'B'})[1]['lease_active'])

    def test_http_watchdog_runs_without_further_requests(self):
        self.g.clock=time.monotonic;self.g.lease_seconds=.15
        with self.http() as base:
            self.call(base+'/api/note',{'client':'A','note':60,'velocity':100})
            deadline=time.monotonic()+2
            while self.g.status()['auto_releases']==0 and time.monotonic()<deadline:time.sleep(.02)
            self.assertEqual(self.g.status()['auto_releases'],1)
            self.assertEqual(self.serial.writes[-1],ALL_NOTES_OFF)
        self.assertFalse(self.g.watchdog.is_alive())

if __name__=='__main__':unittest.main(verbosity=2)
