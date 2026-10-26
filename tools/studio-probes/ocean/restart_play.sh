#!/bin/bash
cd /home/user
python3 -c "
import json,subprocess
args=json.dumps({'dm':'server','timeout':30,'code':'game:GetService(\"StudioTestService\"):EndTest(\"done\") return \"ended\"'})
subprocess.run(['python3','/home/user/.mcp/call.py','probe',args],capture_output=True,text=True)" >/dev/null 2>&1
sleep 10
python3 .mcp/call.py start_stop_play '{"action":"start_play","waitForPeer":true}' 2>&1 | grep -o '"started": [a-z]*\|"serverPeerReady": [a-z]*' | tr '\n' ' '
echo
sleep 6
python3 -c "
import json,subprocess
args=json.dumps({'dm':'client','timeout':40,'code':'return game:GetService(\"Players\").LocalPlayer and game:GetService(\"Players\").LocalPlayer.Name or \"none\"'})
print(subprocess.run(['python3','/home/user/.mcp/call.py','probe',args],capture_output=True,text=True).stdout[:200])" 
