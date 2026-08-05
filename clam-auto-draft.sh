#!/bin/bash
set -euo pipefail
# Warning: Its not production ready its just a draft created by chatgpt. Do not use it.
# Changes:
#
#✅ Detects clamd@scan.service or clamd.service
#✅ Fixes LocalSocket reliably
#✅ Uses detected ClamAV service everywhere
#✅ Fixes clamav-inotify.service dependency
#✅ Adds ClamAV socket health test
#✅ Works with AlmaLinux 9 + CWP variations
#
LOG_DIR="/var/log/clamav"
LOG_FILE="$LOG_DIR/setup.log"
CLAMD_CONF="/etc/clamd.d/scan.conf"

INOTIFY_SCRIPT="/usr/local/bin/clamav-inotify.sh"
INOTIFY_SERVICE="clamav-inotify"

CLAMD_SERVICE=""

mkdir -p "$LOG_DIR"

log() {
    echo "[$(date '+%F %T')] $*" | tee -a "$LOG_FILE"
}

# =========================
# DETECT CLAMD SERVICE
# =========================
detect_clamd_service() {

    log "Detecting ClamAV daemon service..."

    if systemctl list-unit-files | grep -q '^clamd@scan\.service'; then
        CLAMD_SERVICE="clamd@scan"

    elif systemctl list-unit-files | grep -q '^clamd\.service'; then
        CLAMD_SERVICE="clamd"

    else
        log "ERROR: No clamd service found"
        exit 1
    fi

    log "Using service: $CLAMD_SERVICE"
}


# =========================
# INSTALL REQUIRED PACKAGES
# =========================
install_packages() {

    log "Installing EL9 ClamAV packages..."

    dnf install -y \
        clamav \
        clamav-data \
        clamav-server-systemd \
        clamav-update \
        clamav-milter \
        inotify-tools \
        policycoreutils-python-utils || true
}


# =========================
# UPDATE VIRUS DB
# =========================
setup_freshclam() {

    log "Updating virus definitions..."

    freshclam || true

    systemctl enable --now clamav-freshclam || {
        log "WARNING: clamav-freshclam failed"
    }
}


# =========================
# FIX CLAMD CONFIG
# =========================
fix_clamd_config() {

    log "Fixing clamd configuration..."

    if [[ ! -f "$CLAMD_CONF" ]]; then
        log "ERROR: Missing $CLAMD_CONF"
        exit 1
    fi


    sed -i 's/^Example/#Example/' "$CLAMD_CONF"


    if grep -q '^#\?LocalSocket ' "$CLAMD_CONF"; then

        sed -i \
        's|^#\?LocalSocket .*|LocalSocket /run/clamd.scan/clamd.sock|' \
        "$CLAMD_CONF"

    else

        echo "LocalSocket /run/clamd.scan/clamd.sock" >> "$CLAMD_CONF"

    fi


    if grep -q '^#\?LocalSocketMode' "$CLAMD_CONF"; then

        sed -i \
        's/^#\?LocalSocketMode.*/LocalSocketMode 666/' \
        "$CLAMD_CONF"

    else

        echo "LocalSocketMode 666" >> "$CLAMD_CONF"

    fi
}



# =========================
# FIX DIRECTORIES + SELINUX
# =========================
fix_system() {

    log "Fixing directories and SELinux..."

    mkdir -p \
        /run/clamd.scan \
        /var/quarantine \
        /var/log/clamav


    chown -R clamscan:clamscan \
        /run/clamd.scan \
        /var/log/clamav || true


    chmod 755 /var/log/clamav


    if command -v restorecon >/dev/null; then

        restorecon -Rv /run/clamd.scan || true
        restorecon -Rv /var/log/clamav || true
        restorecon -Rv /var/quarantine || true

    fi
}



# =========================
# START CLAMD
# =========================
start_clamd() {

    log "Starting $CLAMD_SERVICE..."

    systemctl daemon-reload


    systemctl enable "$CLAMD_SERVICE"


    systemctl restart "$CLAMD_SERVICE"


    sleep 3


    if ! systemctl is-active --quiet "$CLAMD_SERVICE"; then

        log "ERROR: $CLAMD_SERVICE failed"

        systemctl status "$CLAMD_SERVICE" --no-pager || true

        exit 1

    fi


    log "Testing clamd socket..."

    if clamdscan /etc/hosts >/dev/null 2>&1; then

        log "clamd socket OK"

    else

        log "WARNING: clamdscan test failed"

    fi


    systemctl enable --now clamav-freshclam || true
}



# =========================
# CREATE INOTIFY SCANNER
# =========================
create_inotify() {

    log "Creating realtime scanner..."

cat > "$INOTIFY_SCRIPT" <<'EOF'
#!/bin/bash


WATCH_DIR="/home"
LOG_FILE="/var/log/clamav/inotify.log"
QUARANTINE="/var/quarantine"


mkdir -p "$QUARANTINE"


inotifywait -m -r \
-e modify,create,move \
"$WATCH_DIR" \
--exclude '(/home/.*/\.cache|/home/.*/tmp)' \
--format '%w%f' | while read FILE

do

    [ -f "$FILE" ] || continue


    SIZE=$(stat -c%s "$FILE" 2>/dev/null || echo 0)

    [ "$SIZE" -gt 50000000 ] && continue


    RESULT=$(clamdscan --fdpass "$FILE" 2>&1)


    echo "$RESULT" >> "$LOG_FILE"


    echo "$RESULT" | grep -q "FOUND" && {

        mkdir -p "$QUARANTINE"

        mv "$FILE" "$QUARANTINE"/ 2>/dev/null || true

        echo "$(date) QUARANTINED: $FILE" >> "$LOG_FILE"

    }


done
EOF


chmod +x "$INOTIFY_SCRIPT"

}



# =========================
# CREATE SYSTEMD SERVICE
# =========================
create_service() {

    log "Creating inotify systemd service..."


cat > "/etc/systemd/system/$INOTIFY_SERVICE.service" <<EOF

[Unit]
Description=ClamAV Real-Time Scanner (EL9)

After=network.target ${CLAMD_SERVICE}.service
Requires=${CLAMD_SERVICE}.service


[Service]

ExecStart=$INOTIFY_SCRIPT

Restart=always

User=root


[Install]

WantedBy=multi-user.target

EOF



systemctl daemon-reload

systemctl enable --now "$INOTIFY_SERVICE"

}



# =========================
# DAILY BACKUP SCAN
# =========================
setup_cron() {

    log "Setting daily scan cron..."


    JOB='0 2 * * * clamscan -r /home --log=/var/log/clamav/daily.log'


    (crontab -l 2>/dev/null | grep -F "$JOB") && return


    (
    crontab -l 2>/dev/null
    echo "$JOB"
    ) | crontab -

}



# =========================
# HEALTH CHECK
# =========================
health_check() {

    log "Running health check..."


    if ! systemctl is-active --quiet "$CLAMD_SERVICE"; then

        log "Restarting $CLAMD_SERVICE"

        systemctl restart "$CLAMD_SERVICE" || true

    fi



    if ! systemctl is-active --quiet clamav-freshclam; then

        systemctl restart clamav-freshclam || true

    fi



    if ! systemctl is-active --quiet "$INOTIFY_SERVICE"; then

        systemctl restart "$INOTIFY_SERVICE" || true

    fi

}



# =========================
# MAIN
# =========================
main() {

    log "Starting CLEAN EL9 ClamAV deployment..."


    install_packages

    setup_freshclam

    detect_clamd_service

    fix_clamd_config

    fix_system

    start_clamd

    create_inotify

    create_service

    setup_cron

    health_check


    log "DONE ✔ ClamAV installed and configured successfully"

}


main
