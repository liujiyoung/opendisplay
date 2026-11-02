import unittest
from latency import summarize


def window(samples, **overrides):
    result = dict(transport='WiFi', session='one', quality='best', seconds=5,
                  cursorSamples=samples, cursorPaths=['TCP'] * len(samples),
                  appSamples=[2], udpConfirmed=False, expired=0)
    result.update(overrides)
    return result


class LatencyMeasurementTests(unittest.TestCase):
    def test_means_are_weighted_by_samples_not_windows(self):
        result = summarize([window([1]), window([3, 5, 7])])
        self.assertEqual(result['cursor_roundtrip']['mean_ms'], 4)
        self.assertEqual(result['cursor_roundtrip']['count'], 4)
        self.assertEqual(result['cursor_roundtrip']['p95_ms'], 7)

    def test_usb_mixed_with_wifi_invalidates_comparison(self):
        with self.assertRaises(ValueError):
            summarize([window([1]), window([2], transport='USB')])

    def test_reconnect_or_quality_change_invalidates_comparison(self):
        for change in ({'session': 'two'}, {'quality': 'fast'}):
            with self.assertRaises(ValueError):
                summarize([window([1]), window([2], **change)])

    def test_invalid_or_missing_samples_are_rejected(self):
        for samples in ([], [float('nan')], [-1]):
            with self.assertRaises(ValueError):
                summarize([window(samples)])

    def test_control_transition_or_disagreement_invalidates_run(self):
        with self.assertRaises(ValueError):
            summarize([window([1]), window([2], controlChannel='dedicated')])
        with self.assertRaises(ValueError):
            summarize([window([1], controlChannel='dedicated', senderControlChannel='video')])
        result = summarize([window([1], controlChannel='dedicated', senderControlChannel='dedicated')])
        self.assertEqual(result['control_channel'], 'dedicated')


if __name__ == '__main__':
    unittest.main()
