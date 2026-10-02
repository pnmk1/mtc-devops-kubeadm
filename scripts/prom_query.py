#!/usr/bin/env python3
"""Read Prometheus via a localhost port-forward; never print credentials."""
import argparse
import json
import urllib.parse
import urllib.request

parser = argparse.ArgumentParser()
parser.add_argument('query')
parser.add_argument('--url', default='http://127.0.0.1:19090')
parser.add_argument('--time')
parser.add_argument('--positive', action='store_true')
parser.add_argument('--require-one', action='store_true')
args = parser.parse_args()
params = {'query': args.query}
if args.time:
    params['time'] = args.time
with urllib.request.urlopen(args.url + '/api/v1/query?' + urllib.parse.urlencode(params), timeout=10) as response:
    data = json.load(response)
if data.get('status') != 'success':
    raise SystemExit('Prometheus query failed: ' + json.dumps(data))
results = data['data']['result']
if not results:
    raise SystemExit('Prometheus returned no matching samples')
values = [float(item['value'][1]) for item in results]
if args.require_one and not all(value == 1 for value in values):
    raise SystemExit('Expected every target/metric value to be 1: ' + repr(values))
if args.positive and not all(value > 0 for value in values):
    raise SystemExit('Expected positive metric values: ' + repr(values))
print(json.dumps(data, ensure_ascii=False))

