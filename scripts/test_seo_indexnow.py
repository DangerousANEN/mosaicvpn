import contextlib
import io
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch, MagicMock
import seo_indexnow as subject


class IndexNowTests(unittest.TestCase):
    def test_same_host_deduplicated(self):
        url = subject.HOST_URL + '/blog/'
        self.assertEqual(subject.validate_urls([url, url]), [url])

    def test_invalid_urls_rejected(self):
        for value in ['https://example.org/', subject.HOST_URL + '#fragment',
                      'https://user@' + subject.DOMAIN + '/',
                      subject.HOST_URL + ':443/', subject.HOST_URL + '/bad space',
                      'ftp://' + subject.DOMAIN + '/', '/relative']:
            with self.subTest(value=value), self.assertRaises(ValueError):
                subject.validate_urls([value])
        with self.assertRaises(ValueError):
            subject.validate_urls([])
        with self.assertRaises(ValueError):
            subject.validate_urls([subject.HOST_URL + '/' + str(n) for n in range(10001)])

    def test_sitemap_xml_entities(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'sitemap.xml'
            path.write_text('<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9"><url><loc>https://sub.zxc1x1.ru/?a=1&amp;b=2</loc></url></urlset>')
            with patch.object(subject, 'SITEMAP_FILE', str(path)):
                self.assertEqual(subject.get_sitemap_urls(), [subject.HOST_URL + '/?a=1&b=2'])

    def response(self, code=200, body=b'test-key-123', redirect=False):
        result = MagicMock()
        result.__enter__.return_value = result
        result.getcode.return_value = code
        result.geturl.return_value = subject.HOST_URL + ('/other' if redirect else '/mosaic-indexnow-key.txt')
        result.read.return_value = body
        return result

    def test_remote_key_requires_exact_content_and_target(self):
        for response in [self.response(body=b'wrong'), self.response(code=202), self.response(redirect=True)]:
            with patch.object(subject.urllib.request, 'urlopen', return_value=response), self.assertRaises(ValueError):
                subject.verify_remote_key('test-key-123')
        with patch.object(subject.urllib.request, 'urlopen', return_value=self.response()):
            subject.verify_remote_key('test-key-123')

    def test_no_submission_when_key_not_verified(self):
        with patch.object(subject, 'read_key', return_value='test-key-123'), patch.object(subject, 'verify_remote_key', side_effect=ValueError('missing')), patch.object(subject.urllib.request, 'urlopen') as network, contextlib.redirect_stdout(io.StringIO()):
            self.assertFalse(subject.submit_urls([subject.HOST_URL + '/']))
            network.assert_not_called()

    def test_provider_status_semantics(self):
        for code, success, text in [(200, True, '[RECEIVED]'), (202, True, '[PENDING]'), (204, False, '[UNEXPECTED]')]:
            output = io.StringIO()
            with patch.object(subject, 'read_key', return_value='test-key-123'), patch.object(subject, 'verify_remote_key'), patch.object(subject.urllib.request, 'urlopen', return_value=self.response(code=code)), contextlib.redirect_stdout(output):
                self.assertEqual(subject.submit_urls([subject.HOST_URL + '/']), success)
            self.assertIn(text, output.getvalue())

    def test_dry_run_never_contacts_network(self):
        with patch.object(subject, 'read_key', return_value='test-key-123'), patch.object(subject.urllib.request, 'urlopen') as network, contextlib.redirect_stdout(io.StringIO()):
            self.assertTrue(subject.submit_urls([subject.HOST_URL + '/'], dry_run=True))
            network.assert_not_called()


if __name__ == '__main__':
    unittest.main()
