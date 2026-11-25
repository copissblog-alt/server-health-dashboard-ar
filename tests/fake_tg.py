# خادم تيليجرام مزيف: يكتب كل رسالة في ملف سطراً سطراً. إن وُجد ملف DOWN يرد 502.
import os, sys, urllib.parse
from http.server import BaseHTTPRequestHandler, HTTPServer
log, port = sys.argv[1], int(sys.argv[2])
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get('Content-Length', 0))).decode()
        if os.path.exists(log + '.down'):
            self.send_response(502); self.end_headers(); return
        text = urllib.parse.parse_qs(body).get('text', [''])[0].replace('\n', ' ')
        with open(log, 'a') as f: f.write(text + '\n')
        self.send_response(200); self.end_headers(); self.wfile.write(b'{"ok":true}')
HTTPServer(('127.0.0.1', port), H).serve_forever()
