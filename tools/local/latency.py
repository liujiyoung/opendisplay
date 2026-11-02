"""Collect opt-in LATENCY-STATS windows without averaging window averages."""
import argparse
import datetime
import json
import math
from pathlib import Path
import statistics
import time


def summarize(rows):
    if not rows:
        raise ValueError('No latency measurements received')
    if {r['transport'] for r in rows} != {'WiFi'}:
        raise ValueError('Measurement must stay on WiFi; USB/mixed runs are invalid')
    if len({r['session'] for r in rows}) != 1:
        raise ValueError('Connection changed during measurement; repeat the run')
    if len({r['quality'] for r in rows}) != 1:
        raise ValueError('Quality changed during measurement; repeat the run')

    def stats(values):
        if not values or not all(math.isfinite(x) and x >= 0 for x in values):
            raise ValueError('Missing or invalid latency samples')
        ordered = sorted(values)
        return {
            'count': len(values), 'mean_ms': statistics.fmean(values),
            'median_ms': statistics.median(values),
            'p95_ms': ordered[math.ceil(.95 * len(ordered)) - 1],
            'max_ms': ordered[-1],
        }

    samples = [x for r in rows for x in r['cursorSamples']]
    paths = [x for r in rows for x in r['cursorPaths']]
    if len(samples) != len(paths):
        raise ValueError('Cursor sample/path counts do not match')
    return {
        'transport': 'WiFi', 'quality': rows[0]['quality'],
        'windows': len(rows), 'seconds': sum(r['seconds'] for r in rows),
        'cursor_roundtrip': stats(samples),
        'app_roundtrip': stats([x for r in rows for x in r['appSamples']]),
        'cursor_udp_samples': paths.count('UDP'),
        'cursor_tcp_samples': paths.count('TCP'),
        'udp_confirmed_windows': sum(bool(r['udpConfirmed']) for r in rows),
        'expired_probes': sum(r['expired'] for r in rows),
        'stalled_windows': sum(r['seconds'] > 7 for r in rows),
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--label', required=True)
    parser.add_argument('--windows', type=int, default=12)
    parser.add_argument('--warmup', type=float, default=10)
    parser.add_argument('--log', type=Path, default=Path.home() / 'Library/Logs/OpenDisplay Dev/opendisplay.log')
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    if args.windows < 1 or args.warmup < 0:
        parser.error('windows must be positive and warmup nonnegative')
    output = args.output or Path('build/Measurements') / (args.label + '.json')
    output.parent.mkdir(parents=True, exist_ok=True)
    started = time.monotonic()
    ready = started + args.warmup + 5  # discard the window straddling warm-up
    deadline = ready + args.windows * 5 + 45
    rows = []
    stream = args.log.open()
    inode = args.log.stat().st_ino
    stream.seek(0, 2)
    print(f'{args.label}: warming up, then collecting {args.windows} complete windows', flush=True)
    try:
        while len(rows) < args.windows:
            now = time.monotonic()
            if now > deadline:
                raise RuntimeError(f'Timed out: only {len(rows)} latency windows received')
            line = stream.readline()
            if not line:
                stat = args.log.stat()
                if stat.st_ino != inode or stat.st_size < stream.tell():
                    stream.close()
                    stream = args.log.open()
                    inode = stat.st_ino
                time.sleep(.1)
                continue
            if now < ready or 'LATENCY-STATS ' not in line:
                continue
            row = json.loads(line.split('LATENCY-STATS ', 1)[1])
            if not 0 < row.get('seconds', 0) <= 30:
                raise RuntimeError('Invalid measurement interval; inspect the run')
            rows.append(row)
            # Validate each sample and the shared conditions as we collect.
            summarize(rows)
            if len(rows) % 3 == 0 or len(rows) == args.windows:
                mean = summarize(rows)['cursor_roundtrip']['mean_ms']
                print(f'{len(rows)}/{args.windows} windows, cursor mean {mean:.2f} ms', flush=True)
        result = {
            'label': args.label,
            'recorded_at': datetime.datetime.now().astimezone().isoformat(),
            'metric': 'iPad probe -> Mac cursor queue -> actual cursor return path -> iPad main-thread cursor update; excludes physical finger/display scanout',
            'summary': summarize(rows), 'windows': rows,
        }
        output.write_text(json.dumps(result, indent=2) + '\n')
        print(json.dumps(result['summary'], indent=2), flush=True)
        print(output.resolve(), flush=True)
    finally:
        stream.close()


if __name__ == '__main__':
    main()
