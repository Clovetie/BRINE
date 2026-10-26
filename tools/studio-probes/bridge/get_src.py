import json, subprocess, sys
# usage: get_src.py <Instance.Path> <outfile>
path, outfile = sys.argv[1], sys.argv[2]
code = 'local inst = game' + ''.join(f':FindFirstChild("{p}")' for p in path.split('.')) + '\nif not inst then return "MISSING" end\nreturn inst.Source'
args = json.dumps({'dm': 'edit', 'timeout': 60, 'code': code})
out = subprocess.run(['python3', '/home/user/.mcp/call.py', 'probe', args], capture_output=True, text=True, cwd='/home/user').stdout
i = out.find('"returned"')
if i < 0:
    print(out[:400]); sys.exit(1)
# parse the JSON string value after "returned": "..."
start = out.index(':', i) + 1
dec = json.JSONDecoder()
val, _ = dec.raw_decode(out[start:].lstrip())
inner = json.loads(val) if isinstance(val, str) and val.startswith('{') else {'result': val}
res = inner.get('result', inner)
open(outfile, 'w').write(res if isinstance(res, str) else json.dumps(res))
print('wrote', outfile, len(res) if isinstance(res, str) else '?')
