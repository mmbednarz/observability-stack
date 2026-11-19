# Odinstalowanie

## Kolejność

1. **Wyłącz telemetrię w WEBCON** – inaczej WEBCON będzie dalej próbował wysyłać dane na `localhost:4318` (bez wpływu na działanie WEBCON, ale z błędami eksportu w logach).
2. **Usuń stos** (`Uninstall-ObservabilityStack.ps1`).
3. (opcjonalnie) **Usuń loginy SQL**.

## 1. WEBCON – przywrócenie konfiguracji

Przywróć kopie plików sprzed pierwszego uruchomienia `Set-WebconTelemetry.ps1` (najstarsze `*.bak-*`) – procedura: [Konfiguracja WEBCON → Wycofanie zmian](03-konfiguracja-webcon.md#wycofanie-zmian). Pliki:

| Katalog (domyślnie `C:\Program Files\WEBCON\…`) | Pliki |
|---|---|
| `WEBCON BPS Portal` | `appsettings.Production.json`, `web.config` |
| `WEBCON BPS WorkFlow Service` | `appsettings.Production.json` |

Zmienne `OTEL_*` Serwisu są w rejestrze usługi – usuń je, jeśli przywracasz konfigurację ręcznie:

```powershell
$key = 'HKLM:\SYSTEM\CurrentControlSet\Services\WebCon WorkFlow Service'
(Get-ItemProperty $key).Environment      # podgląd
Remove-ItemProperty $key -Name Environment   # tylko gdy zawiera wyłącznie zmienne OTEL_* dodane przez skrypt
Restart-Service 'WebCon WorkFlow Service'
```

Prostsza alternatywa bez przywracania plików: w `appsettings.Production.json` Portalu i Serwisu ustaw `OpenTelemetry → Metrics / Tracing / Logs → Enabled = false` i zrestartuj WEBCON.

## 2. Usunięcie stosu

PowerShell jako administrator, w katalogu `C:\Observability\app` (kopia skryptów zainstalowanej wersji) albo paczki:

```powershell
# usługi i reguły zapory; dane, konfiguracja i sekrety ZOSTAJĄ w C:\Observability
.\Uninstall-ObservabilityStack.ps1

# wszystko, łącznie z danymi i hasłami (nieodwracalne)
.\Uninstall-ObservabilityStack.ps1 -RemoveFiles
```

| Wariant | Kiedy | Co zostaje |
|---|---|---|
| bez `-RemoveFiles` | chwilowe wyłączenie, przeniesienie, reinstalacja z zachowaniem historii | `C:\Observability` (dane, sekrety, `install-settings.json`). Ponowny `Install-ObservabilityStack.ps1` wróci do poprzedniej konfiguracji i danych |
| z `-RemoveFiles` | trwałe usunięcie, czysta reinstalacja | nic – przy ponownej instalacji trzeba podać loginy SQL i hasła; Grafana dostanie **nowe** hasło `admin` |

Podgląd bez zmian: `-WhatIf`.

**Zabezpieczenia `-RemoveFiles`:**

- katalog instalacji zawiera repozytorium git (np. sklonowane do `C:\Observability\...`) – skrypt **odmawia** usunięcia; przenieś repozytorium i uruchom ponownie,
- katalog instalacji zawiera inne pliki niż stos (`bin`, `config`, `data`, `logs`, `services`, `secrets`, `downloads`, `app`, `agent-bundle`) – skrypt je wypisuje i pyta o potwierdzenie; `-Force` pomija pytanie.

**Czysta reinstalacja** (np. test nowej wersji): `Uninstall-ObservabilityStack.ps1 -RemoveFiles`, potem [Szybki start, krok 3](01-szybki-start.md#krok-3-uruchom-instalator). Konfiguracji WEBCON nie trzeba zmieniać – adres `localhost:4318` jest ten sam.

## 3. Loginy SQL (opcjonalnie)

Skrypty nie usuwają loginów. DBA:

```sql
DROP LOGIN [svc_obs_mssql_exporter];
-- w każdej bazie treści WEBCON:
USE [WEBCON_Content]; DROP USER IF EXISTS [svc_obs_grafana_reader];
DROP LOGIN [svc_obs_grafana_reader];
```

## Tryb zdalny – usunięcie agenta

Na każdym hoście WEBCON / SQL (PowerShell jako administrator, w `C:\Observability\app` – kopia skryptów agenta; paczka agenta nie jest potrzebna):

```powershell
.\Uninstall-ObservabilityAgent.ps1               # usługa obs-alloy
.\Uninstall-ObservabilityAgent.ps1 -RemoveFiles  # także C:\Observability na hoście
```

Skrypt usuwa też regułę zapory `Observability - SQL (Grafana)` na hoście SQL. Nie zmienia konfiguracji WEBCON (krok 1 – na hoście WEBCON) ani loginów SQL (wypisuje polecenia `DROP LOGIN`).

Na VM stosu: `Uninstall-ObservabilityStack.ps1` usuwa też regułę `Observability - Agenci`.
