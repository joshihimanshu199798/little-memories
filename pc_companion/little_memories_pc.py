import hashlib
import json
import os
import threading
import urllib.parse
import urllib.request
import tkinter as tk
from datetime import datetime
from tkinter import filedialog, messagebox, ttk

APP_NAME = "Little Memories PC Companion"
MANIFEST = ".little_memories_backup.json"


class Companion(tk.Tk):
    def __init__(self):
        super().__init__()
        self.title(APP_NAME)
        self.geometry("820x650")
        self.minsize(720, 560)

        self.url = tk.StringVar()
        self.folder = tk.StringVar(
            value=os.path.join(os.path.expanduser("~"), "Pictures", "Little Memories")
        )
        self.status = tk.StringVar(value="Connect your phone and paste the QR/browser URL.")
        self.progress = tk.DoubleVar()
        self.auto_enabled = tk.BooleanVar(value=False)
        self.interval_minutes = tk.IntVar(value=15)

        self.data = []
        self.busy = False
        self.auto_job = None

        root = ttk.Frame(self, padding=20)
        root.pack(fill="both", expand=True)

        ttk.Label(root, text=APP_NAME, font=("Segoe UI", 22, "bold")).pack(anchor="w")
        ttk.Label(
            root,
            text="Automatic local backup • duplicate detection • SHA-256 verification • no cloud",
            font=("Segoe UI", 10),
        ).pack(anchor="w", pady=(0, 18))

        box = ttk.LabelFrame(root, text="1. Phone connection", padding=14)
        box.pack(fill="x")
        ttk.Label(
            box,
            text="Paste the address shown in Little Memories → Connect to Windows PC:",
        ).pack(anchor="w")
        ttk.Entry(box, textvariable=self.url).pack(fill="x", pady=8)
        ttk.Button(box, text="Test connection", command=self.test).pack(anchor="e")

        dest = ttk.LabelFrame(root, text="2. Backup folder", padding=14)
        dest.pack(fill="x", pady=12)
        row = ttk.Frame(dest)
        row.pack(fill="x")
        ttk.Entry(row, textvariable=self.folder).pack(side="left", fill="x", expand=True)
        ttk.Button(row, text="Choose…", command=self.choose).pack(side="left", padx=(8, 0))

        actions = ttk.Frame(root)
        actions.pack(fill="x", pady=8)
        ttk.Button(actions, text="Backup new photos", command=self.backup).pack(side="left")
        ttk.Button(
            actions, text="Full backup + verify", command=lambda: self.backup(full=True)
        ).pack(side="left", padx=8)
        ttk.Button(actions, text="Verify existing backup", command=self.verify_existing).pack(
            side="left"
        )

        auto = ttk.LabelFrame(root, text="3. Automatic backup", padding=14)
        auto.pack(fill="x", pady=(4, 10))
        auto_row = ttk.Frame(auto)
        auto_row.pack(fill="x")
        ttk.Checkbutton(
            auto_row,
            text="Automatically check for new photos",
            variable=self.auto_enabled,
            command=self.toggle_auto,
        ).pack(side="left")
        ttk.Label(auto_row, text="Every").pack(side="left", padx=(18, 6))
        ttk.Combobox(
            auto_row,
            textvariable=self.interval_minutes,
            values=(5, 15, 30, 60),
            width=6,
            state="readonly",
        ).pack(side="left")
        ttk.Label(auto_row, text="minutes").pack(side="left", padx=(6, 0))

        ttk.Progressbar(root, variable=self.progress, maximum=100).pack(fill="x", pady=8)
        ttk.Label(root, textvariable=self.status, wraplength=760).pack(anchor="w")

        logbox = ttk.LabelFrame(root, text="Backup log", padding=8)
        logbox.pack(fill="both", expand=True, pady=(14, 0))
        self.log = tk.Text(logbox, height=12, state="disabled", font=("Consolas", 9))
        self.log.pack(fill="both", expand=True)

        self.protocol("WM_DELETE_WINDOW", self.close_app)

    def choose(self):
        p = filedialog.askdirectory(initialdir=self.folder.get())
        if p:
            self.folder.set(p)

    def base(self):
        u = self.url.get().strip()
        if not u.startswith("http://") and not u.startswith("https://"):
            raise ValueError("Paste the complete address from the phone, including http://")
        return u.rstrip("/") + "/"

    def get_json(self, path):
        u = self.base() + path.lstrip("/")
        with urllib.request.urlopen(u, timeout=15) as r:
            return json.loads(r.read().decode("utf-8"))

    def test(self, quiet=False):
        try:
            j = self.get_json("/api/photos")
            self.data = j.get("photos", [])
            self.status.set(f"Connected: {len(self.data)} photos available.")
            self.write(f"Connected successfully — {len(self.data)} photos available.")
            return True
        except Exception as e:
            self.status.set("Connection failed.")
            if not quiet:
                messagebox.showerror(APP_NAME, str(e))
            return False

    def manifest_path(self):
        return os.path.join(self.folder.get(), MANIFEST)

    def load_manifest(self):
        try:
            with open(self.manifest_path(), "r", encoding="utf-8") as f:
                data = json.load(f)
                data.setdefault("photos", {})
                data.setdefault("last_backup", None)
                return data
        except Exception:
            return {"photos": {}, "last_backup": None}

    def save_manifest(self, manifest):
        os.makedirs(self.folder.get(), exist_ok=True)
        tmp = self.manifest_path() + ".tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(manifest, f, indent=2, ensure_ascii=False)
        os.replace(tmp, self.manifest_path())

    def safe_name(self, name):
        name = "".join(
            c if c.isalnum() or c in " ._-()" else "_" for c in (name or "memory")
        )
        return name.strip()[:120] or "memory"

    def sha256(self, path):
        digest = hashlib.sha256()
        with open(path, "rb") as f:
            while True:
                block = f.read(1024 * 1024)
                if not block:
                    break
                digest.update(block)
        return digest.hexdigest()

    def build_hash_index(self, manifest):
        index = {}
        for item in manifest.get("photos", {}).values():
            path = item.get("path")
            stored_hash = item.get("sha256")
            if path and stored_hash and os.path.isfile(path):
                index.setdefault(stored_hash, path)

        # Also discover files created before the hash-aware version.
        root = self.folder.get()
        if os.path.isdir(root):
            for name in os.listdir(root):
                path = os.path.join(root, name)
                if (
                    not os.path.isfile(path)
                    or name == MANIFEST
                    or name.endswith(".tmp")
                ):
                    continue
                try:
                    h = self.sha256(path)
                    index.setdefault(h, path)
                except OSError:
                    pass
        return index

    def download(self, photo):
        pid = str(photo.get("id", ""))
        name = self.safe_name(photo.get("name") or "memory")
        if not os.path.splitext(name)[1]:
            name += ".jpg"

        target = os.path.join(self.folder.get(), name)
        if os.path.exists(target):
            base, ext = os.path.splitext(name)
            target = os.path.join(self.folder.get(), f"{base}_{pid[-6:]}{ext}")

        temp = target + ".part"
        u = self.base() + "download/" + urllib.parse.quote(pid, safe="")

        try:
            with urllib.request.urlopen(u, timeout=120) as r, open(temp, "wb") as f:
                while True:
                    block = r.read(1024 * 256)
                    if not block:
                        break
                    f.write(block)
            os.replace(temp, target)
        except Exception:
            try:
                if os.path.exists(temp):
                    os.remove(temp)
            except OSError:
                pass
            raise

        return target

    def backup(self, full=False, automatic=False):
        if self.busy:
            self.write("Backup skipped: another backup is already running.")
            return

        self.busy = True
        try:
            if not self.test(quiet=automatic):
                return

            os.makedirs(self.folder.get(), exist_ok=True)
            manifest = self.load_manifest()
            old = manifest.get("photos", {})

            if full:
                todo = list(self.data)
            else:
                todo = []
                for p in self.data:
                    pid = str(p.get("id"))
                    entry = old.get(pid)
                    if not entry:
                        todo.append(p)
                        continue
                    path = entry.get("path")
                    stored_hash = entry.get("sha256")
                    if not path or not os.path.isfile(path):
                        todo.append(p)
                    elif stored_hash:
                        try:
                            if self.sha256(path) != stored_hash:
                                todo.append(p)
                        except OSError:
                            todo.append(p)

            if not todo:
                self.progress.set(100)
                self.status.set("Already up to date — no new or changed photos.")
                self.write("Backup is already up to date.")
                return

            hash_index = self.build_hash_index(manifest)
            processed = 0
            verified = 0
            duplicates = 0
            failed = 0

            self.progress.set(0)

            for i, photo in enumerate(todo, 1):
                try:
                    pid = str(photo.get("id"))
                    path = self.download(photo)

                    # Verify the downloaded bytes before recording them as backed up.
                    file_hash = self.sha256(path)
                    file_size = os.path.getsize(path)

                    existing = hash_index.get(file_hash)
                    if existing and os.path.abspath(existing) != os.path.abspath(path):
                        os.remove(path)
                        final_path = existing
                        duplicates += 1
                        self.write(
                            f"[{i}/{len(todo)}] DUPLICATE — {os.path.basename(final_path)}"
                        )
                    else:
                        final_path = path
                        hash_index[file_hash] = final_path
                        verified += 1
                        self.write(
                            f"[{i}/{len(todo)}] VERIFIED — {os.path.basename(final_path)}"
                        )

                    old[pid] = {
                        "name": photo.get("name"),
                        "caption": photo.get("caption"),
                        "path": final_path,
                        "sha256": file_hash,
                        "size": file_size,
                        "verified_at": datetime.now().isoformat(timespec="seconds"),
                    }
                    processed += 1
                    self.progress.set(i * 100 / len(todo))
                    self.update_idletasks()
                except Exception as e:
                    failed += 1
                    self.write(f"FAILED {photo.get('name')}: {e}")

            manifest["photos"] = old
            manifest["last_backup"] = datetime.now().isoformat(timespec="seconds")
            self.save_manifest(manifest)

            summary = (
                f"Backup finished: {processed} processed • "
                f"{verified} verified • {duplicates} duplicates • {failed} failed."
            )
            self.status.set(summary)
            self.write(summary)

            if not automatic:
                messagebox.showinfo(
                    APP_NAME,
                    "Backup complete.\n\n"
                    f"Processed: {processed}\n"
                    f"Verified: {verified}\n"
                    f"Duplicates avoided: {duplicates}\n"
                    f"Failed: {failed}\n\n"
                    f"Folder: {self.folder.get()}",
                )
        except Exception as e:
            self.status.set("Backup failed.")
            self.write(f"BACKUP ERROR: {e}")
            if not automatic:
                messagebox.showerror(APP_NAME, str(e))
        finally:
            self.busy = False
            if self.auto_enabled.get():
                self.schedule_auto()

    def verify_existing(self):
        if self.busy:
            return
        self.busy = True
        try:
            manifest = self.load_manifest()
            photos = manifest.get("photos", {})
            checked = verified = missing = corrupt = 0

            for entry in photos.values():
                path = entry.get("path")
                expected = entry.get("sha256")
                if not path or not os.path.isfile(path):
                    missing += 1
                    continue
                checked += 1
                if expected:
                    try:
                        actual = self.sha256(path)
                        if actual == expected:
                            verified += 1
                        else:
                            corrupt += 1
                    except OSError:
                        corrupt += 1
                else:
                    # Legacy entry: calculate and upgrade its verification hash.
                    try:
                        actual = self.sha256(path)
                        entry["sha256"] = actual
                        entry["size"] = os.path.getsize(path)
                        entry["verified_at"] = datetime.now().isoformat(timespec="seconds")
                        verified += 1
                    except OSError:
                        corrupt += 1

            self.save_manifest(manifest)
            result = (
                f"Verification complete: {verified} verified, "
                f"{missing} missing, {corrupt} corrupted/changed."
            )
            self.status.set(result)
            self.write(result)
            messagebox.showinfo(APP_NAME, result)
        except Exception as e:
            messagebox.showerror(APP_NAME, str(e))
        finally:
            self.busy = False

    def toggle_auto(self):
        if self.auto_enabled.get():
            self.write(
                f"Automatic backup enabled — checking every {self.interval_minutes.get()} minutes."
            )
            self.schedule_auto()
        else:
            if self.auto_job:
                self.after_cancel(self.auto_job)
                self.auto_job = None
            self.write("Automatic backup disabled.")

    def schedule_auto(self):
        if self.auto_job:
            try:
                self.after_cancel(self.auto_job)
            except tk.TclError:
                pass
        if self.auto_enabled.get():
            delay = max(1, int(self.interval_minutes.get())) * 60 * 1000
            self.auto_job = self.after(delay, self.run_auto)

    def run_auto(self):
        self.auto_job = None
        if self.auto_enabled.get():
            self.write("Automatic backup check started.")
            self.backup(automatic=True)

    def close_app(self):
        if self.auto_job:
            try:
                self.after_cancel(self.auto_job)
            except tk.TclError:
                pass
        self.destroy()

    def write(self, text):
        self.log.configure(state="normal")
        self.log.insert("end", text + "\n")
        self.log.see("end")
        self.log.configure(state="disabled")


if __name__ == "__main__":
    Companion().mainloop()
