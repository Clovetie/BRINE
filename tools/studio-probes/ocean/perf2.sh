#!/bin/bash
cd /home/user
python3 .mcp/call.py get_console_output '{"level":"Warning","dm":"client","limit":400,"search":"OCEANPERF"}' 2>&1 | python3 -c "
import sys,re,statistics as st
t=sys.stdin.read()
ser=[float(x) for x in re.findall(r'serialMsPerFrame=([0-9.]+)',t)]
wr=[float(x) for x in re.findall(r'writesPerFrame=([0-9.]+)',t)]
par=[float(x) for x in re.findall(r'parallelMsPerFrame=([0-9.]+)',t)]
f=lambda a: (round(st.median(a),3) if a else None)
print('n=%d serialMs/worker=%s writes/worker=%s parallelMs/worker=%s' % (len(ser), f(ser), f(wr), f(par)))
"
