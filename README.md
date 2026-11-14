# poster-queue

Microsoft Form → Power Automate → OneDrive `Posters/incoming/` → Linux VM → HP DesignJet Z6.

| File | Purpose |
|---|---|
| `poster-queue.sh` | one-shot job: builds review folders from `incoming/`, prints folders moved to `approved/` |
| `posterfit.py` | sizing/rotation logic; writes the print-ready PDF and a JSON plan |
| `poster-queue.conf.example` | settings, installed as `/etc/poster-queue.conf` |
| `poster-queue.service` / `.timer` | systemd units that run the job every 5 minutes as the service user |

## Workflow

1. A form submission lands as `incoming/N.pdf` + `incoming/N.json`.
2. Within 5 min a folder appears in `review/`, e.g. `0001_jdoe_Smith_47.5x35.6_due-1116`, containing
   `summary.txt`, `preview.png`, `poster.pdf`, `request.json`.
   `_CHECK` = something to look at; `_ERROR` = nothing printable was made.
3. Approve: move the folder to `approved/` (OneDrive app works). Discard: move it to `rejected/`.
4. The next run sends it to the Z6 on port 9100 and moves it to `printed/`.

Sizing: specific size = fit inside requested W x H (orientation auto-matched);
as large as possible = short side 35.6 in. Prints with a short side under 18 in are flagged.
A short side between 35.6 and 36 in is shrunk ~1% for printer margins.
Output is always rotated so the short side runs across the roll.

## Setup

The job runs as an ordinary (non-root) account on the VM, called the service user below.
Set these in every shell you use for setup, on your workstation and on the VM:

```bash
SVC_USER=<service-user>     # account the job runs as, e.g. your VM's default login
VM=<vm-ip-or-hostname>
```

From your workstation, in the folder holding the files:

```bash
scp poster-queue.sh posterfit.py poster-queue.conf.example \
    poster-queue.service poster-queue.timer README.md "$SVC_USER@$VM:~/"
```

Then log in to the VM as the service user (and set `SVC_USER` there too).
Everything below is run as that user; `sudo` only where shown.

### 1. Packages and timezone

```bash
sudo apt update && sudo apt full-upgrade -y
sudo apt install -y jq poppler-utils python3-venv
sudo timedatectl set-timezone <Region/City>   # e.g. America/Chicago
```

`poppler-utils` = `pdfinfo`, `pdftoppm`, `pdfimages`. Timezone matters: due-date math and log times use local time.

### 2. rclone

```bash
sudo apt install -y rclone
rclone version
```

### 3. Install the code and work directory

```bash
sudo install -d /opt/poster-queue
sudo install -m 755 ~/poster-queue.sh ~/posterfit.py /opt/poster-queue/
sudo python3 -m venv /opt/poster-queue/venv
sudo /opt/poster-queue/venv/bin/pip install 'pypdf>=7,<8'   # pinned: major versions break APIs
/opt/poster-queue/venv/bin/python3 -c "import pypdf; print(pypdf.__version__)"

sudo install -d -o "$SVC_USER" -g "$SVC_USER" /var/lib/poster-queue
```

Code is root-owned (the service user can run it, not change it). The work dir holds the log,
lock, sent list and temp files, owned by the service user.

### 4. Config

```bash
sudo install -m 640 -o root -g "$SVC_USER" ~/poster-queue.conf.example /etc/poster-queue.conf
sudo nano /etc/poster-queue.conf
```

Set `PRINTER=` to the Z6 IP. Leave `DRY_RUN=1` for now.

### 5. rclone remote

As the service user on the VM, set up a OneDrive remote named `onedrive`
(must match `REMOTE=` in `/etc/poster-queue.conf`), then check it:

```bash
rclone config
rclone lsf onedrive:Posters        # should list incoming/
```

If the token ever expires: `rclone config reconnect onedrive:`

### 6. Printer reachable?

```bash
nc -zv <z6-ip> 9100
```

### 7. Dry run by hand

Submit a test form, wait for `N.pdf` + `N.json` in `incoming/`, then:

```bash
/opt/poster-queue/poster-queue.sh
tail /var/lib/poster-queue/poster-queue.log
```

Check the new `review/` folder in OneDrive. Move it to `approved/`, run the script again.
With `DRY_RUN=1` it saves the print stream to `/var/lib/poster-queue/last-dryrun.prn`
and moves the folder to `printed/` without printing.

### 8. One real print, by hand

```bash
cat /var/lib/poster-queue/last-dryrun.prn > /dev/tcp/<z6-ip>/9100
```

Check size, orientation, margins. Paper type and quality come from the printer's
defaults; fix them on the front panel if needed. Also set the printer to
**Hold job and continue with next** so a mismatched job waits instead of stopping the queue.
When it's right: set `DRY_RUN=0` in `/etc/poster-queue.conf`.

### 9. Schedule it (systemd timer)

```bash
sed "s/<service-user>/$SVC_USER/g" ~/poster-queue.service \
  | sudo tee /etc/systemd/system/poster-queue.service >/dev/null
sudo install -m 644 ~/poster-queue.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now poster-queue.timer

systemctl list-timers poster-queue.timer      # last / next run
systemctl status poster-queue.service         # result of last run
journalctl -u poster-queue.service -f         # live output
```

Runs never overlap (`Type=oneshot` + the script's own lock).

### 10. Log rotation

```bash
sudo tee /etc/logrotate.d/poster-queue >/dev/null <<EOF
/var/lib/poster-queue/poster-queue.log {
    monthly
    rotate 12
    compress
    missingok
    notifempty
    su $SVC_USER $SVC_USER
}
EOF
```

### 11. Optional: email alerts via an SMTP relay

```bash
sudo apt install -y msmtp-mta bsd-mailx
sudo tee /etc/msmtprc >/dev/null <<EOF
defaults
account default
host <smtp-relay>
port 25
from $SVC_USER@<vm-fqdn>
EOF
echo test | mail -s "poster-queue test" you@example.edu
```

Add TLS lines if the relay needs them. Then set `ALERT_TO="you@example.edu"` in
`/etc/poster-queue.conf`. Alerts (rclone auth lost, unprocessable job, printer unreachable)
are sent at most once per 6 h per issue.

## Day to day

| What | Where |
|---|---|
| Settings | `/etc/poster-queue.conf` |
| Code | `/opt/poster-queue/` |
| Log | `/var/lib/poster-queue/poster-queue.log` and `journalctl -u poster-queue` |
| Jobs already sent | `/var/lib/poster-queue/sent.list` |
| Pause processing | `sudo systemctl stop poster-queue.timer` |
| Update code | rerun the two `install` lines in step 3 (venv untouched) |

## Notes / limits

- The PJL header + PDF over port 9100 is standard for HP PostScript/PDF printers, but prove
  it with step 8 before trusting it.
- `sent.list` prevents a reprint if moving a job to `printed/` fails; the move is just retried.
- If the form's size-option wording changes, update `size_mode()` in `posterfit.py`.
