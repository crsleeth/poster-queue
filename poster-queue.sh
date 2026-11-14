#!/usr/bin/env bash
# poster-queue.sh - process poster print requests from OneDrive and print approved jobs.
#
# OneDrive layout ($REMOTE):
#   incoming/  N.pdf + N.json from Power Automate (JSON is written last = job complete)
#   review/    one folder per job: poster.pdf, preview.png, summary.txt, request.json
#   approved/  move a job folder here to print it
#   printed/   the script moves jobs here after sending them to the printer
#   rejected/  move a job folder here to discard it (the script ignores this folder)
#
# Each run: (1) turn every complete incoming job into a review folder,
#           (2) send every folder in approved/ to the printer, then move it to printed/.
# Cron:  */5 * * * * /opt/poster-queue/poster-queue.sh
#
# Settings can be overridden in /etc/poster-queue.conf (plain KEY=value lines).
set -euo pipefail

CONF=${POSTERQ_CONF:-/etc/poster-queue.conf}
[[ -r $CONF ]] && source "$CONF"

: "${REMOTE:=onedrive:Posters}"            # rclone remote:path to the Posters folder
: "${PRINTER:=}"                         # Z6 hostname or IP (raw port 9100)
: "${WORKDIR:=/var/lib/poster-queue}"    # temp files, log, lock, sent list
: "${ROLL_IN:=36}"                       # loaded roll width
: "${PRINTABLE_IN:=35.6}"                # max across-roll image width (roll minus margins)
: "${MIN_LEAD_DAYS:=2}"                  # business days of notice before flagging
: "${ALERT_TO:=}"                        # email for failures (needs a working `mail`)
: "${DRY_RUN:=0}"                        # 1 = build the print stream but don't send it
HERE=$(dirname "$(readlink -f "$0")")
: "${PYTHON:=$([[ -x $HERE/venv/bin/python3 ]] && echo "$HERE/venv/bin/python3" || echo python3)}"

LOG=$WORKDIR/poster-queue.log
SENT=$WORKDIR/sent.list                  # jobs already sent, so a failed move never reprints

mkdir -p "$WORKDIR"
touch "$SENT"

log() { printf '%s %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG" >&2; }

# Email an alert, at most once per 6 hours per key, so a broken token doesn't spam every run.
alert() {
    local key=$1; shift
    log "ALERT [$key]: $*"
    [[ -n $ALERT_TO ]] || return 0
    local stamp=$WORKDIR/alert.$key
    if [[ -f $stamp ]] && (( $(date +%s) - $(stat -c %Y "$stamp") < 21600 )); then
        return 0
    fi
    touch "$stamp"
    printf '%s\n\nLog: %s\n' "$*" "$LOG" | mail -s "poster-queue: $key" "$ALERT_TO" \
        || log "could not send alert mail"
}

# Weekdays strictly after today up to and including $1 (YYYY-MM-DD). -1 if already past.
business_days_until() {
    local due=$1 d n=0 today
    today=$(date +%F)
    [[ $due < $today ]] && { echo -1; return; }
    d=$(date -d "$today +1 day" +%F)
    while [[ ! $d > $due ]]; do
        if (( $(date -d "$d" +%u) <= 5 )); then n=$((n + 1)); fi
        d=$(date -d "$d +1 day" +%F)
    done
    echo "$n"
}

safe() { tr -cd 'A-Za-z0-9-' | cut -c1-20; }

# ---------------------------------------------------------------- incoming -> review
process_job() {
    local id=$1 t out plan ok=1 err=""
    t=$(mktemp -d "$WORKDIR/job.XXXXXX")
    out=$t/out
    mkdir -p "$out"

    if ! rclone copyto "$REMOTE/incoming/$id.json" "$out/request.json" 2>>"$LOG"; then
        rm -rf "$t"; log "could not download incoming/$id.json; will retry"; return 1
    fi
    if ! rclone copyto "$REMOTE/incoming/$id.pdf" "$t/original.pdf" 2>>"$LOG"; then
        ok=0; err="PDF $id.pdf missing from incoming/"
    fi

    local req=$out/request.json
    local email pi due submitted orig size_text rw rh
    email=$(jq -r '.email // ""' "$req")
    pi=$(jq -r '.pi // ""' "$req")
    due=$(jq -r '.due // ""' "$req")
    submitted=$(jq -r '.submitted // ""' "$req")
    orig=$(jq -r '.orig_name // ""' "$req")
    size_text=$(jq -r '.size_mode // ""' "$req")
    rw=$(jq -r '.width_in // ""' "$req")
    rh=$(jq -r '.height_in // ""' "$req")
    # Forms reports submission time in UTC
    submitted=$(date -d "$submitted UTC" '+%F %R' 2>/dev/null || echo "$submitted")

    if (( ok )); then
        if plan=$("$PYTHON" "$HERE/posterfit.py" "$t/original.pdf" "$req" "$out/poster.pdf" \
                    --roll "$ROLL_IN" --printable "$PRINTABLE_IN" 2>>"$LOG"); then
            :
        else
            ok=0
            err=$(jq -r '.error // empty' <<<"$plan" 2>/dev/null || true)
            err=${err:-"posterfit crashed; see log"}
        fi
    fi

    # Flags from the PDF plan plus due-date checks
    local -a flags=() notes=()
    if (( ok )); then
        mapfile -t flags < <(jq -r '.flags[]' <<<"$plan")
        mapfile -t notes < <(jq -r '.notes[]' <<<"$plan")
    fi
    local bdays="?"
    if [[ $due =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
        bdays=$(business_days_until "$due")
        if (( bdays < 0 )); then flags+=("PAST DUE: requested by $due")
        elif (( bdays < MIN_LEAD_DAYS )); then flags+=("SHORT NOTICE: $bdays business day(s) before $due")
        fi
    else
        flags+=("Due date unreadable: '$due'")
    fi

    # Folder name: readable on a phone, sorts by job number, marks jobs needing a look.
    local name
    name=$(printf '%04d' "$id")_$(safe <<<"${email%%@*}")_$(safe <<<"$pi")
    if (( ok )); then
        local fw fh
        fw=$(jq -r '.final_w' <<<"$plan"); fh=$(jq -r '.final_h' <<<"$plan")
        name+=_$(awk -v w="$fw" -v h="$fh" 'BEGIN { printf "%gx%g", int(w*10+.5)/10, int(h*10+.5)/10 }')
        [[ $due =~ ^[0-9]{4}-([0-9]{2})-([0-9]{2})$ ]] && name+=_due-${BASH_REMATCH[1]}${BASH_REMATCH[2]}
        (( ${#flags[@]} )) && name+=_CHECK
        pdftoppm -png -scale-to 1000 -singlefile "$out/poster.pdf" "$out/preview" 2>>"$LOG" \
            || flags+=("Preview could not be rendered")
    else
        name+=_ERROR
        [[ -f $t/original.pdf ]] && cp "$t/original.pdf" "$out/original.pdf"
    fi

    # Human-readable summary
    {
        echo "Poster job $id"
        echo
        printf '%-11s %s (%s)\n' "Submitted:" "$submitted" "$email"
        printf '%-11s %s\n' "PI / lab:" "$pi"
        printf '%-11s %s (%s business days away)\n' "Due:" "$due" "$bdays"
        printf '%-11s %s\n' "File:" "$orig"
        printf '%-11s %s%s\n' "Request:" "$size_text" "${rw:+ -> $rw x $rh in}"
        if (( ok )); then
            jq -r '
              "PDF size:   \(.orig_w) x \(.orig_h) in",
              "Prints at:  \(.final_w) x \(.final_h) in as it hangs (\(.scale_pct)%)",
              "On roll:    \(.across) in across, \(.along) in long\(if .rotated then ", rotated 90" else "" end)",
              "Paper:      ~\(((.along + 1) / 12 * 10 | round) / 10) ft of roll",
              "Images:     lowest \(if .min_ppi == null then "n/a (no large images)" else "\(.min_ppi) ppi" end)"
            ' <<<"$plan"
        else
            echo
            echo "ERROR: $err"
            echo "Nothing was generated. Handle manually (original.pdf is included if it arrived)."
        fi
        echo
        if (( ${#flags[@]} )); then
            echo "CHECK:"
            printf ' - %s\n' "${flags[@]}"
        elif (( ok )); then
            echo "No issues found."
        fi
        if (( ${#notes[@]} )); then
            echo "Notes:"
            printf ' - %s\n' "${notes[@]}"
        fi
        echo
        if (( ok )); then
            echo "To print: move this folder to approved/.  To discard: move it to rejected/."
        else
            echo "When handled: move this folder to rejected/ (approved/ cannot print an ERROR job)."
        fi
    } > "$out/summary.txt"

    # Publish first, then clear incoming (worst case on failure: a duplicate review folder).
    if ! rclone copy "$out" "$REMOTE/review/$name" 2>>"$LOG"; then
        rm -rf "$t"; log "upload of review/$name failed; job $id left in incoming/ to retry"; return 1
    fi
    rclone deletefile "$REMOTE/incoming/$id.json"
    rclone deletefile "$REMOTE/incoming/$id.pdf" 2>/dev/null || true
    rm -rf "$t"
    log "job $id -> review/$name"
    (( ok )) || alert "job$id" "Job $id could not be processed: $err"
}

# ---------------------------------------------------------------- approved -> printer
print_job() {
    local d=$1 t spool
    if grep -qxF "$d" "$SENT"; then
        log "$d already sent; retrying move to printed/"
    else
        t=$(mktemp -d "$WORKDIR/print.XXXXXX")
        if ! rclone copyto "$REMOTE/approved/$d/poster.pdf" "$t/poster.pdf" 2>>"$LOG"; then
            rm -rf "$t"
            alert "noposter-$d" "approved/$d has no poster.pdf (ERROR job?). Print it manually and move it to printed/."
            return 0
        fi
        # PJL wrapper: names the job in the printer's queue and declares the PDF language.
        spool=$t/job.prn
        {
            printf '\033%%-12345X@PJL JOB NAME="%s"\r\n@PJL ENTER LANGUAGE=PDF\r\n' "$d"
            cat "$t/poster.pdf"
            printf '\033%%-12345X@PJL EOJ NAME="%s"\r\n\033%%-12345X' "$d"
        } > "$spool"

        if (( DRY_RUN )); then
            cp "$spool" "$WORKDIR/last-dryrun.prn"
            log "DRY_RUN: would send $d ($(stat -c %s "$spool") bytes) to ${PRINTER:-<unset>}:9100"
        else
            if ! timeout 900 bash -c 'cat "$1" > "/dev/tcp/$2/9100"' _ "$spool" "$PRINTER"; then
                rm -rf "$t"
                alert "send-$d" "Could not send $d to $PRINTER:9100. It stays in approved/ and will retry."
                return 0
            fi
            log "sent $d to $PRINTER"
        fi
        echo "$d" >> "$SENT"
        rm -rf "$t"
    fi
    rclone move "$REMOTE/approved/$d" "$REMOTE/printed/$d" --delete-empty-src-dirs
    rclone rmdir "$REMOTE/approved/$d" 2>/dev/null || true
}

# ---------------------------------------------------------------- main
exec 9>"$WORKDIR/lock"
flock -n 9 || exit 0                       # previous run still going

if (( ! DRY_RUN )) && [[ -z $PRINTER ]]; then
    log "PRINTER is not set"; exit 1
fi

# One cheap call that fails fast on expired tokens / network problems.
if ! rclone mkdir "$REMOTE/incoming" 2>>"$LOG"; then
    alert rclone "rclone cannot reach $REMOTE (expired token or network?). Run: rclone config reconnect ${REMOTE%%:*}:"
    exit 1
fi
for f in review approved printed rejected; do rclone mkdir "$REMOTE/$f"; done

while IFS= read -r json; do
    id=${json%.json}
    [[ $id =~ ^[0-9]+$ ]] || { log "ignoring incoming/$json"; continue; }
    process_job "$id" || alert "job$id" "Job $id failed unexpectedly; see log"
done < <(rclone lsf "$REMOTE/incoming" --files-only --include '*.json')

while IFS= read -r d; do
    d=${d%/}
    [[ -n $d ]] && { print_job "$d" || alert "print-$d" "Printing $d failed unexpectedly; see log"; }
done < <(rclone lsf "$REMOTE/approved" --dirs-only)
