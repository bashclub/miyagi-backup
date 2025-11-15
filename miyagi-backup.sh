#!/bin/bash
set -uo pipefail
IFS=$'\n\t'

PATH="/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin"
SCRIPT_NAME=$(basename "$0")
LOGFILE="/var/log/${SCRIPT_NAME%.sh}.log"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOGFILE"
}

usage() {
  echo "Usage:"
  echo "  $0 -c /path/to/config                 # Full backup run"
  echo "  $0 [function]                         # Run individual function"
  echo "  $0 help                               # Show available functions"
  exit 1
}

CONFIG_FILE=""
while getopts "c:" opt; do
  case "$opt" in
    c) CONFIG_FILE="$OPTARG" ;;
    *) usage ;;
  esac
done
shift $((OPTIND - 1))

if [[ -n "${CONFIG_FILE:-}" ]]; then
  if [[ ! -f "$CONFIG_FILE" ]]; then
    log "ERROR: Configuration file not found: $CONFIG_FILE"
    exit 1
  fi

  if ! bash -n "$CONFIG_FILE"; then
    log "Syntax error in configuration file $CONFIG_FILE"
    exit 1
  fi

  source "$CONFIG_FILE"

  REQUIRED_VARS=(
    SOURCEPORT BACKUPSERVER ZSYNC MAINTDAY SHUTDOWN UPDATES
    SOURCEHOST ZFSROOT ZFSSECOND ZFSTRGT ZPUSHTAG ZPUSHMINKEEP ZPUSHKEEP ZPUSHLABEL
    PBSHOST BACKUPSTORE BACKUPSTOREPBS BACKUPEXCLUDE REPLEXCLUDE DYNROUTE REBOOT DDNS_GATEWAY
  )

if [[ "${DYNROUTE,,}" == "yes" ]]; then
    REQUIRED_VARS+=(DDNS_GATEWAY)
fi

  MISSING_VARS=()
  for var in "${REQUIRED_VARS[@]}"; do
    if [[ -z "${!var:-}" ]]; then
      MISSING_VARS+=("$var")
    fi
  done

  if [[ "${#MISSING_VARS[@]}" -gt 0 ]]; then
    log "Missing configuration variables:"
    for var in "${MISSING_VARS[@]}"; do
      log " - $var"
    done
    log "Aborting — please check your configuration file."
    exit 1
  else
    log "All required configuration variables are set."
  fi
fi

rssh() { ssh -p "$SOURCEPORT" "$@"; }
rscp() { scp -P "$SOURCEPORT" "$@"; }

get_sourcehostname() {
  if [[ -z "${SOURCEHOSTNAME:-}" ]]; then
    log "SOURCEHOSTNAME is empty, retrieving via SSH from $SOURCEHOST..."
    SOURCEHOSTNAME=$(rssh "$SOURCEHOST" hostname)
    log "Detected SOURCEHOSTNAME: $SOURCEHOSTNAME"
  fi
}

zfs_replace() {
   local status
  status=$(zpool status)

  if echo "$status" | grep -q 'scan: resilver in progress'; then
    return 0
  fi

  if echo "$status" | grep -qE 'replacing-[0-9]'; then
    return 0
  fi

  return 1
}

wait_replace() {
  local interval_seconds=300  # Alle 5 Minuten prüfen
  local waited_minutes=0

  log "ZFS Replace-Vorgang erkannt – warte unbegrenzt auf Abschluss..."

  while true; do
    if ! zfs_replace; then
      log "Replace abgeschlossen nach $waited_minutes Minuten – fahre jetzt herunter."
      return 0
    fi
    log "Replace läuft noch – erneut prüfen in $((interval_seconds/60)) Minuten..."
    sleep "$interval_seconds"
    ((waited_minutes+=interval_seconds/60))
  done
}

set_wol_g_enabled() {
  log "Checking if ethtool is installed..."

  if ! command -v ethtool >/dev/null 2>&1; then
    log "ethtool is not installed, attempting installation..."
    apt update && apt install -y ethtool || {
      log "Error: ethtool could not be installed."
      return 1
    }
  else
    log "ethtool is already installed."
  fi

  log "Setting Wake-on-LAN (WOL) to 'g' on interfaces with static IP..."

  for iface in $(ls /sys/class/net | grep -vE '^(lo|tap|vmbr|veth|br|docker|bond|wl)'); do
    if [[ -e "/sys/class/net/$iface/device" ]]; then
      log "Processing physical interface: $iface"

      current_wol=$(ethtool "$iface" 2>/dev/null | awk '/Wake-on:/ {print $2}')
      if [[ "$current_wol" != "g" ]]; then
        log "Setting WOL to 'g' for $iface..."
        ethtool -s "$iface" wol g || log "Error setting WOL on $iface"
      else
        log "WOL already set to 'g' for $iface"
      fi

      if grep -qE "^\s*iface\s+$iface\s+inet\s+static" /etc/network/interfaces; then
        if ! grep -A 5 -E "^\s*iface\s+$iface\s+inet\s+static" /etc/network/interfaces | grep -q "post-up ethtool -s $iface wol g"; then
          log "Adding WOL command in static block for $iface..."
          sed -i "/^\s*iface\s\+$iface\s\+inet\s\+static/a \    post-up ethtool -s $iface wol g" /etc/network/interfaces
        else
          log "WOL command already present in static block for $iface."
        fi
      else
        log "No static entry found for $iface, no changes made."
      fi
    fi
  done
}

write_zsync_config() {
  get_sourcehostname
  local conf_file="/etc/bashclub/$SOURCEHOST.conf"
  log "Writing zsync config to $conf_file"
  {
    echo "target=$ZFSTRGT"
    echo "source=root@$SOURCEHOST"
    echo "sshport=$SOURCEPORT"
    echo "tag=$ZPUSHTAG"
    echo "snapshot_filter=\"$ZPUSHFILTER\""
    echo "min_keep=$ZPUSHMINKEEP"
    echo "zfs_auto_snapshot_keep=$ZPUSHKEEP"
    echo "zfs_auto_snapshot_label=$ZPUSHLABEL"
    echo "zfs_auto_snapshot_engine=internal"
    echo "checkzfs_disabled=0"
    echo "checkzfs_local=0"
    echo "checkzfs_prefix=miyagi-$SOURCEHOSTNAME-$(hostname)-$ZPUSHTAG"
    echo "checkzfs_max_age=1500,2000"
    echo "checkzfs_max_snapshot_count=180,200"
    echo "checkzfs_spool=1"
    echo "checkzfs_spool_maxage=90000"
  } > "$conf_file"
}

run_zsync() {
  if [[ "$ZSYNC" != "no" ]]; then
    /usr/bin/bashclub-zsync -c "/etc/bashclub/$SOURCEHOST.conf"
  else
    log "Zsync is disabled."
  fi
}

run_remote_updates() {
  if [[ "${UPDATES,,}" == "yes" ]]; then
    log "Running updates on local system..."

    TIMESTAMP=$(date +"%Y-%m-%d_%H-%M-%S")
    SNAPSHOT_TAG="pve-update-via-miyagi"
    MAX_SNAPSHOTS=5
    ZFS_DATASETS=("rpool/ROOT" "rpool/pveconf")
    REBOOT_FLAG="${REBOOT^^}"
    LOGFILE="/var/log/proxmox_update.log"

    log_msg() {
      local level="$1"
      local message="$2"
      local timestamp
      timestamp=$(date +"%Y-%m-%d %H:%M:%S")
      echo "[$timestamp] $message"
      echo "[$timestamp] [$level] $message" >> "$LOGFILE"
    }

    # Prüfen, ob Updates verfügbar sind
    if ! apt update | tee -a "$LOGFILE" | grep -qi "upgradable"; then
      log_msg "INFO" "Keine Updates verfügbar."
      return
    fi

    log_msg "INFO" "Updates verfügbar. Erstelle Snapshots."

    for dataset in "${ZFS_DATASETS[@]}"; do
      snapshot="${dataset}@${SNAPSHOT_TAG}-${TIMESTAMP}"
      log_msg "INFO" "Erstelle Snapshot: $snapshot"
      zfs snapshot "$snapshot"

      # Alte Snapshots bereinigen
      log_msg "INFO" "Bereinige alte Snapshots in $dataset"
      old_snaps=$(zfs list -t snapshot -o name -s creation | grep "^${dataset}@${SNAPSHOT_TAG}-")
      snap_count=$(echo "$old_snaps" | wc -l)
      if (( snap_count > MAX_SNAPSHOTS )); then
        snaps_to_delete=$(echo "$old_snaps" | head -n $((snap_count - MAX_SNAPSHOTS)))
        while IFS= read -r snap; do
          log_msg "INFO" "Lösche alten Snapshot: $snap"
          zfs destroy "$snap"
        done <<< "$snaps_to_delete"
      fi
    done

    # System-Upgrade
    log_msg "INFO" "Starte dist-upgrade"
    if ! apt dist-upgrade -y | tee -a "$LOGFILE"; then
      log_msg "ERROR" "Fehler während dist-upgrade"
      return 1
    fi

    log_msg "INFO" "Starte autoremove"
    apt autoremove -y | tee -a "$LOGFILE"

    # Kernel-Update prüfen
    if apt list --upgradable 2>/dev/null | grep -q "linux-image-"; then
      log_msg "WARN" "Kernel-Update erkannt. Neustart empfohlen."
      if [[ "$REBOOT_FLAG" == "YES" ]]; then
        log_msg "INFO" "REBOOT=YES erkannt. System wird neugestartet."
        reboot
      fi
    else
      log_msg "INFO" "Update abgeschlossen. Kein Neustart erforderlich."
    fi

    # PBS-Host-Update 
    if [[ "${BACKUPSERVER,,}" == "yes" ]]; then
      log "Running updates on PBS host ($PBSHOST)..."
      ssh -p $PBSPORT root@"$PBSHOST" apt update && ssh -p $PBSPORT root@"$PBSHOST" apt dist-upgrade -y || {
        log "Error during updates on $PBSHOST"
      }
    else
      log "PBS updates skipped (BACKUPSERVER=$BACKUPSERVER)"
    fi

  else
    log "Updates disabled (UPDATES=$UPDATES)"
  fi
}

send_piggyback() {
  get_sourcehostname
  local combined_host="miyagi-${SOURCEHOSTNAME}-$(hostname)"
  local filename="90000_${combined_host}"

  log "Reminder: Add a host named ${combined_host} in CMK (without Agent, Piggyback enabled)!"
  log "Creating piggyback file: $filename"

  {
    echo "<<<<${combined_host}>>>>"
    /usr/bin/check_mk_agent
    echo "<<<<>>>>"
  } > "$filename"

  if rscp "$filename" "$SOURCEHOST:/var/lib/check_mk_agent/spool/"; then
    log "Piggyback data successfully sent to $SOURCEHOST"
  else
    log "ERROR: Failed to send piggyback data to $SOURCEHOST"
  fi

  rm -f "$filename"
}

run_pbs_backup() {
  if [[ "${BACKUPSERVER,,}" != "yes" ]]; then
    log "PBS Backup übersprungen: BACKUPSERVER='$BACKUPSERVER' (muss 'yes' sein)"
    return 0
  fi

  get_sourcehostname
  log "Starte PBS Backup auf Host: $SOURCEHOST"

  # PBS-Storage prüfen und ggf. aktivieren
  log "Prüfe, ob PBS-Storage '$BACKUPSTORE' auf $SOURCEHOST aktiviert ist..."
  if rssh root@"$SOURCEHOST" "pvesm status | grep -w '$BACKUPSTORE' | grep -q 'disabled'"; then
    log "PBS-Storage '$BACKUPSTORE' ist deaktiviert – aktiviere temporär und warte 10 Sekunden..."
    rssh root@"$SOURCEHOST" "pvesm set '$BACKUPSTORE' --disable 0 && sleep 10"
    pbs_enabled_by_script=true
  else
    log "PBS-Storage '$BACKUPSTORE' ist bereits aktiviert."
    pbs_enabled_by_script=false
  fi

  vzdump_success=false

  # Versuch: vzdump mit Change Detection
  ## Eintrag muss in /etc/vzdump.conf entries-max 100000000
  log "Starte vzdump mit Change Detection..."
  if rssh root@"$SOURCEHOST" vzdump --pbs-change-detection-mode metadata \
    --node "$SOURCEHOSTNAME" --storage "$BACKUPSTORE" \
    --exclude "$BACKUPEXCLUDE" --mode snapshot --all 1 \
    --notes-template '{{guestname}}'; then

    log "vzdump (Change Detection) erfolgreich."
    vzdump_success=true
  else
    log "vzdump (Change Detection) fehlgeschlagen – versuche Fallback ohne Change Detection..."

    if rssh root@"$SOURCEHOST" vzdump \
      --node "$SOURCEHOSTNAME" --storage "$BACKUPSTORE" \
      --exclude "$BACKUPEXCLUDE" --mode snapshot --all 1 \
      --notes-template '{{guestname}}'; then

      log "Fallback-vzdump erfolgreich."
      vzdump_success=true
    else
      log "FEHLER: vzdump fehlgeschlagen – auch im Fallback."
    fi
  fi

  # PBS-Storage ggf. wieder deaktivieren
  if [[ "$vzdump_success" == true && "$pbs_enabled_by_script" == true ]]; then
    log "Deaktiviere temporär aktiviertes PBS-Storage '$BACKUPSTORE' auf $SOURCEHOST..."
    rssh root@"$SOURCEHOST" "pvesm set '$BACKUPSTORE' --disable 1"
  fi

  # Monitoring-Ausgabe
  if [[ "$vzdump_success" == true ]]; then
    echo "0 DailyPBS - Daily Backup erfolgreich" > /tmp/cmk_tmp.out
  else
    echo "2 DailyPBS - Daily Backup FEHLGESCHLAGEN" > /tmp/cmk_tmp.out
  fi

  {
    echo "<<<local>>>"
    cat /tmp/cmk_tmp.out
  } > /tmp/90000_checkpbs

  rscp /tmp/90000_checkpbs root@"$SOURCEHOST":/var/lib/check_mk_agent/spool \
    || log "Fehler beim Übertragen des Monitoring-Outputs via SCP"

  rm -f /tmp/cmk_tmp.out /tmp/90000_checkpbs
  #write_pbs_status
}


run_maintenance() {
  if [[ "${BACKUPSERVER,,}" != "yes" ]]; then
    log "PBS Backup wird übersprungen (BACKUPSERVER=$BACKUPSERVER)"
    return
  fi
  
  if [[ "$(date +%u)" == "$MAINTDAY" ]]; then
    log "Running maintenance..."
    PRUNEJOB=$(ssh -p $PBSPORT "$PBSHOST" proxmox-backup-manager prune-job list --output-format json-pretty | grep -m 1 "id" | cut -d'"' -f4)
    ssh -p $PBSPORT root@"$PBSHOST" proxmox-backup-manager prune-job run "$PRUNEJOB"
    ssh -p $PBSPORT root@"$PBSHOST" proxmox-backup-manager garbage-collection start "$BACKUPSTOREPBS"
    ssh -p $PBSPORT root@"$PBSHOST" proxmox-backup-manager verify backup
  else
    log "No maintenance scheduled for today."
  fi
}

run_scrub_stop() {
  local mode="$1" # "local" oder "remote"
  local ssh_cmd=()

  if [[ "$mode" == "remote" ]]; then
    ssh_cmd=(ssh -p "$SOURCEPORT" root@"$SOURCEHOST")
  fi

  "${ssh_cmd[@]}" bash -c '
    for pool in $(zpool list -H -o name); do
      echo "Stopping scrub on pool: $pool"
      if zpool status "$pool" | grep -q "scrub in progress"; then
        if zpool scrub -s "$pool"; then
          echo "Scrub stopped on $pool"
        else
          echo "Error stopping scrub on $pool"
        fi
      else
        echo "No active scrub on $pool"
      fi
    done
  '
}

write_pbs_status() {
  local spool_file="/var/lib/check_mk_agent/spool/90000_checkpbs_local"
  local repo="$BACKUPSTOREPBS"
  local tmpfile
  tmpfile=$(mktemp)

  if ! command -v proxmox-backup-client >/dev/null 2>&1; then
    log "proxmox-backup-client nicht installiert – PBS-Status-Ausgabe übersprungen."
    return
  fi

  echo "<<<local>>>" > "$tmpfile"

  local now
  now=$(date +%s)

  # === Schwellenwert(e) parsen ===
  local warn_threshold=0
  local crit_threshold=86400  # Default kritisch ab 24h

  if [[ -n "${PBSBACKUP_STATUS:-}" ]]; then
    IFS=',' read -r t1 t2 <<< "$PBSBACKUP_STATUS"
    if [[ "$t1" =~ ^[0-9]+$ && -z "$t2" ]]; then
      # Nur ein Wert vorhanden
      crit_threshold=$t1
      log "Verwende einfachen Schwellenwert: CRIT=${crit_threshold}s"
    elif [[ "$t1" =~ ^[0-9]+$ && "$t2" =~ ^[0-9]+$ ]]; then
      warn_threshold=$t1
      crit_threshold=$t2
      log "Verwende gestaffelte Schwellenwerte: WARN=${warn_threshold}s, CRIT=${crit_threshold}s"
    else
      log "WARNUNG: Ungültiges PBSBACKUP_STATUS-Format – Fallback: CRIT=${crit_threshold}s"
    fi
  fi

  # Backup-Daten extrahieren
  rssh root@"$SOURCEHOST" proxmox-backup-client list --repository "$repo" --output-format json 2>/dev/null | \
  grep -E '"backup-id"|"backup-type"|"backup-time"' | \
  sed -E 's/[",]//g; s/^ *//' > "$tmpfile.json"

  local backup_type="" backup_id="" backup_time=""
  while read -r line; do
    case "$line" in
      backup-type:*)
        backup_type="${line#*: }"
        ;;
      backup-id:*)
        backup_id="${line#*: }"
        ;;
      backup-time:*)
        backup_time="${line#*: }"

        if [[ -n "$backup_type" && -n "$backup_id" && -n "$backup_time" ]]; then
          local age status timestamp msg
          age=$((now - backup_time))
          timestamp=$(date -d "@$backup_time" "+%Y-%m-%d %H:%M:%S")

          if (( age < warn_threshold )); then
            status=0
          elif (( age < crit_threshold )); then
            status=1
          else
            status=2
          fi

          msg="$backup_type/$backup_id last backup $timestamp (age: $((age / 3600))h)"
          echo "$status PBS_${backup_type}_${backup_id} - $msg" >> "$tmpfile"

          # Reset
          backup_type="" backup_id="" backup_time=""
        fi
        ;;
    esac
  done < "$tmpfile.json"

  rm -f "$tmpfile.json"
  mv "$tmpfile" "$spool_file"
  log "PBS Backup Status lokal geschrieben: $spool_file"
}

shutdown_now() {
  if [[ "${SHUTDOWN,,}" == "yes" ]]; then
    if zfs_replace; then
      log "ZFS Replace-Vorgang erkannt – warte bis zum Abschluss..."
      if ! wait_replace; then
        log "Shutdown abgebrochen – Replace ist nach max. Wartezeit noch nicht abgeschlossen."
        return
      fi
    fi
    send_piggyback
    send_piggyback_external
    send_checkzfs_external
    log "Shutting down now...in 1 min"
    shutdown +1
  else
    log "No shutdown requested."
  fi
}

send_piggyback_external() {
    if [[ "${EPIGGYBACK,,}" != "yes" ]]; then
        log "Externer Piggyback-Export deaktiviert."
        return
    fi
    get_sourcehostname
    log "Ermittelter SOURCEHOSTNAME: $SOURCEHOSTNAME"

    local combined_host="miyagi-${SOURCEHOSTNAME}-$(hostname)"
    local spool_file="90000_${combined_host}_external"
    local temp_dir
    temp_dir=$(mktemp -d)

    log "Erzeuge temporäre Piggyback-Datei: $temp_dir/$spool_file"

    {
        echo "<<<<${combined_host}>>>>"
        /usr/bin/check_mk_agent
        echo "<<<<>>>>"
    } > "$temp_dir/$spool_file"

    if scp -P "$EPIGGYBACK_PORT" "$temp_dir/$spool_file" "$EPIGGYBACK_HOST:/var/lib/check_mk_agent/spool/"; then
        log "Piggyback-Daten erfolgreich an $EPIGGYBACK_HOST gesendet: $spool_file"
    else
        log "Fehler beim Übertragen der Piggyback-Daten an $EPIGGYBACK_HOST"
        rm -rf "$temp_dir"
        return 1
    fi

    rm -rf "$temp_dir"
    return 0
}

send_checkzfs_external() {
        if [[ "${ECHECKZFS,,}" != "yes" ]]; then
        log "Externer Piggyback-Export deaktiviert."
        return
    fi
    local config="/etc/bashclub/${SOURCEHOST}.conf"
    if [[ ! -f "$config" ]]; then
        log "Konfigurationsdatei fehlt: $config"
        return 1
    fi
    source "$config"

    if [[ "${ECHECKZFS,,}" != "yes" ]]; then
        log "Externer Check-ZFS deaktiviert (ECHECKZFS=$ECHECKZFS)"
        return
    fi

    get_sourcehostname  # Setzt SOURCEHOSTNAME, wenn nicht vorhanden

    local checkzfs_cmd="${checkzfs_cmd:-$(command -v checkzfs)}"
    if [[ -z "$checkzfs_cmd" || ! -x "$checkzfs_cmd" ]]; then
        log "checkzfs nicht gefunden oder nicht ausführbar – Abbruch."
        return 1
    fi
    log "Verwende checkzfs: $checkzfs_cmd"

    # Filter anhand ZFS-Tags auf dem SOURCEHOST aufbauen
    local filter=""
    while IFS=$'\t' read -r name value source; do
        if [[ "$source" == "local" && "$value" == "subvols" ]]; then
            filter+="${name}/|"
        elif [[ "$source" == "local" && "$value" == "all" ]]; then
            filter+="${name}|"
        fi
    done < <(ssh -p "$SOURCEPORT" "$SOURCEHOST" "zfs get -H -o name,value,source -t filesystem,volume $ZPUSHTAG")

    filter="#${filter%|}"
    log "Generierter ZFS-Filter: $filter"

    local combined="miyagi-${SOURCEHOSTNAME}-$(hostname)"
    local spoolfile="/tmp/${combined}_checkzfs_external"
    local spooldest="90000_${combined}_checkzfs_external"

    log "Führe checkzfs aus..."
    {
        echo "<<<local>>>"
        "$checkzfs_cmd" \
            --source root@"${SOURCEHOST}:${SOURCEPORT}" \
            --filter "$filter" \
            --replicafilter "^${ZFSTRGT}" \
            --prefix "$checkzfs_prefix" \
            --threshold "$checkzfs_max_age" \
            --maxsnapshots "$checkzfs_max_snapshot_count" \
            --output checkmk
    } > "$spoolfile"

    if scp -P "$ECHECKZFS_PORT" "$spoolfile" root@"$ECHECKZFS_HOST":/var/lib/check_mk_agent/spool/"$spooldest"; then
        log "Spool-Datei erfolgreich übertragen an $ECHECKZFS_HOST:$spooldest"
    else
        log "Fehler beim Übertragen der Spool-Datei an $ECHECKZFS_HOST"
    fi

    rm -f "$spoolfile"
}
wait() {
    echo
    echo "###########################################"
    echo "# Das Backup startet in 60 Sekunden...    #"
    echo "# Drücke [Enter], um sofort fortzufahren, #"
    echo "# oder warte, um automatisch zu starten.  #"
    echo "###########################################"
    read -t 60 -p "Fortfahren (Enter drücken) oder warten... " input
    if [[ $? -eq 0 ]]; then
        log "Press ENTER to continue."
    else
        log "No press ENTER, wait for 60 Sec.."
        sleep 60
    fi
}
set_dynamic_route() {
    local ddns_hostname="$SOURCEHOST"
    local gateway="$DDNS_GATEWAY"
    local dns_server="1.1.1.1"

    if [[ -z "$ddns_hostname" || -z "$gateway" ]]; then
        log "Fehler: SOURCEHOST oder DDNS_GATEWAY nicht gesetzt"
        return 1
    fi

    log "Setze temporäre Route zu DNS-Server $dns_server via $gateway..."
    if ! ip route | grep -q "^$dns_server"; then
        ip route add "$dns_server" via "$gateway" \
            && log "Route zu $dns_server via $gateway gesetzt" \
            || log "Fehler beim Setzen der DNS-Route"
    else
        log "Route zu $dns_server bereits vorhanden"
    fi

    log "Löse IP von $ddns_hostname über DNS $dns_server..."
    CURRENT_IP=$(dig +short @"$dns_server" "$ddns_hostname")

    if [[ -z "$CURRENT_IP" ]]; then
        log "Fehler: Konnte IP für $ddns_hostname nicht auflösen"
        return 1
    fi

    log "Ermittelte IP: $CURRENT_IP – setze Route via $gateway..."
    if ! ip route | grep -q "^$CURRENT_IP"; then
        ip route add "$CURRENT_IP" via "$gateway" \
            && log "Route erfolgreich gesetzt: $CURRENT_IP via $gateway" \
            || log "Fehler beim Setzen der Route zu $CURRENT_IP"
    else
        log "Route zu $CURRENT_IP bereits vorhanden"
    fi
}
# Main execution:
if [[ $# -eq 0 ]]; then
  if [[ -n "$CONFIG_FILE" ]]; then
    wait
    log "Running full backup using configuration file: $CONFIG_FILE"
    
    if [[ "${DYNROUTE,,}" == "yes" ]]; then
        log "DYNROUTE ist aktiviert – setze dynamische Route für $SOURCEHOST..."
    set_dynamic_route
    else
    log "DYNROUTE ist deaktiviert oder nicht gesetzt."
    fi

    write_zsync_config
    run_zsync
    
    if [[ "${BACKUPSERVER,,}" == "yes" ]]; then
        log "BACKUPSERVER ist aktiviert, führe Backup aus..."
        run_maintenance
        run_pbs_backup
    else
        log "BACKUPSERVER ist nicht aktiviert (BACKUPSERVER=$BACKUPSERVER), überspringe Backup."
    fi
    run_remote_updates
    if [[ "${EPIGGYBACK,,}" == "yes" ]]; then
        send_piggyback_external
    fi

    if [[ "${ECHECKZFS,,}" == "yes" ]]; then
        send_checkzfs_external
    fi
    shutdown_now
  else
    usage
  fi
else
  case "$1" in
    help)
      declare -F | awk '{print $3}' | grep -v "^_" | grep -v "^main$"
      ;;
    *)
      if declare -F "$1" >/dev/null 2>&1; then
        "$@"
      else
        log "Function $1 not found."
        usage
      fi
      ;;
  esac
fi
