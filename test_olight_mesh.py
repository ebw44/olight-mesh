"""Tests for olight_mesh: crypto round trips with a dummy key set, plus the message encodings.

Run:  uv run python -I -m unittest test_olight_mesh -v
"""
import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import olight_mesh as om  # noqa: E402

DUMMY = {'nid': 0x2C, 'iv_index': 0, 'src': 0x6100,
         'enc_key': bytes(range(16)), 'priv_key': bytes(range(16, 32)), 'app_key': bytes(range(32, 48))}
DUMMY['aid'] = om.k4(DUMMY['app_key'])


class CryptoRoundTrip(unittest.TestCase):
    def setUp(self):
        self.k = DUMMY

    def test_round_trip(self):
        seq, dst, access = 0x123456, 0x0040, om.generic_onoff_get()
        net = om.build_network_pdu(self.k, self.k['src'], dst,
                                   om.access_encrypt(self.k, seq, self.k['src'], dst, access), seq)
        parsed = om.parse_network_pdu(self.k, net)
        self.assertEqual((parsed['src'], parsed['dst'], parsed['seq']), (self.k['src'], dst, seq))
        self.assertEqual(om.access_decrypt(self.k, parsed)[1], access)
        self.assertEqual(om.proxy_pdu(net)[0], 0)

    def test_wrong_key_fails_netmic(self):
        net = om.build_network_pdu(self.k, self.k['src'], 0x0040,
                                   om.access_encrypt(self.k, 1, self.k['src'], 0x0040, b'\x82\x01'), 1)
        self.assertIsNone(om.parse_network_pdu(dict(self.k, enc_key=bytes(16)), net))


class Encodings(unittest.TestCase):
    def test_dp_write(self):
        # vendor write: c9 d0 07 | work mode 01 | 66 04 14  (DP 102 enum = 20)
        self.assertEqual(om.dp_write_access([(102, 'enum', 20)]).hex(), 'c9d00701660414')
        self.assertEqual(om.dp_write_access([(7, 'int', 15)]).hex(), 'c9d0070107020000000f')

    def test_white_mode_write(self):
        # c9 d0 07 00 (work_mode white, no DP items)
        self.assertEqual(om.dp_write_access([], om.WORK_MODE['white']).hex(), 'c9d00700')
        self.assertEqual(om.parse_access(bytes.fromhex('cdd00700'))['work_mode'], 'white')
        self.assertEqual(om.parse_access(bytes.fromhex('cdd00701'))['work_mode'], 'colour')

    def test_dp_report_parse(self):
        # 01 | 67 02 00000064 -> DP 103 int 100
        self.assertEqual(om.parse_dps(bytes.fromhex('01670200000064')), [(103, 'int', 100)])
        self.assertEqual(om.parse_access(bytes.fromhex('cdd00701660414'))['dps'], [(102, 'enum', 20)])

    def test_lightness_and_hsl_encodings(self):
        self.assertEqual(om.lightness_set_access(100, 0x1F).hex(), '824cffff1f')
        # hue 120 deg -> 0x5555
        hsl = om.hsl_set_access(100, 120, 96, 0x11)
        self.assertEqual(hsl[:2].hex(), '8276')
        self.assertEqual(hsl[4:6].hex(), '5555')
        self.assertEqual(len(hsl), 9)
        info = om.parse_access(bytes.fromhex('8276610e555578f511'))
        self.assertEqual(info['op'], 'hsl_set')
        self.assertEqual(info['hue_deg'], 120.0)
        self.assertAlmostEqual(info['sat_pct'], 95.9, delta=0.1)


if __name__ == '__main__':
    unittest.main()
