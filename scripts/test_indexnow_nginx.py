"""Exercise the shipped exact-location snippet using real isolated nginx."""
import pathlib
import subprocess
import tempfile
import time
import urllib.request
import urllib.error
import socket

root = pathlib.Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='mosaic-indexnow-nginx-') as directory:
    temp = pathlib.Path(directory)
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        port = sock.getsockname()[1]
    snippet = (root / 'deploy/nginx-indexnow.conf').read_text()
    snippet = snippet.replace('/etc/letsencrypt/landing', str(root / 'site'))
    config = temp / 'nginx.conf'
    config.write_text(f'''daemon off;
pid {temp}/nginx.pid;
error_log {temp}/error.log;
events {{}}
http {{ client_body_temp_path {temp}/body;
proxy_temp_path {temp}/proxy;
fastcgi_temp_path {temp}/fastcgi;
uwsgi_temp_path {temp}/uwsgi;
scgi_temp_path {temp}/scgi;
access_log off; server {{ listen 127.0.0.1:{port};
{snippet}
location / {{ return 502; }}
}} }}''')
    subprocess.run(['nginx', '-t', '-p', directory, '-c', str(config)], check=True)
    child = subprocess.Popen(['nginx', '-p', directory, '-c', str(config)])
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    try:
        deadline = time.monotonic() + 5
        while True:
            try:
                response = opener.open(f'http://127.0.0.1:{port}/mosaic-indexnow-key.txt', timeout=1)
                break
            except urllib.error.URLError:
                if child.poll() is not None or time.monotonic() >= deadline:
                    raise
                time.sleep(.05)
        with response:
            assert response.status == 200
            assert response.read() == (root / 'site/mosaic-indexnow-key.txt').read_bytes()
            assert response.headers.get_content_type() == 'text/plain'
        try:
            opener.open(f'http://127.0.0.1:{port}/unrelated', timeout=1)
            raise AssertionError('unrelated route unexpectedly changed')
        except urllib.error.HTTPError as error:
            assert error.code == 502
        print('PASS: nginx syntax, exact key HTTP 200/content/type, unrelated route unchanged')
    finally:
        child.terminate()
        child.wait(timeout=5)
