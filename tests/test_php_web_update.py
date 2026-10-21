"""Exercise maintenance regeneration and Nginx rollback without a running server."""
import builtins
import importlib.util
import pathlib
import subprocess
import sys
import tempfile
import types
import unittest
from unittest.mock import patch

ROOT = pathlib.Path(__file__).resolve().parents[1]


class PHPWebUpdateTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.config = pathlib.Path(self.temp.name) / 'local.conf'
        self.config.write_text('previous working configuration')
        dependencies = {}
        for name, attributes in {
            'rtyaml': [], 'mailconfig': ['get_mail_domains'],
            'dns_update': ['get_custom_dns_config', 'get_dns_zones'],
            'ssl_certificates': ['get_ssl_certificates', 'get_domain_ssl_files', 'check_certificate'],
            'utils': ['shell', 'safe_domain_name', 'sort_domains'],
        }.items():
            module = types.ModuleType(name)
            for attribute in attributes:
                setattr(module, attribute, lambda *args, **kwargs: None)
            dependencies[name] = module
        with patch.dict(sys.modules, dependencies):
            spec = importlib.util.spec_from_file_location('php_web_update_test', ROOT / 'management/web_update.py')
            self.module = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(self.module)
        self.maintenance = False
        real_open, real_exists = builtins.open, self.module.os.path.exists

        def mapped_open(path, *args, **kwargs):
            if str(path) == '/etc/nginx/conf.d/local.conf':
                path = self.config
            return real_open(path, *args, **kwargs)

        def mapped_exists(path):
            if path == '/var/lib/mailinabox/php-maintenance':
                return self.maintenance
            if path == '/etc/nginx/conf.d/local.conf':
                return real_exists(self.config)
            return real_exists(path)

        patches = [
            patch('builtins.open', mapped_open),
            patch.object(self.module.os.path, 'exists', mapped_exists),
            patch.object(self.module, 'get_web_domains', return_value={'box.example.test'}),
            patch.object(self.module, 'get_web_domains_with_root_overrides', return_value={}),
            patch.object(self.module, 'make_domain_config', return_value='location /mail/ { fastcgi_pass php-fpm; }\n'),
        ]
        for item in patches:
            item.start()
            self.addCleanup(item.stop)

    def test_maintenance_survives_automatic_regeneration(self):
        self.maintenance = True
        with patch.object(self.module, 'shell') as shell:
            self.module.do_web_update({'PRIMARY_HOSTNAME': 'box.example.test'})
        self.assertIn('return 503;', self.config.read_text())
        self.assertNotIn('fastcgi_pass ', self.config.read_text())
        self.assertEqual(shell.call_args_list[0].args[1], ['/usr/sbin/nginx', '-t'])

    def test_completed_upgrade_restores_php_routes(self):
        with patch.object(self.module, 'shell'):
            self.module.do_web_update({'PRIMARY_HOSTNAME': 'box.example.test'})
        self.assertIn('fastcgi_pass php-fpm;', self.config.read_text())
        self.assertIn('mailinabox-fpm.sock', self.config.read_text())

    def test_failed_validation_restores_previous_configuration(self):
        with patch.object(self.module, 'shell', side_effect=subprocess.CalledProcessError(1, 'nginx -t')) as shell:
            with self.assertRaises(subprocess.CalledProcessError):
                self.module.do_web_update({'PRIMARY_HOSTNAME': 'box.example.test'})
        self.assertEqual(self.config.read_text(), 'previous working configuration')
        self.assertEqual(shell.call_count, 1)

    def test_unchanged_configuration_does_not_reload(self):
        with patch.object(self.module, 'shell') as shell:
            self.module.do_web_update({'PRIMARY_HOSTNAME': 'box.example.test'})
            shell.reset_mock()
            self.assertEqual(self.module.do_web_update({'PRIMARY_HOSTNAME': 'box.example.test'}), '')
            shell.assert_not_called()


if __name__ == '__main__':
    unittest.main()
