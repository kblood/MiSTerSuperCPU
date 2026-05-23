"""Restore Step 7b RBF to MiSTer (md5 108dd072)."""
import paramiko, time
src = r"C:\LLM\C64\MiSTerSuperCPU\C64_MiSTer\output_files\C64.rbf"
c = paramiko.SSHClient()
c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
c.connect("192.168.50.130", username="root", password="1", timeout=10)
sftp = c.open_sftp()
print("Uploading Step 7b RBF...")
sftp.put(src, "/media/fat/_Test/C64.rbf")
sftp.close()
print("Loading core...")
c.exec_command('echo "load_core /media/fat/_Test/C64.rbf" > /dev/MiSTer_cmd')
time.sleep(14)
c.close()
print("Step 7b restored.")
