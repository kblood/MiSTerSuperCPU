import paramiko, time, sys
# Upload mtype if missing
c=paramiko.SSHClient()
c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
c.connect('192.168.50.130', username='root', password='1', look_for_keys=False, allow_agent=False)
# Build a one-shot BASIC program that prints all counters
# Use short lines (<80 chars each)
prog = (
  '?"DL"PEEK(57328)"INJ"PEEK(57329)\r'  # $DFF0/$DFF1
  '?"ANY"PEEK(57330)"IDX"PEEK(57331)\r' # $DFF2/$DFF3
  '?"CLS"PEEK(57332)"RBX"PEEK(57333)\r' # $DFF4/$DFF5
  '?"LL"PEEK(57334)"LH"PEEK(57335)\r'   # $DFF6/$DFF7 prg_link_lo/hi
  '?"RSL"PEEK(57336)"RSH"PEEK(57337)\r' # $DFF8/$DFF9 req_set lo/hi
  '?"RCL"PEEK(57338)"RCH"PEEK(57339)\r' # $DFFA/$DFFB req_cons lo/hi
  '?"CWC"PEEK(57340)"CWD"PEEK(57341)\r' # $DFFC/$DFFD wr_0801 cnt/data
  '?"FL"PEEK(57342)"ST"PEEK(57343)\r'   # $DFFE/$DFFF fall/strk
  '?"L1"PEEK(2049)"L2"PEEK(2050)\r'     # $0801/$0802 link
  '?"TT"PEEK(43)"TH"PEEK(44)\r'         # TXTTAB $2B/$2C
  '?"VL"PEEK(45)"VH"PEEK(46)\r'         # VARTAB $2D/$2E
  '?"B20"PEEK(2080)"B21"PEEK(2081)\r'   # $0820/$0821 ML area
)
# Upload mtype.py (may already exist but ensure)
sftp=c.open_sftp()
try: sftp.put('tools/mtype.py','/tmp/mtype.py')
except: pass
sftp.close()
# Type it all in one batch (<< one-shot-per-lifetime rule)
i,o,e=c.exec_command(f"python3 /tmp/mtype.py '{prog}'")
print("mtype result:", o.read().decode(), e.read().decode())
time.sleep(8)
c.close()
