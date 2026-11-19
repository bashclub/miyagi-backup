# Miyagi Backup – Einrichtung, ZFS-Replikation und PBS-Sicherung

> Überarbeitete technische Anleitung · November 2026

## 1. Voraussetzungen und wichtige Hinweise

**Empfehlung: Zuerst den Proxmox ZFS Postinstaller verwenden.** Dieser richtet die benötigten Werkzeuge ein, darunter `bashclub-zsync`, `zfs-auto-snapshot` und `checkzfs`. Eine manuelle Installation dieser Komponenten ist dann normalerweise nicht erforderlich.

**Repository:** [bashclub/proxmox-zfs-postinstall](https://github.com/bashclub/proxmox-zfs-postinstall)

Der Postinstaller kann auf einem Proxmox-VE-System folgendermaßen gestartet werden:

```bash
wget -O ./postinstall --no-cache \
  https://github.com/bashclub/proxmox-zfs-postinstall/raw/main/postinstall

bash ./postinstall
```

Die gewünschten Komponenten werden im interaktiven Menü ausgewählt.

Die Anleitung setzt voraus, dass ZFS bereits vorhanden ist, da als Systeme Proxmox VE beziehungsweise TrueNAS zum Einsatz kommen. Ein separater Abschnitt zur ZFS-Installation entfällt deshalb.

### Welche Miyagi-Version verwenden?

Die ursprüngliche GitHub-Version ist weiterhin verfügbar. Für Neuinstallationen sollte jedoch die neuere Gitea-Version berücksichtigt werden.

- **Aktuellere Entwicklung:** [Miyagi Backup auf Gitea](https://gitea.perlbach24.de/scripte/miyagi-backup)
- **Ursprüngliches Repository:** [bashclub/miyagi-backup](https://github.com/bashclub/miyagi-backup)

Die Gitea-Version enthält zusätzliche Entwicklungen, unter anderem konfigurierbare Checkmk-Spool-Dateien, deren automatische Bereinigung und eine erweiterte PBS-Konfiguration mit Namespace-Unterstützung.

## 2. Miyagi installieren

Auf dem Backupserver:

```bash
git clone \
  https://gitea.perlbach24.de/scripte/miyagi-backup.git \
  /opt/miyagi-backup

cd /opt/miyagi-backup

chmod +x miyagi-backup.sh miyagi-check.sh

cp config.example /etc/miyagi.conf
chmod 600 /etc/miyagi.conf
```

Die wichtigsten Dateien sind:

| Datei | Funktion |
|---|---|
| `miyagi-backup.sh` | Steuerung der Sicherung |
| `config.example` | Vorlage aller zentralen Konfigurationsparameter |
| `miyagi-check.sh` | Prüfung von Konfiguration und SSH-Verbindungen |

Der Hostname des Quellsystems wird mittlerweile automatisch per SSH ermittelt. Ein manuelles Setzen von `SOURCEHOSTNAME` ist normalerweise nicht mehr erforderlich.

## 3. Konfiguration

Die Konfiguration erfolgt über:

```bash
nano /etc/miyagi.conf
```

**Wichtig: Die einfachen Anführungszeichen `''` bei den Parametern nicht löschen.** Beispielsweise bleibt `ZSYNC='yes'` in dieser Form bestehen. Auch optionale Werte sollten nicht versehentlich durch komplett leere Variablen ersetzt werden.

### Grundparameter

```bash
UPDATES='no'
SHUTDOWN='no'
DYNROUTE='no'
DDNS_GATEWAY='192.168.50.1'
REBOOT='no'

SOURCEPORT='22'
SOURCEHOST='192.168.50.200'
```

`SOURCEHOST` ist die IP-Adresse beziehungsweise der DNS-Name des Quell-Proxmox-Systems.

### ZFS-Datasets

```bash
ZFSROOT='none'
ZFSSECOND='none'
ZFSTRGT='rpool/repl/pve200'
```

`ZFSROOT` und `ZFSSECOND` werden in der aktuellen Replikationslogik nicht mehr zur Dataset-Auswahl verwendet.

Sie können in einer entsprechend bereinigten Skriptversion entfallen. **In der hier beschriebenen Gitea-Version sollten beide jedoch mit `none` gesetzt bleiben**, solange `miyagi-backup.sh` diese Variablen noch bei der Validierung verlangt.

Die Auswahl der tatsächlich zu replizierenden Datasets erfolgt über ZFS-Properties.

### ZFS-Replikation

```bash
ZSYNC='yes'
ZPUSHTAG='bashclub:zsync'
ZPUSHMINKEEP='3'
ZPUSHKEEP='14'
ZPUSHLABEL='zsync'
ZPUSHFILTER='hourly|daily|weekly|monthly'
```

Auf dem Quellsystem wird die entsprechende ZFS-Property gesetzt, beispielsweise:

```bash
zfs set bashclub:zsync=subvols rpool/data
```

Zur Kontrolle:

```bash
zfs get bashclub:zsync rpool/data
```

`bashclub-zsync` kann bereits über den Proxmox ZFS Postinstaller eingerichtet werden. Die separate manuelle Installation entfällt in diesem Fall.

## 4. PBS einrichten – ausschließlich mit API-Token

Für VM- und Container-Backups empfehlen wir grundsätzlich einen dedizierten PBS-Backupbenutzer und einen API-Token.

**Keine regulären Benutzerpasswörter für automatisierte PBS-Sicherungen verwenden.**

### Backupbenutzer auf PBS anlegen

1. Unter **Configuration → Access Control → User Management** einen Backupbenutzer erstellen, beispielsweise `backup@pbs`.
2. Unter **API Tokens** einen Token für diesen Benutzer erstellen, beispielsweise `miyagi`.
3. Dem Benutzer beziehungsweise Token die Berechtigung `DatastoreBackup` auf dem gewünschten Datastore oder Namespace gewähren.
4. Den Token-Schlüssel unmittelbar sicher hinterlegen.

Die vollständige Token-ID lautet beispielsweise:

```text
backup@pbs!miyagi
```

In Proxmox VE wird danach ein PBS-Storage mit dieser Token-ID und dem zugehörigen Secret eingerichtet. Das Secret gehört in die geschützte Storage-Konfiguration und **nicht** in die Miyagi-Konfiguration.

Für die Verwendung eingeschränkter API-Tokens müssen die effektiven Berechtigungen von Benutzer und Token auf den benötigten Datastore abgestimmt sein.

### Sicherheitsempfehlung

- Den dedizierten Backupbenutzer ausschließlich für die Sicherung vorsehen und seine interaktiven Anmeldedaten nicht für den Regelbetrieb aufbewahren. Passwort und gegebenenfalls TOTP-Registrierungsdaten können anschließend bewusst verworfen werden, sofern kein Wiederherstellungsbedarf für diesen Benutzer besteht.
- Den PBS-Root-Benutzer und sämtliche administrativen Proxmox-VE-Benutzer mit Zwei-Faktor-Authentifizierung (2FA) absichern.
- Für die Administration separate Konten mit 2FA verwenden, statt den Backupbenutzer interaktiv einzusetzen.

**Wichtig:** Miyagi nutzt für bestimmte PBS-Wartungsfunktionen weiterhin SSH. Ein PBS-API-Token ersetzt diese administrative SSH-Verbindung nicht. Diese sollte separat mit einem abgesicherten SSH-Schlüssel eingerichtet werden.

### PBS in Miyagi aktivieren

```bash
BACKUPSERVER='yes'
MAINTDAY='7'

PBSHOST='192.168.50.199'
PBSPORT='22'

BACKUPSTORE='backup'
BACKUPSTOREPBS='backup'
PBS_NAMESPACE='none'

BACKUPEXCLUDE='9999,99988'
REPLEXCLUDE=$BACKUPEXCLUDE
```

| Variable | Beschreibung |
|---|---|
| `BACKUPSERVER` | Aktiviert PBS-Backups |
| `PBSHOST` | Adresse des PBS |
| `BACKUPSTORE` | PBS-Storage-ID auf Proxmox VE |
| `BACKUPSTOREPBS` | Datastore-Name auf dem PBS |
| `PBS_NAMESPACE` | Optionaler Namespace, ansonsten `none` |
| `BACKUPEXCLUDE` | Auszuschließende VM-/CT-IDs |
| `REPLEXCLUDE` | Ausschlüsse für die Replikation |
| `MAINTDAY` | Wochentag der Wartung, `7` = Sonntag |

## 5. Checkmk: Replikation auf der Quelle kontrollieren

Ein wichtiger Bestandteil der Sicherung ist die Überwachung der erfolgreichen Replikation.

Dafür wird das Projekt [bashclub/check-zfs-replication](https://github.com/bashclub/check-zfs-replication) verwendet.

Das Tool `checkzfs` kann Snapshot-Alter und Replikationsstatus kontrollieren und seine Ergebnisse als Checkmk-Agentdaten bereitstellen.

Die neuere Miyagi-Version übergibt dafür zusätzliche Parameter an `bashclub-zsync`:

```bash
CHECKZFS_DISABLED='0'
CHECKZFS_LOCAL='0'
CHECKZFS_MAX_AGE='1500,2000'
CHECKZFS_MAX_SNAPSHOT_COUNT='180,200'
CHECKZFS_SPOOL='1'
CHECKZFS_SPOOL_MAXAGE='90000'
```

Diese Parameter besitzen im hier beschriebenen Skript Standardwerte und müssen nur bei abweichenden Anforderungen explizit ergänzt werden.

Die Ergebnisse lassen sich über eine Checkmk-Spool-Datei auf dem Quellsystem bereitstellen. So kann der Checkmk-Agent des produktiven Proxmox-Hosts den Replikationszustand melden, auch wenn Miyagi selbst nach der Sicherung heruntergefahren wurde.

Standardverzeichnis:

```text
/var/lib/check_mk_agent/spool/
```

Damit ist die Sicherung nicht ausschließlich anhand eines Logs auf dem Backupserver zu kontrollieren.

## 6. Checkmk-Piggyback und Shutdown

Miyagi unterstützt zusätzlich Piggyback-Daten, um Informationen des Backupservers in Checkmk sichtbar zu machen.

Hier muss zwischen zwei Verfahren unterschieden werden.

| Verfahren | Verhalten |
|---|---|
| Lokales Piggyback zur Quelle | Wird durch den Shutdown-Pfad geschrieben |
| Externes Piggyback (`EPIGGYBACK=yes`) | Wird auch bei regulären Durchläufen an den externen Host übertragen |
| Check-ZFS-Spool | Überwacht die eigentliche Replikation unabhängig vom Piggyback |

**Besonderheit:** Das lokale Piggyback wird nur geschrieben, wenn `SHUTDOWN='yes'` gesetzt ist und der entsprechende Abschaltpfad durchlaufen wird. Bei `SHUTDOWN='no'` sollte man deshalb nicht mit einer Aktualisierung dieses lokalen Piggybacks rechnen.

Ein externes Piggyback lässt sich mit diesen Parametern aktivieren:

```bash
EPIGGYBACK='yes'
EPIGGYBACK_PORT='22'
EPIGGYBACK_HOST='192.168.50.10'
```

Der externe Export kann auch bei einem dauerhaft laufenden Miyagi-System verwendet werden. Die neuere Version bietet zudem konfigurierbare Spool-Dateinamen und eine Bereinigung veralteter Dateien.

## 7. Testlauf und Kontrolle

Zunächst die Konfiguration prüfen:

```bash
bash -n /etc/miyagi.conf

/opt/miyagi-backup/miyagi-check.sh /etc/miyagi.conf
```

Anschließend den vollständigen Sicherungslauf starten:

```bash
/opt/miyagi-backup/miyagi-backup.sh -c /etc/miyagi.conf
```

Das Ergebnis auf dem Backupserver prüfen:

```bash
zpool status

zfs list -r rpool/repl/pve200

zfs list -t snapshot -r rpool/repl/pve200

tail -n 100 /var/log/miyagi-backup.log
```

Danach in Checkmk die entsprechenden Dienste auf dem Quellhost kontrollieren. Auf dem PBS zusätzlich die vorhandenen VM-/LXC-Backups und gegebenenfalls die Verifikation prüfen.

## 8. Zusammenfassung der empfohlenen Einrichtung

- [ ] Proxmox ZFS Postinstaller ausführen und `bashclub-zsync` sowie `checkzfs` einrichten
- [ ] Neuere Miyagi-Version von Gitea verwenden
- [ ] SSH-Schlüssel vom Backupserver zum Quellsystem einrichten
- [ ] `ZFSROOT` und `ZFSSECOND` vorerst mit `'none'` belegen
- [ ] ZFS-Datasets über `bashclub:zsync` markieren
- [ ] PBS mit dediziertem Backupbenutzer und API-Token einrichten
- [ ] Administrative Konten auf PBS und Proxmox VE mit 2FA absichern
- [ ] Checkmk-Replikationsüberwachung über Spool-Dateien aktivieren
- [ ] Piggyback-Verhalten bei Shutdown beziehungsweise externem Host berücksichtigen
- [ ] Vollständige Sicherung und Wiederherstellung testen

Damit stehen drei voneinander getrennte Funktionen zur Verfügung: **ZFS-Replikation** für die schnelle Wiederherstellung ganzer Datasets, **PBS-Sicherung** für VM-/LXC-Backups und **Checkmk-Monitoring** zur Kontrolle, ob die Datensicherungen aktuell und vollständig sind.

Bei späteren Änderungen sollten insbesondere die beiden zentralen Dateien `miyagi-backup.sh` und `config.example` erneut miteinander abgeglichen werden.
