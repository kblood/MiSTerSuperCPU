import paramiko
c = paramiko.SSHClient()
c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
c.connect('192.168.50.130', username='root', password='1', timeout=5)
cmd = 'echo "agent=c64 task=option-c-step1-layer2-sync since=$(date -Iseconds)" > /tmp/mister_session.lock && cat /tmp/mister_session.lock'
s, o, e = c.exec_command(cmd)
print(o.read().decode())
print(e.read().decode())
c.close()
