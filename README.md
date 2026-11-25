# H10 Sleep & ECG

Eine universelle iOS-/iPadOS-App (ab **iOS 17**) für den **Polar H10** Brustgurt mit Live-EKG, Echtzeit-HRV, kontinuierlicher Rhythmus-Erkennung und nächtlicher Schlafanalyse.

> **Wichtiger Hinweis – Kein Medizinprodukt**  
> Diese App ist **kein Medizinprodukt** im Sinne der MDR/FDA und dient ausschließlich zu Informations- und privaten Forschungszwecken. Die angezeigten EKG-Kurven, HRV-Werte, Rhythmus-Hinweise (z. B. Verdacht auf Vorhofflimmern, Extrasystolen, Pausen) und Schlafphasen sind algorithmische Schätzungen und **kein Ersatz für eine ärztliche Diagnose oder Behandlung**. Bei Beschwerden, Schwindel, Brustschmerzen oder ungewöhnlichen Befunden wende dich bitte umgehend an eine Ärztin, einen Arzt oder den Notruf.

---

## Funktionen

- **Live-EKG (130 Hz):** Darstellung auf klassischem EKG-Papier (25 mm/s) mit automatischer Markierung von VES/SVES sowie Live-Signalqualität.
- **Echtzeit-HRV:** RMSSD (60 s und 5 min), SDNN, pNN50, RR-Tachogramm und Poincaré-Plot.
- **Kontinuierliche Rhythmus-Analyse (auch im Hintergrund):** Erkennt Hinweise auf Bradykardie, Tachykardie, Pausen, VES/SVES (inkl. Couplet, Bigeminus, Trigeminus) und Vorhofflimmern-Verdacht – inklusive gespeichertem EKG-Ausschnitt pro Ereignis.
- **Schlafanalyse & Schlaf-Score (0–100):** Nächtliche Aufzeichnung aus EKG, Herzfrequenz, HRV, Atmung und 3-Achsen-Beschleunigungssensor (25 Hz) inkl. internem RR-Backup-Speicher des Polar H10 gegen Verbindungsabbrüche.
- **Universal-App:** Optimiert für iPhone und iPad, alle Daten bleiben lokal auf deinem Gerät (SwiftData).

---

## Schritt-für-Schritt-Anleitung (Windows → GitHub Actions → SideStore)

Für diese App benötigst du **keinen Mac** und **kein kostenpflichtiges Apple-Developer-Konto**. GitHub Actions baut die unsignierte `.ipa`-Datei automatisch auf einem macOS-Runner; anschließend signiert und installiert **SideStore** die App direkt auf deinem iPhone/iPad mit deiner kostenlosen Apple-ID.

### 1. GitHub-Konto anlegen

1. Erstelle ein kostenloses Konto auf [github.com](https://github.com/signup) (falls noch nicht vorhanden).
2. Merke dir deinen **GitHub-Benutzernamen** (im Folgenden `GITHUB_USER`).

### 2. Git und GitHub CLI unter Windows installieren

Öffne **PowerShell** und installiere Git sowie die GitHub CLI (`gh`) über `winget`:

```powershell
winget install --id Git.Git -e
winget install --id GitHub.cli -e
```

Schließe PowerShell danach einmal und öffne es neu, damit `git` und `gh` im `PATH` verfügbar sind. Melde dich dann bei GitHub an:

```powershell
gh auth login
```

Folge dem Dialog (GitHub.com → HTTPS → Login with a web browser).

### 3. Öffentliches Repository `h10-sleep-ecg` erstellen und pushen

Wechsle in den Projektordner (z. B. `cd C:\Users\Jebel\Documents\H10`).  
*(Optional, wenn du später die SideStore-Quelle nutzen möchtest: ersetze in `sidestore-source.json` alle Vorkommen von `GITHUB_USER` durch deinen echten GitHub-Benutzernamen.)*

Initialisiere Git und lade das Projekt als **öffentliches** Repository hoch (öffentliche Repos haben unbegrenzte kostenlose GitHub-Actions-Minuten):

```powershell
git init -b main
git add .
git commit -m "Initial commit: H10 Sleep & ECG"
gh repo create h10-sleep-ecg --public --source=. --remote=origin --push
```

### 4. Auf GitHub Actions warten

1. Öffne dein Repository im Browser (`https://github.com/GITHUB_USER/h10-sleep-ecg`) und wechsle zum Tab **Actions**.
2. Der Workflow **Build & Test H10 Sleep & ECG** startet automatisch:
   - Zuerst laufen die Unit-Tests von `H10Analysis` (`swift test`).
   - Danach erzeugt XcodeGen das Xcode-Projekt und baut `H10Sleep.ipa` (dauert ca. 5–10 Minuten).
3. Nach erfolgreichem Lauf findest du die fertige `H10Sleep.ipa` unter **Releases → latest** (`https://github.com/GITHUB_USER/h10-sleep-ecg/releases/tag/latest`).

### 5. SideStore einmalig auf iPhone/iPad installieren

Folge der offiziellen Anleitung auf [sidestore.io](https://sidestore.io) (Kurzfassung für Windows):

1. **Windows-Treiber:** Installiere **iTunes** (direkt von Apple oder aus dem Microsoft Store), damit Windows dein iPhone/iPad erkennt.
2. **Entwicklermodus (iPhone/iPad):** Aktiviere unter *Einstellungen → Datenschutz & Sicherheit → Entwicklermodus* den Schalter und starte das Gerät neu.
3. **LocalDevVPN (iPhone/iPad):** Lade die kostenlose App **LocalDevVPN** aus dem iOS App Store herunter.
4. **SideStore + Pairing-File installieren:**
   - Lade das offizielle Windows-Tool **iloader** (empfohlen laut [sidestore.io](https://sidestore.io)) herunter.
   - Verbinde dein iPhone/iPad per USB-Kabel mit dem PC, entsperre es und tippe auf **Vertrauen**.
   - Starte `iloader`, melde dich mit deiner kostenlosen Apple-ID an, wähle dein Gerät und installiere **SideStore (Stable)**. Dabei wird die benötigte Pairing-Datei (`.mobiledevicepairing`) in der Regel automatisch erzeugt und übertragen.
   - *(Falls SideStore manuell nach einer Pairing-Datei fragt: Lade `jitterbugpair` für Windows herunter, verbinde das iPhone per USB, führe `./jitterbugpair.exe` in PowerShell aus, übertrage die erzeugte `.mobiledevicepairing`-Datei aufs iPhone und wähle sie in SideStore aus.)*
5. **SideStore einrichten:**
   - Trenne das USB-Kabel.
   - Öffne **LocalDevVPN** auf dem iPhone/iPad und tippe auf **Connect** (VPN-Konfiguration erlauben).
   - Öffne **SideStore**, melde dich mit derselben Apple-ID an und tippe unter **My Apps** einmal auf den **7 DAYS**-Button neben SideStore, um die Erst-Aktualisierung abzuschließen.

### 6. H10 Sleep & ECG über SideStore installieren

Stelle sicher, dass **LocalDevVPN** verbunden ist. Du hast zwei Möglichkeiten:

- **Weg A – Direkt über GitHub Releases (am schnellsten):**
  1. Öffne am iPhone/iPad in Safari `https://github.com/GITHUB_USER/h10-sleep-ecg/releases/latest`.
  2. Lade `H10Sleep.ipa` herunter.
  3. Öffne **SideStore → My Apps → `+`** (oben links) und wähle die heruntergeladene `H10Sleep.ipa`.
- **Weg B – Als SideStore-Quelle (bequem für spätere Updates):**
  1. Stelle sicher, dass du in `sidestore-source.json` den Platzhalter `GITHUB_USER` durch deinen Benutzernamen ersetzt und gepusht hast.
  2. Kopiere die Raw-URL:  
     `https://raw.githubusercontent.com/GITHUB_USER/h10-sleep-ecg/main/sidestore-source.json`
  3. Öffne **SideStore → Sources → `+`** und füge die URL hinzu. Danach kannst du **H10 Sleep & ECG** direkt aus der Quelle installieren und aktualisieren.

### 7. Automatische 7-Tage-Aktualisierung (LocalDevVPN + Kurzbefehle)

Kostenlos signierte Apps laufen nach 7 Tagen ab. Mit **LocalDevVPN** und der Apple-App **Kurzbefehle (Shortcuts)** aktualisiert sich die App vollautomatisch ohne PC:

1. Öffne auf dem iPhone/iPad die App **Kurzbefehle → Automation → `+`**.
2. Wähle z. B. **Ladegerät → Wird verbunden** (oder **Tageszeit**, z. B. täglich 03:00 Uhr) und stelle auf **Sofort ausführen** (ohne Rückfrage).
3. Füge folgende Aktionen hinzu:
   1. **LocalDevVPN → VPN verbinden** (*Connect*)
   2. **Warten** → `3` Sekunden
   3. **SideStore → Alle Apps aktualisieren** (*Refresh All Apps*)
   4. **LocalDevVPN → VPN trennen** (*Disconnect*)

Solange dein Gerät im WLAN ist, werden SideStore und **H10 Sleep & ECG** im Hintergrund automatisch verlängert.

### 8. Einschränkungen einer kostenlosen Apple-ID

- **Maximal 3 aktive Apps gleichzeitig:** SideStore selbst zählt als 1 App – daneben kannst du bis zu **2 weitere Apps** gleichzeitig signiert nutzen (z. B. *H10 Sleep & ECG* + eine weitere App).
- **Maximal 10 App-IDs pro 7 Tage:** Jede App und jede App-Erweiterung belegt eine App-ID. *H10 Sleep & ECG* benötigt nur **1 App-ID** (keine Widgets/Extensions).
- **7 Tage Gültigkeit:** Alle 7 Tage muss ein Refresh über SideStore (+ LocalDevVPN) erfolgen.

---

## Tipps für zuverlässige Messungen & Schlafaufzeichnungen

- **Elektroden gut anfeuchten:** Befeuchte die beiden gummierten Kontaktflächen auf der Rückseite des Polar H10 Gurts vor dem Anlegen gründlich mit Wasser (oder etwas Kontaktgel). Trockene Elektroden erzeugen Rauschen und falsche Extrasystolen-/Artefakt-Meldungen.
- **Gurt fest, aber bequem anlegen:** Der Sender sollte mittig unterhalb der Brustmuskulatur sitzen, ohne beim Atmen zu verrutschen.
- **iPhone/iPad nachts ans Ladegerät hängen:** Die kontinuierliche 130-Hz-EKG- und 25-Hz-ACC-Aufzeichnung verbraucht spürbar Akku. Mit Ladegerät läuft die Nacht problemlos durch.
- **App nicht nach oben wegwischen:** Lasse die App im Hintergrund offen (Sperrbildschirm ist völlig okay). Wenn du die App im App-Switcher manuell schließt, beendet iOS auch die Bluetooth-Hintergrundverbindung.
- **Interner H10-Backup-Speicher:** Wenn du in der App eine **Nacht startest**, aktiviert die App zusätzlich die interne RR-Aufzeichnung des Polar H10. Sollte Bluetooth nachts kurz abbrechen, werden die Lücken beim Beenden der Nacht automatisch aufgefüllt.
