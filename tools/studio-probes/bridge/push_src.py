import json, subprocess, sys
# usage: push_src.py <parent> <name> <className> <repo_relative_path>
parent, name, cls, rel = sys.argv[1:5]
src = open(f"/home/user/BRINE/{rel}").read()
args = {"parent": parent, "name": name, "className": cls, "source": src}
out = subprocess.run(["python3", "/home/user/.mcp/call.py", "write_script", json.dumps(args)],
                     capture_output=True, text=True, cwd="/home/user").stdout
print(f"{parent}.{name} [{cls}] {len(src)} chars -> {out.strip()[:300]}")
