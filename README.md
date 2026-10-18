# UGREEN NAS Docker Backup & Restore

[![Quality](https://github.com/Railsimulatornet/UGREEN-NAS-Docker-Backup-Restore/actions/workflows/quality.yml/badge.svg?branch=main)](https://github.com/Railsimulatornet/UGREEN-NAS-Docker-Backup-Restore/actions/workflows/quality.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

![Docker Backup Pack](Screen/DockerBackupPack.png)

[Deutsch](#deutsch) · [English](#english)

## Deutsch

Dieses Paket sichert Docker-Projekte auf UGREEN NAS mit UGOS und stellt sie bei Bedarf wieder her. Es unterstützt auch den Umzug auf ein anderes NAS und den Abgleich mit der UGOS-Docker-App.

### Funktionen

- Backup aller oder ausgewählter Docker-Projekte.
- Restore einzelner oder mehrerer Projekte mit Prüfung der Auswahl.
- Automatische Erkennung von Docker-Pfaden und UGOS-Docker-Datenbank.
- Standalone-Container ohne Compose-Projektlabel als eigene Projekte sichern.
- Optional Images, Named Volumes und externe Bind-Mounts einschließen.
- Cache-Verzeichnisse über eine Ausschlussliste auslassen.
- Pfade beim NAS-Umzug über eine Zuordnungstabelle anpassen.
- Optional Archive per SCP übertragen, Statusmails senden und das NAS nach erfolgreichem Backup herunterfahren.
- Deutsche und englische Ausgaben, Protokolle und Mails.
- Zeitgesteuerter Betrieb über Cron.

### Voraussetzungen

- UGREEN NAS mit UGOS und laufendem Docker-Dienst.
- SSH-Zugriff und Root-Rechte für Docker-, Datei- und UGOS-Zugriffe.
- Bash, Python 3 und die verwendeten Archivwerkzeuge, insbesondere `tar` und `gzip`.
- Ausreichend Platz für Backup, temporäre Dateien und Logs.
- Für optionale Funktionen: SMTP-Zugang beziehungsweise SSH/SCP-Zugang zum Sicherungsziel.

Die Pfade in dieser Anleitung sind Beispiele. Passe das Volume an dein NAS an.

### Schnellstart

1. Lade das aktuelle ZIP-Paket unter [Releases](https://github.com/Railsimulatornet/UGREEN-NAS-Docker-Backup-Restore/releases/latest) herunter.
2. Lege in der UGOS-App **Dateien** eine Freigabe `DockerBackup` an, zum Beispiel `/volume2/DockerBackup`. Lasse den Papierkorb dafür deaktiviert und prüfe die Lese- und Schreibrechte für Administratoren.
3. Kopiere den **Inhalt** des entpackten Ordners `DockerBackup/` direkt in diese Freigabe.
4. Verbinde dich per SSH mit dem NAS und bereite die Dateien vor:

```bash
sudo -i
cd /volume2/DockerBackup
cp dockersich.env.example dockersich.env
chmod +x ugreen-docker-backup.sh ugreen-docker-restore.sh
```

5. Bearbeite `dockersich.env`. Prüfe für den Einstieg mindestens diese Werte:

```bash
LANGUAGE=de
HOST_LABEL="UGREEN NAS"
SOURCE_DIR=auto
BACKUP_DIR=/volume2/DockerBackup
SEND_MAIL=false
DRY_RUN=true
```

`DRY_RUN` gilt **nur für Restore**. Ein Aufruf des Backup-Skripts erstellt ein echtes Backup und kann mit `STOP_CONTAINERS=true` Container vorübergehend stoppen.

### Konfiguration

Die vollständige Vorlage liegt in [DockerBackup/dockersich.env.example](DockerBackup/dockersich.env.example). Beide Skripte verwenden die aktive Datei `dockersich.env` im Skriptordner.

| Bereich | Einstellungen und Bedeutung |
| --- | --- |
| Sprache und Anzeigename | `LANGUAGE=de` oder `LANGUAGE=en`; `HOST_LABEL` für Logs und Mails. |
| Automatische Erkennung | `SOURCE_DIR=auto`; auch `DOCKER_ROOT_DIR=auto` und `UGOS_DOCKER_DB=auto` werden unterstützt. |
| Arbeitsverzeichnisse | `BACKUP_DIR`, `TEMP_DIR` und `LOG_DIR` legen Archiv-, Arbeits- und Logpfade fest. |
| Archiv und Aufbewahrung | `COMPRESS_BACKUP=true` erzeugt ein komprimiertes Archiv; `false` ein TAR-Archiv. `KEEP_BACKUPS` begrenzt die aufbewahrten Backups. |
| Projektwahl beim Backup | `BACKUP_ALL_PROJECTS`, `INCLUDE_PROJECTS`, `EXCLUDE_PROJECTS` und `EXCLUDE_CONTAINERS` steuern die Auswahl. |
| Standalone-Container | `BACKUP_STANDALONE_CONTAINERS=true` schließt Container ohne Compose-Projekt ein. |
| Container stoppen | `STOP_CONTAINERS=true` und `STOP_TIMEOUT` steuern das Stoppen vor dem Backup. Zuvor laufende Container werden danach wieder gestartet. |
| Ausschlüsse | `BACKUP_EXCLUDE_PATHS_FILE=backup-exclude-paths.txt` verweist auf die [Ausschlussliste](DockerBackup/backup-exclude-paths.txt). |
| Zusätzliche Inhalte | `BACKUP_IMAGES`, `BACKUP_NAMED_VOLUMES` und `BACKUP_EXTERNAL_BINDS` aktivieren zusätzliche Sicherungen. |
| Restore-Auswahl | `RESTORE_ALL_PROJECTS`, `RESTORE_PROJECTS` und `RESTORE_STANDALONE_CONTAINERS` steuern die Wiederherstellung. Die genaue Auswahlregel steht unten. |
| Vorhandene Ziele | `RESTORE_OVERWRITE_EXISTING=false` verhindert das Überschreiben vorhandener Projektordner. |
| Zusätzliche Restore-Inhalte | `RESTORE_IMAGES`, `RESTORE_NAMED_VOLUMES` und `RESTORE_EXTERNAL_BINDS` müssen für die jeweiligen Inhalte aktiviert sein. |
| Pfadzuordnung | `ENABLE_PATH_REMAP=true` und `PATH_REMAP_FILE=path-remap.tsv` nutzen die [Zuordnungstabelle](DockerBackup/path-remap.tsv). |
| UGOS-Abgleich | `UPDATE_UGOS_DOCKER_DB` und `REFRESH_UGOS_DOCKER_APP` steuern Datenbankabgleich und Aktualisierung der Docker-App. |
| Mail | `SEND_MAIL` aktiviert den Versand. `MAIL_NOTIFY_ON` erlaubt `all`, `success`, `fail` oder `none`. SMTP-Zugang, Absender und Empfänger stehen ebenfalls in der ENV-Datei. |
| Remote-Sicherung | `ENABLE_REMOTE_BACKUP` sowie `REMOTE_HOST`, `REMOTE_USER`, `REMOTE_PORT` und `REMOTE_PATH` konfigurieren das zusätzliche SCP-Ziel. |
| Herunterfahren | `SHUTDOWN_AFTER_SUCCESS=false` lässt das NAS nach dem Backup eingeschaltet. Aktiviere die Option nur, wenn ein Herunterfahren gewünscht ist. |

### Backup starten

```bash
cd /volume2/DockerBackup
./ugreen-docker-backup.sh
```

Das Skript erkennt die Pfade, wählt die Projekte aus und erstellt das Archiv. Je nach Konfiguration stoppt es laufende Container vorübergehend, startet sie wieder und versendet Mails zu Start, Erfolg oder Fehler.

### Restore starten

Prüfe zuerst die Projektauswahl und lasse `DRY_RUN=true` gesetzt. Ersetze den Archivnamen im Beispiel durch dein vorhandenes Backup:

```bash
cd /volume2/DockerBackup
./ugreen-docker-restore.sh /volume2/DockerBackup/ugreen-docker-backup_YYYY-MM-DD_HH-MM-SS.tar.gz
```

Komprimierte und unkomprimierte TAR-Backups werden unterstützt.

**Für einen gezielten Restore musst du `RESTORE_PROJECTS` ausfüllen und `RESTORE_ALL_PROJECTS=false` verwenden.** Ist `RESTORE_PROJECTS` leer, berücksichtigt das Skript alle Projekte im Archiv, auch bei `RESTORE_ALL_PROJECTS=false`. Ausschlüsse und die Standalone-Option gelten weiterhin.

Prüfe die Ausgabe des Dry-Runs. Setze erst danach `DRY_RUN=false` und starte den Restore erneut. Standardmäßig verlangt das Skript in der interaktiven Konsole die Bestätigung `RESTORE`.

### Auf ein anderes NAS umziehen

1. Erstelle das Backup auf dem Quell-NAS.
2. Kopiere Archiv und Paket auf das Ziel-NAS.
3. Passe bei abweichenden Pfaden `path-remap.tsv` an. Quell- und Zielpfad werden durch einen echten Tabulator getrennt.
4. Prüfe den Restore auf dem Ziel-NAS mit `DRY_RUN=true` und deiner Projektauswahl.
5. Führe den Restore aus und kontrolliere den UGOS-Docker-App-Abgleich sowie die gestarteten Projekte.

Ein Standalone-Container wird beispielsweise als `standalone_ubuntu-1` gesichert. Beim Restore kann daraus ein Compose-Projekt für die UGOS-Docker-App erzeugt werden.

### Zeitgesteuertes Backup

Trage den Aufruf in die Root-Crontab über `crontab -e` ein. Dieses Beispiel läuft sonntags um 03:30 Uhr:

```cron
30 3 * * 0 cd /volume2/DockerBackup && /volume2/DockerBackup/ugreen-docker-backup.sh >> /volume2/DockerBackup/cron.log 2>&1
```

### Aktualisierung

Sichere vor dem Austausch die vorhandenen Skripte und deine Konfiguration. Übernimm die Skripte aus dem aktuellen Release und vergleiche neue Optionen mit `dockersich.env.example`. Behalte deine aktive `dockersich.env`, Ausschlussliste, Pfadzuordnungen und Archive. Starte während des Austauschs keinen Backup- oder Restore-Lauf.

### Projektstruktur

| Pfad | Inhalt |
| --- | --- |
| [DockerBackup/](DockerBackup/) | Backup- und Restore-Skript, ENV-Vorlage, Ausschlussliste und Pfadzuordnung. |
| [Screen/](Screen/) | Projektbilder. |
| [Changelog.txt](Changelog.txt) | Bisherige Änderungen. |
| [UGREEN_Docker_BR_DE_EN.pdf](UGREEN_Docker_BR_DE_EN.pdf) | Ausführliches Handbuch für Installation, Backup, Restore und Migration. |

Aktuelle Paketversion: **v1.10.1**. Verwende die [Release-Dateien](https://github.com/Railsimulatornet/UGREEN-NAS-Docker-Backup-Restore/releases/latest) für die Installation.

### Fehlersuche

| Problem | Prüfen |
| --- | --- |
| Skript startet nicht | Ausführungsrechte mit `chmod +x` und den Skriptpfad prüfen. |
| Keine Mail | SMTP-Werte, `SEND_MAIL` und `MAIL_NOTIFY_ON` prüfen. |
| Keine Projekte ausgewählt | `BACKUP_ALL_PROJECTS`, `INCLUDE_PROJECTS` und `EXCLUDE_PROJECTS` prüfen. |
| Archiv wird sehr groß | Cache-Pfade in `backup-exclude-paths.txt` und zusätzliche Backup-Inhalte prüfen. |
| Restore erscheint nicht in UGOS | `REFRESH_UGOS_DOCKER_APP=true` prüfen oder das Projekt in UGOS neu bereitstellen. |
| SCP-Übertragung scheitert | SSH-Zugang und Zielrechte prüfen; bei manuellen Tests den im Skript verwendeten Legacy-Modus `scp -O` berücksichtigen. |

### Dokumentation und Lizenz

Das [Handbuch (DE/EN)](UGREEN_Docker_BR_DE_EN.pdf) enthält die ausführliche Schrittfolge. Dieses Projekt steht unter der [MIT-Lizenz](LICENSE).

Community-Projekt von **Roman Glos / Railsimulatornet**, kein offizielles UGREEN-Produkt. Verwendung auf eigene Verantwortung. Feedback, Verbesserungsvorschläge und Praxistests sind willkommen; mit einem Stern auf GitHub kannst du das Projekt unterstützen.

## English

![Docker Backup Pack – English](Screen/DockerBackupPackEN.png)

This package backs up Docker projects on UGREEN NAS systems running UGOS and restores them when needed. It also supports migration to another NAS and integration with the UGOS Docker app.

### Features

- Back up all or selected Docker projects.
- Restore one or more projects with selection checks.
- Automatically detect Docker paths and the UGOS Docker database.
- Back up standalone containers without Compose project labels as separate projects.
- Optionally include images, named volumes and external bind mounts.
- Exclude cache directories through an exclusion list.
- Remap paths when moving to another NAS.
- Optionally transfer archives over SCP, send status emails and shut down the NAS after a successful backup.
- German and English console output, logs and emails.
- Scheduled operation through cron.

### Requirements

- UGREEN NAS running UGOS with an active Docker service.
- SSH access and root privileges for Docker, file and UGOS operations.
- Bash, Python 3 and the archive tools used by the scripts, particularly `tar` and `gzip`.
- Enough space for backups, temporary files and logs.
- For optional features: SMTP access or SSH/SCP access to the remote backup target.

The paths in this guide are examples. Adjust the volume to match your NAS.

### Quick start

1. Download the current ZIP package from [Releases](https://github.com/Railsimulatornet/UGREEN-NAS-Docker-Backup-Restore/releases/latest).
2. Create a share named `DockerBackup` in the UGOS **Files** app, for example at `/volume2/DockerBackup`. Leave its recycle bin disabled and check that administrators have read and write access.
3. Copy the **contents** of the extracted `DockerBackup/` folder directly into this share.
4. Connect to the NAS over SSH and prepare the files:

```bash
sudo -i
cd /volume2/DockerBackup
cp dockersich.env.example dockersich.env
chmod +x ugreen-docker-backup.sh ugreen-docker-restore.sh
```

5. Edit `dockersich.env`. Check at least these settings before the first run:

```bash
LANGUAGE=en
HOST_LABEL="UGREEN NAS"
SOURCE_DIR=auto
BACKUP_DIR=/volume2/DockerBackup
SEND_MAIL=false
DRY_RUN=true
```

`DRY_RUN` applies **only to restore**. Running the backup script creates a real backup and may temporarily stop containers when `STOP_CONTAINERS=true`.

### Configuration

The complete template is [DockerBackup/dockersich.env.example](DockerBackup/dockersich.env.example). Both scripts use the active `dockersich.env` file in the script directory.

| Area | Settings and purpose |
| --- | --- |
| Language and display name | `LANGUAGE=de` or `LANGUAGE=en`; `HOST_LABEL` identifies the NAS in logs and emails. |
| Automatic detection | `SOURCE_DIR=auto`; `DOCKER_ROOT_DIR=auto` and `UGOS_DOCKER_DB=auto` are also supported. |
| Working directories | `BACKUP_DIR`, `TEMP_DIR` and `LOG_DIR` define archive, temporary and log paths. |
| Archive and retention | `COMPRESS_BACKUP=true` creates a compressed archive; `false` creates a TAR archive. `KEEP_BACKUPS` limits retained backups. |
| Backup project selection | `BACKUP_ALL_PROJECTS`, `INCLUDE_PROJECTS`, `EXCLUDE_PROJECTS` and `EXCLUDE_CONTAINERS` control selection. |
| Standalone containers | `BACKUP_STANDALONE_CONTAINERS=true` includes containers without a Compose project. |
| Stopping containers | `STOP_CONTAINERS=true` and `STOP_TIMEOUT` control stopping before backup. Previously running containers are started again afterwards. |
| Exclusions | `BACKUP_EXCLUDE_PATHS_FILE=backup-exclude-paths.txt` points to the [exclusion list](DockerBackup/backup-exclude-paths.txt). |
| Additional contents | `BACKUP_IMAGES`, `BACKUP_NAMED_VOLUMES` and `BACKUP_EXTERNAL_BINDS` enable additional backups. |
| Restore selection | `RESTORE_ALL_PROJECTS`, `RESTORE_PROJECTS` and `RESTORE_STANDALONE_CONTAINERS` control restoration. The exact selection rule is explained below. |
| Existing destinations | `RESTORE_OVERWRITE_EXISTING=false` prevents overwriting existing project directories. |
| Additional restore contents | `RESTORE_IMAGES`, `RESTORE_NAMED_VOLUMES` and `RESTORE_EXTERNAL_BINDS` must be enabled for the respective contents. |
| Path mapping | `ENABLE_PATH_REMAP=true` and `PATH_REMAP_FILE=path-remap.tsv` use the [mapping table](DockerBackup/path-remap.tsv). |
| UGOS integration | `UPDATE_UGOS_DOCKER_DB` and `REFRESH_UGOS_DOCKER_APP` control database updates and Docker app refresh. |
| Email | `SEND_MAIL` enables delivery. `MAIL_NOTIFY_ON` accepts `all`, `success`, `fail` or `none`. SMTP credentials, sender and recipients are also configured in the ENV file. |
| Remote backup | `ENABLE_REMOTE_BACKUP` plus `REMOTE_HOST`, `REMOTE_USER`, `REMOTE_PORT` and `REMOTE_PATH` configure the additional SCP destination. |
| Shutdown | `SHUTDOWN_AFTER_SUCCESS=false` keeps the NAS running after backup. Enable it only when shutdown is intended. |

### Start a backup

```bash
cd /volume2/DockerBackup
./ugreen-docker-backup.sh
```

The script detects paths, selects projects and creates the archive. Depending on the configuration, it temporarily stops running containers, starts them again and sends start, success or failure emails.

### Start a restore

Check the project selection first and keep `DRY_RUN=true`. Replace the example archive name with your existing backup:

```bash
cd /volume2/DockerBackup
./ugreen-docker-restore.sh /volume2/DockerBackup/ugreen-docker-backup_YYYY-MM-DD_HH-MM-SS.tar.gz
```

Both compressed and uncompressed TAR backups are supported.

**For a selective restore, fill in `RESTORE_PROJECTS` and use `RESTORE_ALL_PROJECTS=false`.** If `RESTORE_PROJECTS` is empty, the script considers all projects in the archive, even when `RESTORE_ALL_PROJECTS=false`. Exclusions and the standalone-container setting still apply.

Review the dry-run output. Only then set `DRY_RUN=false` and run the restore again. By default, the script requires the confirmation `RESTORE` in an interactive terminal.

### Move to another NAS

1. Create a backup on the source NAS.
2. Copy the archive and package to the destination NAS.
3. Adjust `path-remap.tsv` if paths differ. Separate the source and destination paths with a real tab character.
4. Check the restore on the destination with `DRY_RUN=true` and your project selection.
5. Run the restore and verify the UGOS Docker app integration and started projects.

A standalone container may be backed up as `standalone_ubuntu-1`, for example. During restore, it can become a Compose project for the UGOS Docker app.

### Scheduled backup

Add the command to the root crontab using `crontab -e`. This example runs on Sundays at 03:30:

```cron
30 3 * * 0 cd /volume2/DockerBackup && /volume2/DockerBackup/ugreen-docker-backup.sh >> /volume2/DockerBackup/cron.log 2>&1
```

### Updating

Back up the existing scripts and your configuration before replacing them. Take the scripts from the latest release and compare new options with `dockersich.env.example`. Keep your active `dockersich.env`, exclusion list, path mappings and archives. Do not run a backup or restore while replacing the files.

### Project structure

| Path | Contents |
| --- | --- |
| [DockerBackup/](DockerBackup/) | Backup and restore scripts, ENV template, exclusion list and path mapping. |
| [Screen/](Screen/) | Project images. |
| [Changelog.txt](Changelog.txt) | Previous changes. |
| [UGREEN_Docker_BR_DE_EN.pdf](UGREEN_Docker_BR_DE_EN.pdf) | Detailed installation, backup, restore and migration manual. |

Current package version: **v1.10.1**. Use the [release assets](https://github.com/Railsimulatornet/UGREEN-NAS-Docker-Backup-Restore/releases/latest) for installation.

### Troubleshooting

| Problem | Check |
| --- | --- |
| Script does not start | Check executable permissions with `chmod +x` and verify the script path. |
| No email | Check SMTP settings, `SEND_MAIL` and `MAIL_NOTIFY_ON`. |
| No projects selected | Check `BACKUP_ALL_PROJECTS`, `INCLUDE_PROJECTS` and `EXCLUDE_PROJECTS`. |
| Archive is very large | Check cache paths in `backup-exclude-paths.txt` and additional backup contents. |
| Restore is missing in UGOS | Check `REFRESH_UGOS_DOCKER_APP=true` or redeploy the project in UGOS. |
| SCP transfer fails | Check SSH access and destination permissions; for manual tests, account for the script's legacy mode `scp -O`. |

### Documentation and license

The [DE/EN manual](UGREEN_Docker_BR_DE_EN.pdf) contains the detailed procedure. This project is licensed under the [MIT License](LICENSE).

Community project by **Roman Glos / Railsimulatornet**, not an official UGREEN product. Use at your own risk. Feedback, suggestions and practical tests are welcome; a GitHub star is another way to support the project.

