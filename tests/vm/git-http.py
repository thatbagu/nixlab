# git's smart HTTP protocol (what Argo CD's go-git speaks), via git http-backend.
import http.server, os, subprocess, sys

root = sys.argv[1]

class Handler(http.server.BaseHTTPRequestHandler):
    def run(self):
        path, _, query = self.path.partition("?")
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length) if length else b""
        env = dict(os.environ, GIT_PROJECT_ROOT=root, GIT_HTTP_EXPORT_ALL="1",
                   PATH_INFO=path, QUERY_STRING=query, REQUEST_METHOD=self.command,
                   CONTENT_TYPE=self.headers.get("Content-Type", ""), CONTENT_LENGTH=str(len(body)),
                   REMOTE_ADDR=self.client_address[0])
        out = subprocess.run(["git", "http-backend"], input=body, env=env, capture_output=True).stdout
        head, _, rest = out.partition(b"\r\n\r\n")
        status, headers = 200, []
        for line in head.decode().split("\r\n"):
            k, _, v = line.partition(": ")
            if k.lower() == "status": status = int(v.split()[0])
            elif k: headers.append((k, v))
        self.send_response(status)
        for k, v in headers: self.send_header(k, v)
        self.send_header("Content-Length", str(len(rest)))
        self.end_headers()
        self.wfile.write(rest)
    do_GET = do_POST = run

http.server.ThreadingHTTPServer(("0.0.0.0", int(sys.argv[2])), Handler).serve_forever()
