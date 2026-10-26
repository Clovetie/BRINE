import json, subprocess, sys
parent, name, cls, path = sys.argv[1:5]
src = open(path).read()
args = {"parent": parent, "name": name, "className": cls, "source": src}
out = subprocess.run(["python3", "/home/user/.mcp/call.py", "write_script", json.dumps(args)], capture_output=True, text=True, cwd="/home/user").stdout
print(f"{parent}.{name} {len(src)} -> {'ok\": true' in out and 'ok' or out[:200]}")
