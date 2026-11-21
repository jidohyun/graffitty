import unittest
from abi import inspect_abi


class AbiTests(unittest.TestCase):
    header = '  Machine:                           AArch64\n'

    def test_baseline(self):
        self.assertEqual(inspect_abi('libc.so.6', 'File: libc.so.6\nName: GLIBC_2.17\nName: GLIBC_2.35', self.header, 'arm64'), (2, 35))

    def test_newer_glibc(self):
        with self.assertRaisesRegex(RuntimeError, 'maximum is 2.35'):
            inspect_abi('libc.so.6', 'File: libc.so.6\nName: GLIBC_2.36', self.header, 'arm64')

    def test_musl_rejected(self):
        for dynamic, headers in [('libc.musl-aarch64.so.1', self.header),
                                 ('', self.header + '      [Requesting program interpreter: /lib/ld-musl-aarch64.so.1]\n')]:
            with self.assertRaisesRegex(RuntimeError, 'musl'):
                inspect_abi(dynamic, '', headers, 'arm64')

    def test_wrong_architecture(self):
        with self.assertRaisesRegex(RuntimeError, 'architecture'):
            inspect_abi('', '', self.header, 'x86_64')

    def test_private_symbols(self):
        with self.assertRaisesRegex(RuntimeError, 'private'):
            inspect_abi('libc.so.6', 'File: libc.so.6\nName: GLIBC_PRIVATE', self.header, 'arm64')

    def test_new_glibc_abi_tag(self):
        with self.assertRaisesRegex(RuntimeError, 'Unsupported glibc ABI'):
            inspect_abi('libc.so.6', 'File: libc.so.6\nName: GLIBC_ABI_DT_RELR', self.header, 'arm64')

    def test_libgcc_version_is_not_glibc(self):
        versions = 'File: libgcc_s.so.1\nName: GLIBC_2.0\nName: GCC_3.0'
        self.assertEqual(inspect_abi('libgcc_s.so.1', versions, self.header, 'arm64'), (0, 0))

    def test_mixed_providers_still_enforce_glibc_ceiling(self):
        versions = 'File: libgcc_s.so.1\nName: GLIBC_2.0\nFile: libc.so.6\nName: GLIBC_2.36'
        with self.assertRaisesRegex(RuntimeError, 'maximum is 2.35'):
            inspect_abi('libc.so.6', versions, self.header, 'arm64')

    def test_libstdcxx_requirements_stay_within_ubuntu_22_04(self):
        ok = 'File: libstdc++.so.6\nName: GLIBCXX_3.4.30\nName: CXXABI_1.3.13\nFile: libc.so.6\nName: GLIBC_2.34'
        self.assertEqual(inspect_abi('libstdc++.so.6', ok, self.header, 'arm64'), (2, 34))
        for tag in ('GLIBCXX_3.4.32', 'CXXABI_1.3.15'):
            with self.assertRaisesRegex(RuntimeError, 'requires libstdc\\+\\+ ' + tag):
                inspect_abi('libstdc++.so.6', 'File: libstdc++.so.6\nName: ' + tag, self.header, 'arm64')
