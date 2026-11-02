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

    def test_adaptive_targets_can_change_but_mode_and_workload_cannot(self):
        metadata = dict(workload='dense', videoConfiguration='hevc:2388x1668:60',
                        bitrateMode='adaptive', videoBitrate=18_000_000,
                        videoPayloadBytes=1_000_000, videoPayloadSeconds=5)
        first = window([1], **metadata)
        second = window([2], **dict(metadata, videoBitrate=9_000_000, videoPayloadBytes=2_000_000))
        result = summarize([first, second])
        self.assertEqual(result['video_target_min'], 9_000_000)
        self.assertEqual(result['video_target_max'], 18_000_000)
        self.assertEqual(result['video_submission_mbps'], 2.4)
        for change in ({'workload': 'simple'}, {'bitrateMode': 'fixed'}, {'videoConfiguration': 'h264:1920x1080:60'}):
            with self.assertRaises(ValueError):
                summarize([first, dict(second, **change)])


if __name__ == '__main__':
    unittest.main()
