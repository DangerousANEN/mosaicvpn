"""
Unit tests for Collector v3 URI parser and country extraction.
"""
import unittest
import json
import urllib.parse
import base64
import re
from typing import Optional

OWN_HOSTS = {
    '5.175.188.152',
    'sub.zxc1x1.ru',
    'panel.zxc1x1.ru',
    'zxc1x1.ru',
}

def is_forbidden_host(host: str) -> bool:
    if not host:
        return True
    host_lower = host.lower()
    return host_lower in OWN_HOSTS or any(host_lower.endswith('.' + h) for h in OWN_HOSTS)

def parse_uri_to_singbox(raw: str, tag: str) -> Optional[dict]:
    raw = raw.strip()
    if not raw or '://' not in raw:
        return None

    parsed = urllib.parse.urlsplit(raw)
    scheme = parsed.scheme.lower()
    if is_forbidden_host(parsed.hostname):
        return None

    query = urllib.parse.parse_qs(parsed.query)
    q = {k: v[0] for k, v in query.items()}

    ttype = (q.get('type') or 'tcp').lower()
    if ttype in ('xhttp', 'splithttp'):
        return None

    if scheme == 'vless':
        uuid = parsed.username
        host = parsed.hostname
        port = parsed.port
        if not uuid or not host or not port:
            return None

        security = q.get('security', 'none').lower()
        sni = q.get('sni') or q.get('peer') or host
        fp_tls = q.get('fp', 'chrome')
        pbk = q.get('pbk')
        sid = q.get('sid', '')
        flow = q.get('flow', '')

        outbound = {
            'type': 'vless',
            'tag': tag,
            'server': host,
            'server_port': port,
            'uuid': uuid,
        }
        if flow:
            outbound['flow'] = flow

        if security == 'reality' and pbk:
            outbound['tls'] = {
                'enabled': True,
                'server_name': sni,
                'utls': {'enabled': True, 'fingerprint': fp_tls or 'chrome'},
                'reality': {
                    'enabled': True,
                    'public_key': pbk,
                    'short_id': sid,
                },
            }
        elif security == 'tls':
            tls = {
                'enabled': True,
                'server_name': sni,
                'utls': {'enabled': True, 'fingerprint': fp_tls or 'chrome'},
            }
            if q.get('allowInsecure') in ('1', 'true') or q.get('insecure') in ('1', 'true'):
                tls['insecure'] = True
            outbound['tls'] = tls

        if ttype == 'ws':
            outbound['transport'] = {
                'type': 'ws',
                'path': q.get('path') or '/',
                'headers': {'Host': q.get('host') or sni},
            }
        elif ttype == 'grpc':
            outbound['transport'] = {
                'type': 'grpc',
                'service_name': q.get('serviceName') or '',
            }
        elif ttype == 'httpupgrade':
            outbound['transport'] = {
                'type': 'httpupgrade',
                'path': q.get('path') or '/',
                'host': q.get('host') or sni,
            }
        return outbound

    elif scheme == 'trojan':
        password = parsed.username
        host = parsed.hostname
        port = parsed.port
        if not password or not host or not port:
            return None
        sni = q.get('sni') or host
        outbound = {
            'type': 'trojan',
            'tag': tag,
            'server': host,
            'server_port': port,
            'password': password,
            'tls': {
                'enabled': True,
                'server_name': sni,
            }
        }
        if q.get('allowInsecure') in ('1', 'true') or q.get('insecure') in ('1', 'true'):
            outbound['tls']['insecure'] = True
        if ttype == 'ws':
            outbound['transport'] = {
                'type': 'ws',
                'path': q.get('path') or '/',
                'headers': {'Host': q.get('host') or sni},
            }
        elif ttype == 'grpc':
            outbound['transport'] = {
                'type': 'grpc',
                'service_name': q.get('serviceName') or '',
            }
        return outbound

    elif scheme == 'ss':
        netloc = parsed.netloc
        if '@' in netloc:
            userinfo, hostport = netloc.split('@', 1)
            try:
                padded = userinfo + '=' * (-len(userinfo) % 4)
                decoded = base64.b64decode(padded).decode('utf-8')
                if ':' in decoded:
                    method, password = decoded.split(':', 1)
                else:
                    method, password = userinfo.split(':', 1)
            except Exception:
                if ':' in userinfo:
                    method, password = userinfo.split(':', 1)
                else:
                    return None
            if ':' in hostport:
                host, port_str = hostport.split(':', 1)
                port = int(port_str)
            else:
                return None
        else:
            try:
                padded = netloc + '=' * (-len(netloc) % 4)
                decoded = base64.b64decode(padded).decode('utf-8')
                if '@' in decoded and ':' in decoded:
                    up, hp = decoded.split('@', 1)
                    method, password = up.split(':', 1)
                    host, port_str = hp.split(':', 1)
                    port = int(port_str)
                else:
                    return None
            except Exception:
                return None

        return {
            'type': 'shadowsocks',
            'tag': tag,
            'server': host,
            'server_port': port,
            'method': method,
            'password': password,
        }

    elif scheme == 'hysteria2':
        auth = parsed.username or parsed.password
        host = parsed.hostname
        port = parsed.port
        if not host or not port:
            return None
        sni = q.get('sni') or host
        return {
            'type': 'hysteria2',
            'tag': tag,
            'server': host,
            'server_port': port,
            'password': auth or '',
            'tls': {
                'enabled': True,
                'server_name': sni,
                'insecure': q.get('insecure') in ('1', 'true'),
            }
        }

    return None


class TestUriParser(unittest.TestCase):
    def test_vless_reality(self):
        uri = "vless://d7108b53-e99d-422e-a2d8-4f4c237efda0@1.2.3.4:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=speedtest.net&fp=chrome&pbk=JyJ5HHur3kUOHb_zlo2NDCjTnFeluB60eWc2C7VSLAU&sid=9a0088fb#TestReality"
        ob = parse_uri_to_singbox(uri, "test-reality")
        self.assertIsNotNone(ob)
        self.assertEqual(ob["type"], "vless")
        self.assertEqual(ob["server"], "1.2.3.4")
        self.assertEqual(ob["server_port"], 443)
        self.assertEqual(ob["uuid"], "d7108b53-e99d-422e-a2d8-4f4c237efda0")
        self.assertEqual(ob["flow"], "xtls-rprx-vision")
        self.assertTrue(ob["tls"]["reality"]["enabled"])
        self.assertEqual(ob["tls"]["reality"]["public_key"], "JyJ5HHur3kUOHb_zlo2NDCjTnFeluB60eWc2C7VSLAU")
        self.assertEqual(ob["tls"]["utls"]["fingerprint"], "chrome")

    def test_vless_ws_tls(self):
        uri = "vless://d7108b53-e99d-422e-a2d8-4f4c237efda0@5.6.7.8:8443?type=ws&security=tls&sni=example.com&path=%2Fws#TestWS"
        ob = parse_uri_to_singbox(uri, "test-ws")
        self.assertIsNotNone(ob)
        self.assertEqual(ob["type"], "vless")
        self.assertEqual(ob["transport"]["type"], "ws")
        self.assertEqual(ob["transport"]["path"], "/ws")
        self.assertTrue(ob["tls"]["enabled"])

    def test_reject_xhttp(self):
        uri = "vless://d7108b53-e99d-422e-a2d8-4f4c237efda0@1.2.3.4:443?type=xhttp&security=tls#BadXHTTP"
        ob = parse_uri_to_singbox(uri, "bad-xhttp")
        self.assertIsNone(ob)

    def test_reject_own_server(self):
        uri = "vless://d7108b53-e99d-422e-a2d8-4f4c237efda0@5.175.188.152:443?security=reality#OwnServer"
        ob = parse_uri_to_singbox(uri, "own-server")
        self.assertIsNone(ob)

        uri2 = "vless://d7108b53-e99d-422e-a2d8-4f4c237efda0@sub.zxc1x1.ru:443?security=reality#OwnDomain"
        self.assertIsNone(parse_uri_to_singbox(uri2, "own-domain"))

    def test_trojan(self):
        uri = "trojan://secret-password@9.10.11.12:443?sni=trojan.test#TestTrojan"
        ob = parse_uri_to_singbox(uri, "test-trojan")
        self.assertIsNotNone(ob)
        self.assertEqual(ob["type"], "trojan")
        self.assertEqual(ob["password"], "secret-password")
        self.assertEqual(ob["tls"]["server_name"], "trojan.test")

    def test_shadowsocks(self):
        # chacha20-ietf-poly1305:mysecretpassword
        uinfo = base64.b64encode(b"chacha20-ietf-poly1305:mysecretpassword").decode("utf-8")
        uri = f"ss://{uinfo}@13.14.15.16:8388#TestSS"
        ob = parse_uri_to_singbox(uri, "test-ss")
        self.assertIsNotNone(ob)
        self.assertEqual(ob["type"], "shadowsocks")
        self.assertEqual(ob["method"], "chacha20-ietf-poly1305")
        self.assertEqual(ob["password"], "mysecretpassword")
        self.assertEqual(ob["server"], "13.14.15.16")
        self.assertEqual(ob["server_port"], 8388)

    def test_hysteria2(self):
        uri = "hysteria2://myauth@17.18.19.20:443?sni=hy2.example.com&insecure=1#TestHy2"
        ob = parse_uri_to_singbox(uri, "test-hy2")
        self.assertIsNotNone(ob)
        self.assertEqual(ob["type"], "hysteria2")
        self.assertEqual(ob["password"], "myauth")
        self.assertEqual(ob["tls"]["server_name"], "hy2.example.com")
        self.assertTrue(ob["tls"]["insecure"])


if __name__ == "__main__":
    unittest.main()
