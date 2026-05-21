#!/usr/bin/env python3
"""Test OSD open + screenshot timing."""
import sys, time
sys.path.insert(0, 'tools')
from mister_debug import ssh, scp_to, scp_from, SCREENSHOT_DIR

# Upload mtype.py
scp_to('tools/mtype.py', '/tmp/mtype.py')

# Open OSD - this takes ~7s (6s settle + key)
print('Sending F12 to open OSD...')
t0 = time.time()
ssh('python3 /tmp/mtype.py f12', timeout=15)
print(f'  mtype.py took {time.time()-t0:.1f}s')
print('OSD should now be open. Taking screenshot in 1s...')
time.sleep(1)

# Take screenshot
ssh('echo screenshot > /dev/MiSTer_cmd')
print('Screenshot triggered. Waiting 2s...')
time.sleep(2)

# Retrieve it
out, _, _ = ssh(f'ls -t {SCREENSHOT_DIR}/*/*.png 2>/dev/null | head -1')
if out:
    scp_from(out.strip(), 'screenshots/osd_timing_test.png')
    print(f'Screenshot saved to screenshots/osd_timing_test.png')

print('OSD should still be open - check MiSTer display!')
