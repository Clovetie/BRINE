#!/bin/bash
cd /home/user
python3 .mcp/call.py get_console_output '{"level":"Warning","dm":"client","limit":400,"search":"OCEANPERF"}' 2>&1 | python3 -c "
import sys,json,re
t=sys.stdin.read()
lines=re.findall(r'OCEANPERF[^\"]*', t)
ser=[float(re.search(r'serialMsPerFrame=([0-9.]+)',l).group(1)) for l in lines]
wr=[float(re.search(r'writesPerFrame=([0-9.]+)',l).group(1)) for l in lines]
if not lines: print('no samples'); sys.exit()
print('samples=%d serialMsPerWorkerFrame(median)=%.3f writesPerWorkerFrame(median)=%.0f' % (len(lines), sorted(ser)[len(ser)//2], sorted(wr)[len(wr)//2]))
"
