#!/usr/bin/env python
import os
import re
import subprocess
import sys

SCENARIOS = {
    'midpoint': [r'TEST_RESULT .*requested=132 accepted=132 acknowledged=132 status=SUCCESS',
                 r'TEST_RECEIVER_RESULT consumed=132 mismatches=0', r'DATA_TX .*outstanding=12',
                 r'FIN_TX ', r'CLEANUP .*TIME_WAIT expired'],
    'baseline': [r'TEST_RESULT .*requested=1201 accepted=1201 acknowledged=1201 status=SUCCESS',
                 r'TEST_RECEIVER_RESULT consumed=1201 mismatches=0', r'CLEANUP .*TIME_WAIT expired',
                 r'DATA_TX .*len=9 .*outstanding=', r'DATA_TX .*outstanding=(?:24|36|48)'],
    'data-loss': [r'DATA_DISCARD .*seq=2', r'ACK_TX ack=2', r'RETX seq=2',
                  r'TEST_RESULT .*status=SUCCESS', r'TEST_RECEIVER_RESULT consumed=1201 mismatches=0'],
    'ack-loss': [r'TEST_DROP .*', r'ACK_RX ack=26', r'TEST_RESULT .*status=SUCCESS',
                 r'TEST_RECEIVER_RESULT consumed=1201 mismatches=0'],
    'flow': [r'ACK_TX ack=130 wnd=0', r'TEST_DROP .*', r'ACK_TX ack=130 wnd=(?!0)',
             r'TEST_RESULT .*requested=300 accepted=300 acknowledged=300 status=SUCCESS',
             r'TEST_RECEIVER_RESULT consumed=300 mismatches=0'],
    'syn-loss': [r'SYN_TX', r'TEST_DROP .*', r'TEST_RESULT .*status=SUCCESS'],
    'synack-loss': [r'SYN_ACK_TX', r'TEST_DROP .*', r'TEST_RESULT .*status=SUCCESS'],
    'handshake-ack-loss': [r'TEST_DROP .*', r'SYN_ACK_TX', r'TEST_RESULT .*status=SUCCESS'],
    'close-ack-loss': [r'TEST_DROP .*', r'FIN_TX ', r'TEST_RESULT .*status=SUCCESS', r'CLEANUP .*TIME_WAIT expired'],
    'failure': [r'FAILURE .*retries=8', r'CLEANUP .*reason=RETRY_LIMIT'],
    'overlap': [r'ALLOC', r'TEST_RESULT .*requested=701 .*status=SUCCESS',
                r'TEST_RESULT .*requested=907 .*status=SUCCESS'],
    'noisy': [r'TEST_RESULT .*status=SUCCESS', r'TEST_RECEIVER_RESULT consumed=1201 mismatches=0'],
}

def main():
    root = os.path.dirname(os.path.abspath(__file__))
    outdir = os.path.join(root, 'validation', 'logs')
    if not os.path.isdir(outdir):
        os.makedirs(outdir)

    rows = []
    for name, patterns in SCENARIOS.items():
        print 'Running', name
        proc = subprocess.Popen([sys.executable, 'run.py', name], cwd=root, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        output = proc.communicate()[0]
        if not isinstance(output, str):
            output = output.decode('utf-8', 'replace')

        path = os.path.join(outdir, name + '.log')
        open(path, 'w').write(output)
        missing = [p for p in patterns if not re.search(p, output)]
        
        ping_ok = ('route-check' in output)
        expected_allocations = 2 if name == 'overlap' else (0 if name == 'failure' else 1)
        allocations = len(re.findall(r'\bALLOC ', output))
        allocation_ok = allocations == expected_allocations
        control_retries_ok = True

        if name == 'syn-loss':
            control_retries_ok = len(re.findall(r'\bSYN_RETX ', output)) >= 1
        elif name in ('synack-loss', 'handshake-ack-loss'):
            control_retries_ok = len(re.findall(r'\bSYN_ACK_TX ', output)) >= 2
        elif name == 'close-ack-loss':
            control_retries_ok = len(re.findall(r'\bFIN_RETX ', output)) >= 1

        flow_events_ok = True
        if name == 'flow':
            zero = re.search(r'ACK_TX ack=130 wnd=0', output)
            resumed = re.search(r'CONSUMER_RESUME', output)
            drop = re.search(r'TEST_DROP .*ack=130', output)
            reopen = re.search(r'ACK_TX ack=130 wnd=[1-9]', output)
            flow_events_ok = bool(zero and resumed and drop and reopen and zero.start() < resumed.start() < reopen.start() < drop.start())

        status = 'PASS' if proc.returncode == 0 and not missing and ping_ok and allocation_ok and control_retries_ok and flow_events_ok else 'FAIL'
        rows.append((name, status, proc.returncode, missing, ping_ok, output))
        print ' ', status, 'exit=', proc.returncode, 'route-check=', ping_ok, 'allocations=', allocations
        for p in missing:
            print '  missing:', p

    report = ['# Transport validation results', '', '',
              'Topology: `topo/line4.topo` (nodes 1-4, bidirectional links); noise: `noise/no_noise.txt`, but `noisy` uses `noise/moderate_noise.txt`.',
              'Each scenario runs 30 simulated seconds for route establishment, sends three `route-check` pings from node 1 to node 4, then executes the scenario. Logs are in `validation/logs/`.', '',
              '| Scenario | Result | Exit | Route ping observed | Evidence |', '|---|---:|---:|---:|---|']

    for name, status, code, missing, ping_ok, output in rows:
        lines = output.splitlines()
        markers = [r'Node 1 received ping reply from 4: route-check', r'TEST_OPEN', r'SYN_TX', r'SYN_ACK_TX',
                   r'STATE ESTABLISHED', r'ALLOC ', r'TEST_DROP ', r'DATA_DISCARD ', r'RETX ', r'TIMEOUT ',
                   r'ACK_RX ack=26', r'ACK_TX ack=2 wnd=', r'ACK_TX ack=130 wnd=0', r'ACK_TX ack=130 wnd=[1-9]',
                   r'SYN_RETX ', r'FIN_RETX ', r'TEST_RESULT ', r'TEST_RECEIVER_RESULT ', r'FAILURE ', r'CLEANUP ']
        if name == 'baseline':
            markers += [r'DATA_TX .*outstanding=(?:24|36|48)', r'DATA_TX .*len=9 ']

        evidence = []
        for marker in markers:
            match = next((line for line in lines if re.search(marker, line)), None)
            if match and match not in evidence:
                evidence.append(match.strip().replace('|', '\\|'))

        report.append('| %s | **%s** | %s | %s | %s |' % (name, status, code, 'yes' if ping_ok else 'no', '<br>'.join(evidence)))
        if missing:
            report.append('')
            report.append('Missing expected markers for **%s**: `%s`' % (name, '`, `'.join(missing)))
        if not allocation_ok:
            report.append('')
            report.append('Expected %s connection allocation(s), observed %s for **%s**.' % (expected_allocations, allocations, name))
        if not control_retries_ok:
            report.append('Expected the dropped control packet to trigger a retransmission for **%s**.' % name)
        if not flow_events_ok:
            report.append('Flow-control event order did not show zero window, resume, dropped reopening update, and reopened window for **%s**.' % name)
    report += ['', '', '']
    open(os.path.join(root, 'validation', 'observed-results.md'), 'w').write('\n'.join(report))
    sys.exit(0 if all(r[1] == 'PASS' for r in rows) else 1)

if __name__ == '__main__':
    main()
