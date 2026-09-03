import io, threading, unittest
from email.message import Message
from urllib.error import HTTPError
import server

class FakeResponse:
    def __init__(self, body=b'ok', content_length=None):
        self.body=body; self.headers=Message(); self.closed=False
        if content_length is not None:self.headers['Content-Length']=str(content_length)
    def __enter__(self): return self
    def __exit__(self,*a): self.close()
    def read(self,n=-1):
        out=self.body[:n]; self.body=self.body[len(out):]; return out
    def close(self): self.closed=True

class FakeOpener:
    def __init__(self,responses):self.responses=list(responses);self.calls=0;self.lock=threading.Lock()
    def open(self,req,timeout=None):
        with self.lock:self.calls+=1;x=self.responses.pop(0)
        if isinstance(x,Exception):raise x
        return x

class MiddlemanTests(unittest.TestCase):
    def setUp(self):server._cache.clear();server._locks.clear()
    def test_redirect_handler_rejects_redirect(self):
        h=server.NoRedirectHandler();req=server.Request('https://example.invalid/a')
        with self.assertRaises(HTTPError) as cm:h.redirect_request(req,None,302,'Found',{},'https://evil.invalid/b')
        self.assertEqual(cm.exception.code,302)
    def test_path_validation_rejects_traversal(self):
        for p in ('../x','a/../x','/x','a\\b',''):
            with self.assertRaises(server.UpstreamFailure):server._validate_path(p)
    def test_size_limit(self):
        old=server.MAX_BYTES;server.MAX_BYTES=3
        try:
            with self.assertRaises(server.UpstreamFailure):server._read_limited(io.BytesIO(b'1234'))
        finally:server.MAX_BYTES=old
    def test_deterministic_4xx_not_retried(self):
        err=HTTPError('https://u/x',422,'unprocessable',{},io.BytesIO(b''));f=FakeOpener([err]);old=server.OPENER;server.OPENER=f
        try:
            with self.assertRaises(server.UpstreamFailure) as cm:server.fetch('manifest.json')
            self.assertEqual(cm.exception.code,422);self.assertEqual(f.calls,1)
        finally:server.OPENER=old
    def test_transient_then_success_retries(self):
        e=HTTPError('https://u/x',503,'busy',{},io.BytesIO(b''));f=FakeOpener([e,FakeResponse(b'abc')]);old=server.OPENER;server.OPENER=f;old_sleep=server.time.sleep;server.time.sleep=lambda _:None
        try:self.assertEqual(server.fetch('manifest.json'),b'abc');self.assertEqual(f.calls,2)
        finally:server.OPENER=old;server.time.sleep=old_sleep
    def test_json_normalization_rejects_invalid_json(self):
        with self.assertRaises(server.UpstreamFailure):server.normalize(b'{bad','config.json')
    def test_single_flight(self):
        class Slow(FakeOpener):
            def open(self,req,timeout=None):
                with self.lock:self.calls+=1
                import time;time.sleep(.05);return FakeResponse(b'abc')
        f=Slow([]);old=server.OPENER;server.OPENER=f;out=[]
        try:
            ts=[threading.Thread(target=lambda:out.append(server.artifact('manifest.json'))) for _ in range(8)]
            [t.start() for t in ts];[t.join() for t in ts];self.assertEqual(f.calls,1);self.assertEqual(out,[b'abc']*8)
        finally:server.OPENER=old
if __name__=='__main__':unittest.main(verbosity=2)
