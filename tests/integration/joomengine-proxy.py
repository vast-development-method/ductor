"""Disposable TLS reverse proxy for the real Joomla MCP integration test."""
import http.client
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import ssl
import sys


class Proxy(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def proxy(self):
        connection = http.client.HTTPConnection("127.0.0.1", 38080, timeout=120)
        try:
            body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
            headers = {key: value for key, value in self.headers.items() if key.lower() not in ("connection", "transfer-encoding")}
            headers["X-Forwarded-Proto"] = "https"
            connection.request(self.command, self.path, body=body, headers=headers)
            response = connection.getresponse()
            data = response.read()
            self.send_response(response.status)
            for key, value in response.getheaders():
                if key.lower() not in ("connection", "transfer-encoding", "content-length"):
                    self.send_header(key, value)
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
        except (OSError, http.client.HTTPException):
            self.send_error(502, "Disposable Joomla test backend unavailable")
        finally:
            connection.close()

    do_GET = proxy
    do_POST = proxy
    do_DELETE = proxy
    do_HEAD = proxy


server = ThreadingHTTPServer(("0.0.0.0", 38443), Proxy)
context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.load_cert_chain(sys.argv[1], sys.argv[2])
server.socket = context.wrap_socket(server.socket, server_side=True)
server.serve_forever()
