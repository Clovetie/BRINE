import json, subprocess, sys
code = open(sys.argv[1]).read()
timeout = int(sys.argv[2]) if len(sys.argv) > 2 else 60
args = json.dumps({"dm": "client", "timeout": timeout, "code": code})
out = subprocess.run(["python3", "/home/user/.mcp/call.py", "probe", args], capture_output=True, text=True).stdout
i = out.find('"returned"')
print(out[i:i+1500] if i >= 0 else out[:1500])
