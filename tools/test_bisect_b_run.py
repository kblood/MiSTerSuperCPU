import os, time, paramiko, base64, re
from collections import Counter
HOST,USER,PASS = '192.168.50.130','root','1'
RBF='/media/fat/_Test/C64.rbf'; CFG='/media/fat/config/C64.cfg'
PRG_LOCAL=os.path.join(os.path.dirname(os.path.abspath(__file__)),'test_bisect_b.prg')
PRG_REMOTE='/tmp/test_bisect_b.prg'
REU_MGL='/tmp/load_doom_reu_only.mgl'; PRG_MGL='/tmp/load_test_bisect_b.mgl'
OUT=os.path.join(os.path.dirname(os.path.abspath(__file__)),'test_bisect_b_run')
def run(c,cmd,t=20):
    _,o,_ = c.exec_command(cmd, timeout=t); return o.read().decode(errors='replace')
def upload(c):
    with open(PRG_LOCAL,'rb') as f: data=f.read()
    b64=base64.b64encode(data).decode()
    run(c,'rm -f {0}.b64 {0}'.format(PRG_REMOTE))
    chunks=[b64[i:i+4096] for i in range(0,len(b64),4096)]
    for i,ch in enumerate(chunks):
        op='>' if i==0 else '>>'; run(c,"echo '"+ch+"' "+op+" "+PRG_REMOTE+".b64")
    run(c,'base64 -d {0}.b64 > {0} && rm {0}.b64'.format(PRG_REMOTE))
def write_mgl(c,p,b):
    run(c,'rm -f '+p)
    for L in b.split('\n'):
        if L.strip(): run(c,"echo '"+L+"' >> "+p)
os.makedirs(OUT,exist_ok=True)
c = paramiko.SSHClient(); c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
c.connect(HOST,username=USER,password=PASS,timeout=15); upload(c)
reu_mgl='<mistergamedescription>\n<rbf>_Test/C64</rbf>\n<file delay="3" type="f" index="1" path="/media/fat/games/C64/doom.reu"/>\n</mistergamedescription>\n'
prg_mgl='<mistergamedescription>\n<rbf>_Test/C64</rbf>\n<file delay="3" type="f" index="1" path="'+PRG_REMOTE+'"/>\n</mistergamedescription>\n'
write_mgl(c,REU_MGL,reu_mgl); write_mgl(c,PRG_MGL,prg_mgl)
run(c,"printf '\x84' | dd of="+CFG+" bs=1 count=1 seek=10 conv=notrunc 2>/dev/null")
print('reload core ...'); run(c,'echo load_core '+RBF+' > /dev/MiSTer_cmd'); time.sleep(8)
print('load doom.reu ...'); run(c,'echo load_core '+REU_MGL+' > /dev/MiSTer_cmd'); time.sleep(40)
print('load test PRG ...'); run(c,'echo load_core '+PRG_MGL+' > /dev/MiSTer_cmd'); time.sleep(15)
out=run(c,'stty -F /dev/ttyS1 115200 raw -echo; timeout 5 cat /dev/ttyS1 2>&1',t=10)
with open(os.path.join(OUT,'uart_5s.txt'),'w',errors='replace') as f: f.write(out)
g_re=re.compile(r'G:([0-9A-Fa-f]{2}) ([0-9A-Fa-f]{2}) ([0-9A-Fa-f]{2})')
gv=g_re.findall(out); print('Total samples:',len(gv))
if gv:
    last=gv[-1]
    print('  $00:$6C00 = $'+last[0]); print('  $2A:$6C00 = $'+last[1]+' <<<<<')
    cv=Counter(g[1] for g in gv); print('hist:',cv.most_common(5))
run(c,'rm -f /media/fat/screenshots/C64/*.png')
run(c,'echo screenshot > /dev/MiSTer_cmd'); time.sleep(2.5)
rp=run(c,'ls -1t /media/fat/screenshots/C64/*.png 2>/dev/null | head -1').strip()
if rp:
    sftp=c.open_sftp(); sftp.get(rp,os.path.join(OUT,'border.png')); sftp.close(); print('saved')
c.close()
