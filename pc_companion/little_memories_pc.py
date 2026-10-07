import hashlib
import json
import os
import socket
import threading
import sys
import urllib.parse
import urllib.request
import tkinter as tk
import winreg
from datetime import datetime
from tkinter import filedialog, messagebox, ttk

APP_NAME = "Little Memories PC Companion"
MANIFEST = ".little_memories_backup.json"
PAIRING = ".little_memories_pairing.json"
SETTINGS = ".little_memories_settings.json"


class Companion(tk.Tk):
    def __init__(self):
        super().__init__()
        self.title(APP_NAME)
        self.geometry("820x650")
        self.minsize(720, 560)

        self.url = tk.StringVar()
        self.paired = tk.BooleanVar(value=False)
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
        self.discovery_job = None
        self.discovery_running = False
        self.discovery_watch = tk.BooleanVar(value=False)
        self.auto_backup_on_connect = tk.BooleanVar(value=False)
        self.start_with_windows = tk.BooleanVar(value=False)

        self.load_settings()

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
        row2 = ttk.Frame(box)
        row2.pack(fill="x")
        ttk.Button(row2, text="Test connection", command=self.test).pack(side="left")
        ttk.Button(row2, text="Reconnect paired phone", command=self.reconnect_paired).pack(side="left", padx=8)
        ttk.Button(row2, text="Find phone automatically", command=self.discover_phone).pack(side="left", padx=8)
        ttk.Checkbutton(row2, text="Keep watching", variable=self.discovery_watch, command=self.toggle_discovery_watch).pack(side="left", padx=8)

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
        interval_box = ttk.Combobox(
            auto_row,
            textvariable=self.interval_minutes,
            values=(5, 15, 30, 60),
            width=6,
            state="readonly",
        )
        interval_box.pack(side="left")
        interval_box.bind("<<ComboboxSelected>>", lambda _e: self.save_settings())
        ttk.Label(auto_row, text="minutes").pack(side="left", padx=(6, 0))
        ttk.Checkbutton(auto_row, text="Backup immediately when phone is discovered", variable=self.auto_backup_on_connect, command=self.save_settings).pack(side="left", padx=(18, 0))
        ttk.Checkbutton(auto_row, text="Start with Windows", variable=self.start_with_windows, command=self.toggle_startup).pack(side="left", padx=(18, 0))

        ttk.Progressbar(root, variable=self.progress, maximum=100).pack(fill="x", pady=8)
        ttk.Label(root, textvariable=self.status, wraplength=760).pack(anchor="w")

        logbox = ttk.LabelFrame(root, text="Backup log", padding=8)
        logbox.pack(fill="both", expand=True, pady=(14, 0))
        self.log = tk.Text(logbox, height=12, state="disabled", font=("Consolas", 9))
        self.log.pack(fill="both", expand=True)

        self.protocol("WM_DELETE_WINDOW", self.close_app)

    def settings_path(self):
        root = os.environ.get("APPDATA") or os.path.expanduser("~")
        return os.path.join(root, "Little Memories", SETTINGS)

    def load_settings(self):
        try:
            with open(self.settings_path(), "r", encoding="utf-8") as f:
                s = json.load(f)
            self.folder.set(s.get("folder", self.folder.get()))
            self.auto_enabled.set(bool(s.get("auto_enabled", False)))
            self.interval_minutes.set(int(s.get("interval_minutes", 15)))
            self.discovery_watch.set(bool(s.get("discovery_watch", False)))
            self.auto_backup_on_connect.set(bool(s.get("auto_backup_on_connect", False)))
            self.start_with_windows.set(bool(s.get("start_with_windows", False)))
        except Exception:
            pass

    def save_settings(self):
        try:
            folder = self.folder.get().strip()
            if not folder:
                return
            os.makedirs(os.path.dirname(self.settings_path()), exist_ok=True)
            with open(self.settings_path(), "w", encoding="utf-8") as f:
                json.dump({
                    "folder": folder,
                    "auto_enabled": self.auto_enabled.get(),
                    "interval_minutes": self.interval_minutes.get(),
                    "discovery_watch": self.discovery_watch.get(),
                    "auto_backup_on_connect": self.auto_backup_on_connect.get(),
                    "start_with_windows": self.start_with_windows.get(),
                }, f, indent=2)
        except Exception as e:
            self.write(f"Could not save settings: {e}")

    def toggle_startup(self):
        try:
            key_path = r"Software\Microsoft\Windows\CurrentVersion\Run"
            with winreg.OpenKey(winreg.HKEY_CURRENT_USER, key_path, 0, winreg.KEY_SET_VALUE) as key:
                if self.start_with_windows.get():
                    command = sys.executable if getattr(sys, "frozen", False) else os.path.abspath(__file__)
                    winreg.SetValueEx(key, "Little Memories PC Companion", 0, winreg.REG_SZ, f'"{command}"')
                    self.write("Start with Windows enabled.")
                else:
                    try:
                        winreg.DeleteValue(key, "Little Memories PC Companion")
                    except FileNotFoundError:
                        pass
                    self.write("Start with Windows disabled.")
            self.save_settings()
        except Exception as e:
            self.start_with_windows.set(False)
            self.write(f"Could not change Windows startup setting: {e}")

    def choose(self):
        p = filedialog.askdirectory(initialdir=self.folder.get())
        if p:
            self.folder.set(p)
            self.save_settings()

    def pairing_path(self):
        return os.path.join(self.folder.get(), PAIRING)

    def save_pairing(self):
        try:
            u = self.url.get().strip()
            parsed = urllib.parse.urlparse(u)
            params = urllib.parse.parse_qs(parsed.query)
            pair = params.get("pair", [None])[0]
            if not pair:
                return
            base = f"{parsed.scheme}://{parsed.netloc}/"
            os.makedirs(self.folder.get(), exist_ok=True)
            with open(self.pairing_path(), "w", encoding="utf-8") as f:
                json.dump({"base_url": base, "pair": pair}, f, indent=2)
            self.paired.set(True)
            self.write("Trusted phone pairing saved on this PC.")
        except Exception as e:
            self.write(f"Could not save pairing: {e}")

    def load_pairing(self):
        try:
            with open(self.pairing_path(), "r", encoding="utf-8") as f:
                return json.load(f)
        except Exception:
            return None

    def reconnect_paired(self):
        pair = self.load_pairing()
        if not pair:
            messagebox.showinfo(APP_NAME, "No trusted phone is saved yet. Connect once using the phone QR address.")
            return
        self.url.set(pair.get("base_url", "") + "?pair=" + urllib.parse.quote(pair.get("pair", ""), safe=""))
        if self.test():
            self.write("Trusted phone reconnected without scanning a new QR code.")

    def toggle_discovery_watch(self):
        if self.discovery_watch.get():
            self.write("Continuous phone discovery enabled — checking every 10 seconds.")
            self.save_settings()
            self.schedule_discovery()
        else:
            if self.discovery_job:
                try:
                    self.after_cancel(self.discovery_job)
                except tk.TclError:
                    pass
                self.discovery_job = None
            self.write("Continuous phone discovery disabled.")
            self.save_settings()

    def schedule_discovery(self):
        if self.discovery_job:
            try:
                self.after_cancel(self.discovery_job)
            except tk.TclError:
                pass
        if self.discovery_watch.get():
            self.discovery_job = self.after(10000, self.run_discovery_watch)

    def run_discovery_watch(self):
        self.discovery_job = None
        if not self.discovery_watch.get() or self.discovery_running or self.busy:
            self.schedule_discovery()
            return
        pair = self.load_pairing()
        if not pair or not pair.get("pair"):
            self.schedule_discovery()
            return
        self.discovery_running = True
        threading.Thread(target=self._discover_worker, args=(pair["pair"], True), daemon=True).start()

    def discover_phone(self):
        pair = self.load_pairing()
        if not pair or not pair.get("pair"):
            messagebox.showinfo(APP_NAME, "Pair this PC with the phone once first. After that, automatic discovery can find it even when its IP changes.")
            return
        if self.busy:
            return
        self.status.set("Searching the local Wi-Fi network for Little Memories…")
        self.write("Automatic discovery started.")
        threading.Thread(target=self._discover_worker, args=(pair["pair"], False), daemon=True).start()

    def _discover_worker(self, pair, silent=False):
        sock = None
        try:
            sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
            sock.settimeout(1.2)
            sock.bind(("0.0.0.0", 0))
            message = ("LITTLE_MEMORIES_DISCOVER_V1|" + pair).encode("utf-8")
            sock.sendto(message, ("255.255.255.255", 47833))
            found = None
            while True:
                try:
                    data, addr = sock.recvfrom(4096)
                except socket.timeout:
                    break
                try:
                    item = json.loads(data.decode("utf-8"))
                except Exception:
                    continue
                if item.get("service") == "Little Memories" and item.get("pair") == pair:
                    found = (addr[0], int(item.get("port", 0)))
                    break
            if not found:
                self.after(0, lambda: self._discovery_done(None, silent))
                return
            ip, port = found
            self.after(0, lambda: self._discovery_done((ip, port, pair), silent))
        except Exception as e:
            self.after(0, lambda: self._discovery_error(str(e), silent))
        finally:
            if sock:
                try:
                    sock.close()
                except OSError:
                    pass

    def _discovery_done(self, found, silent=False):
        self.discovery_running = False
        if self.discovery_watch.get():
            self.schedule_discovery()
        if not found:
            if not silent:
                self.status.set("Phone not found on this Wi-Fi network.")
                self.write("Automatic discovery found no Little Memories phone.")
                messagebox.showinfo(APP_NAME, "Phone not found. Make sure Little Memories → Connect to Windows PC is open and both devices are on the same Wi-Fi.")
            return
        ip, port, pair = found
        self.url.set(f"http://{ip}:{port}/?pair={urllib.parse.quote(pair, safe='')}")
        self.write(f"Phone discovered automatically at {ip}:{port}.")
        if self.test(quiet=silent) and silent and self.auto_backup_on_connect.get():
            self.write("Phone connected — automatic backup starting now.")
            self.after(100, lambda: self.backup(automatic=True))

    def _discovery_error(self, error, silent=False):
        self.discovery_running = False
        if self.discovery_watch.get():
            self.schedule_discovery()
        self.status.set("Automatic discovery failed.")
        self.write("DISCOVERY ERROR: " + error)
        if not silent:
            messagebox.showerror(APP_NAME, "Automatic discovery failed: " + error)

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
            self.save_pairing()
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
            self.save_settings()
            self.schedule_auto()
        else:
            if self.auto_job:
                self.after_cancel(self.auto_job)
                self.auto_job = None
            self.write("Automatic backup disabled.")
            self.save_settings()

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
        self.save_settings()
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
