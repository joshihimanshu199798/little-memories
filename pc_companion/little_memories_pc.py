import json
import os
import threading
import urllib.parse
import urllib.request
import tkinter as tk
from tkinter import filedialog, messagebox, ttk

APP_NAME = "Little Memories PC Companion"
MANIFEST = ".little_memories_backup.json"

class Companion(tk.Tk):
    def __init__(self):
        super().__init__()
        self.title(APP_NAME)
        self.geometry("760x560")
        self.minsize(680, 500)
        self.url = tk.StringVar()
        self.folder = tk.StringVar(value=os.path.join(os.path.expanduser("~"), "Pictures", "Little Memories"))
        self.status = tk.StringVar(value="Connect your phone and paste the QR/browser URL.")
        self.progress = tk.DoubleVar()
        self.data = []

        root = ttk.Frame(self, padding=20)
        root.pack(fill="both", expand=True)

        ttk.Label(root, text=APP_NAME, font=("Segoe UI", 22, "bold")).pack(anchor="w")
        ttk.Label(root, text="Local Wi-Fi backup • no cloud required", font=("Segoe UI", 10)).pack(anchor="w", pady=(0,18))

        box = ttk.LabelFrame(root, text="1. Phone connection", padding=14)
        box.pack(fill="x")
        ttk.Label(box, text="Paste the address shown in Little Memories → Connect to Windows PC:").pack(anchor="w")
        ttk.Entry(box, textvariable=self.url).pack(fill="x", pady=8)
        ttk.Button(box, text="Test connection", command=self.test).pack(anchor="e")

        dest = ttk.LabelFrame(root, text="2. Backup folder", padding=14)
        dest.pack(fill="x", pady=12)
        row = ttk.Frame(dest); row.pack(fill="x")
        ttk.Entry(row, textvariable=self.folder).pack(side="left", fill="x", expand=True)
        ttk.Button(row, text="Choose…", command=self.choose).pack(side="left", padx=(8,0))

        actions = ttk.Frame(root); actions.pack(fill="x", pady=8)
        ttk.Button(actions, text="Backup new photos", command=self.backup).pack(side="left")
        ttk.Button(actions, text="Full backup", command=lambda: self.backup(full=True)).pack(side="left", padx=8)

        ttk.Progressbar(root, variable=self.progress, maximum=100).pack(fill="x", pady=12)
        ttk.Label(root, textvariable=self.status, wraplength=700).pack(anchor="w")

        logbox = ttk.LabelFrame(root, text="Backup log", padding=8)
        logbox.pack(fill="both", expand=True, pady=(14,0))
        self.log = tk.Text(logbox, height=12, state="disabled", font=("Consolas", 9))
        self.log.pack(fill="both", expand=True)

    def choose(self):
        p = filedialog.askdirectory(initialdir=self.folder.get())
        if p: self.folder.set(p)

    def base(self):
        u = self.url.get().strip()
        if not u.startswith("http://") and not u.startswith("https://"):
            raise ValueError("Paste the complete address from the phone, including http://")
        return u.rstrip("/") + "/"

    def get_json(self, path):
        u = self.base() + path.lstrip("/")
        with urllib.request.urlopen(u, timeout=15) as r:
            return json.loads(r.read().decode("utf-8"))

    def test(self):
        try:
            j = self.get_json("/api/photos")
            self.data = j.get("photos", [])
            self.status.set(f"Connected: {len(self.data)} photos available.")
            self.write(f"Connected successfully — {len(self.data)} photos available.")
        except Exception as e:
            self.status.set("Connection failed.")
            messagebox.showerror(APP_NAME, str(e))

    def manifest_path(self):
        return os.path.join(self.folder.get(), MANIFEST)

    def load_manifest(self):
        try:
            with open(self.manifest_path(), "r", encoding="utf-8") as f:
                return json.load(f)
        except Exception:
            return {"photos": {}, "last_backup": None}

    def save_manifest(self, m):
        os.makedirs(self.folder.get(), exist_ok=True)
        tmp = self.manifest_path() + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(m, f, indent=2, ensure_ascii=False)
        os.replace(tmp, self.manifest_path())

    def safe_name(self, name):
        name = "".join(c if c.isalnum() or c in " ._-()" else "_" for c in (name or "memory"))
        return name.strip()[:120] or "memory"

    def download(self, photo):
        pid = str(photo.get("id", ""))
        name = self.safe_name(photo.get("name") or "memory")
        if not os.path.splitext(name)[1]:
            name += ".jpg"
        target = os.path.join(self.folder.get(), name)
        if os.path.exists(target):
            base, ext = os.path.splitext(name)
            target = os.path.join(self.folder.get(), f"{base}_{pid[-6:]}{ext}")
        u = self.base() + "download/" + urllib.parse.quote(pid, safe="") 
        with urllib.request.urlopen(u, timeout=120) as r, open(target, "wb") as f:
            while True:
                b = r.read(1024 * 256)
                if not b: break
                f.write(b)
        return target

    def backup(self, full=False):
        try:
            self.test()
            os.makedirs(self.folder.get(), exist_ok=True)
            manifest = self.load_manifest()
            old = manifest.get("photos", {})
            todo = self.data if full else [p for p in self.data if str(p.get("id")) not in old]
            if not todo:
                self.status.set("Already up to date — no new photos.")
                self.write("No new photos. Backup is already up to date.")
                return
            self.progress.set(0)
            for i, p in enumerate(todo, 1):
                try:
                    path = self.download(p)
                    old[str(p.get("id"))] = {"name": p.get("name"), "caption": p.get("caption"), "path": path}
                    self.write(f"[{i}/{len(todo)}] {os.path.basename(path)}")
                    self.progress.set(i * 100 / len(todo))
                    self.update_idletasks()
                except Exception as e:
                    self.write(f"FAILED {p.get('name')}: {e}")
            from datetime import datetime
            manifest["photos"] = old
            manifest["last_backup"] = datetime.now().isoformat(timespec="seconds")
            self.save_manifest(manifest)
            self.status.set(f"Backup complete: {len(todo)} photo(s) processed.")
            messagebox.showinfo(APP_NAME, f"Backup complete.\n\nProcessed: {len(todo)}\nFolder: {self.folder.get()}")
        except Exception as e:
            messagebox.showerror(APP_NAME, str(e))

    def write(self, text):
        self.log.configure(state="normal")
        self.log.insert("end", text + "\n")
        self.log.see("end")
        self.log.configure(state="disabled")

if __name__ == "__main__":
    Companion().mainloop()
