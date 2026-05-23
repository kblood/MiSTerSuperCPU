"""One-shot: deploy v356 RBF and load it on MiSTer."""
import paramiko, time
src = r"C:\LLM\C64\MiSTerSuperCPU\C64_MiSTer\builds\C64_vanilla-cpu-swap_5b557dab5c_20260519T032825Z_d2687672-dirty.rbf"
c = paramiko.SSHClient()
c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
c.connect("192.168.50.130", username="root", password="1", timeout=10)
sftp = c.open_sftp()
print("Uploading v356 RBF...")
sftp.put(src, "/media/fat/_Test/C64.rbf")
sftp.close()
print("Loading core...")
c.exec_command('echo "load_core /media/fat/_Test/C64.rbf" > /dev/MiSTer_cmd')
time.sleep(14)
c.close()
print("Done.")
