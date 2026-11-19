# Aktualizacja

Instalator jest **idempotentny**: ponowne uruchomienie na zainstalowanym stosie aktualizuje binarki, konfigurację, dashboardy i reguły alertów, a **zachowuje dane** (metryki, ślady, logi, użytkowników Grafany) i sekrety.

## Aktualizacja do nowej wersji

1. Pobierz nową paczkę z [Releases](https://github.com/mmbednarz/observability-stack/releases), odblokuj i rozpakuj **do nowego katalogu** (np. `C:\Install\observability-stack-0.9.1`) – jak w [Szybkim starcie, krok 1](01-szybki-start.md#krok-1-pobierz-pliki-instalacyjne).
2. Przeczytaj sekcję nowej wersji w `CHANGELOG.md` (w paczce) – **Wymaga działań** wymienia kroki ręczne (np. nowe uprawnienia SQL, ponowne `Set-WebconTelemetry.ps1`).
3. PowerShell jako administrator, w katalogu nowej paczki:

   ```powershell
   Set-ExecutionPolicy -Scope Process Bypass -Force
   .\Install-ObservabilityStack.ps1 -NonInteractive
   C:\Observability\app\Test-ObservabilityStack.ps1
   ```

Instalator pokazuje zmianę wersji (`Aktualizacja 0.9.0 -> 0.9.1`), zachowuje ustawienia i dane, a `C:\Observability\app` zastępuje skryptami nowej wersji. Starą i nową paczkę można potem usunąć. Zainstalowaną wersję pokazuje smoke test (sekcja „Wersja”).

**Starsza wersja** niż zainstalowana – instalator przerywa (konfiguracja i reguły alertów nowszej wersji mogą nie pasować do starszej). Świadomy powrót do starszej wersji: `-AllowDowngrade`.
**Przerwa w działaniu:** instalator zatrzymuje usługi `obs-*` na czas aktualizacji (zwykle 1–3 minuty, dłużej gdy pobiera nowe wersje komponentów). WEBCON działa normalnie – telemetria z tego okresu jest tracona, WEBCON tego nie odczuwa.

### Które ustawienia są zachowywane

| Zachowywane automatycznie (z `C:\Observability\config\install-settings.json`) | **Trzeba podać ponownie** przy każdej aktualizacji |
|---|---|
| instancja i login exportera SQL (`-SqlServer`, `-SqlLogin`) + hasło | `-GrafanaListenAll`, `-OtlpListenAll` |
| login, instancja i baza źródła „WEBCON SQL” + hasło | `-RetentionMetricsDays`, `-RetentionTracesDays`, `-RetentionLogsDays` (gdy inne niż domyślne) |
| tryb zdalny: hosty, instancja, port, adresy, hasła loginów | `-SqlSpanThresholdSeconds`, `-ServiceLogPath`, `-AlloyMemoryLimit`, `-EnvironmentName` |
| hasło administratora Grafany | `-SkipCommunityDashboards` |

Przykład – stos z Grafaną dostępną w sieci i dłuższą retencją śladów:

```powershell
.\Install-ObservabilityStack.ps1 -GrafanaListenAll -RetentionTracesDays 14
```

> Zapisz swoje polecenie instalacji (np. w pliku `install.cmd.txt` obok paczek), żeby przy aktualizacji powtórzyć te same parametry.

### Co nadpisuje aktualizacja

- **Dashboardy** z paczki (`dashboards\`) – zmiany zrobione w Grafanie na tych dashboardach zostaną utracone. Własne dashboardy zapisuj jako **nowe** (*Save as*) – są w bazie Grafany i aktualizacja ich nie rusza.
- **Reguły alertów** – są tylko do odczytu w Grafanie; zmiana = edycja YAML w `config-templates\` (nadpisywana przez kolejne wydanie).
- Pliki `.json` w `C:\Observability\config\grafana\dashboards` spoza paczki są usuwane.
- Konfiguracja komponentów w `C:\Observability\config` – generowana od nowa z szablonów.

## Zmiana parametrów

Ponowne uruchomienie instalatora z nowymi parametrami – bez paczki, z kopii w `C:\Observability\app` (ta sama wersja), np.:

```powershell
cd C:\Observability\app
.\Install-ObservabilityStack.ps1 -GrafanaListenAll
```

Przykłady:

| Cel | Polecenie |
|---|---|
| dodanie metryk SQL po instalacji bez SQL | `.\Install-ObservabilityStack.ps1 -SqlServer 'localhost,1433' -SqlLogin svc_obs_mssql_exporter` |
| dodanie źródła „WEBCON SQL” | `.\Install-ObservabilityStack.ps1 -WebconSqlReaderLogin svc_obs_grafana_reader` |
| zmiana hasła loginu SQL exportera | `.\Install-ObservabilityStack.ps1 -SqlServer 'localhost,1433' -SqlLogin svc_obs_mssql_exporter` (zapyta o hasło) |
| wyłączenie metryk SQL | `.\Install-ObservabilityStack.ps1 -SqlServer ''` |
| wyłączenie źródła „WEBCON SQL” | `.\Install-ObservabilityStack.ps1 -WebconSqlReaderLogin ''` |
| Grafana dostępna z sieci | `.\Install-ObservabilityStack.ps1 -GrafanaListenAll` (dodaje regułę zapory dla portu 3000) |

Pełna lista: [Parametry instalatora](08-parametry-instalatora.md).

## Po aktualizacji WEBCON

Aktualizacja WEBCON może nadpisać `appsettings` i `web.config` oraz odtworzyć tabele bazy treści:

1. `C:\Observability\app\scripts\Set-WebconTelemetry.ps1` – ponownie włącza eksport telemetrii (restart WEBCON).
2. DBA: `C:\Observability\app\sql\grant-webcon-reader-permissions.sql` – ponownie nadaje uprawnienia loginowi Grafany.
3. `C:\Observability\app\Test-ObservabilityStack.ps1` – sprawdzenie.

Objaw pominięcia: puste dashboardy WEBCON (brak 1.) albo błędy w panelach z nazwami ścieżek i zadaniami (brak 2.).

## Zmiana wersji komponentu (dla zaawansowanych)

Wersje Grafany, Prometheusa, Tempo, Loki i Alloy są przypięte w `versions.psd1` (URL + suma SHA256) i zmieniają się z wydaniem stosu. Nie zmieniaj ich na serwerze – konfiguracja może wymagać zmian (np. Tempo 3.x usuwa sekcje `ingester` / `compactor`).

## Hasło administratora Grafany

Plik `C:\Observability\secrets\grafana-admin.txt` jest używany **tylko przy pierwszym uruchomieniu** Grafany (tworzenie bazy). Hasło zmienione później w Grafanie (*Profile → Change password*) nie jest zapisywane w pliku – plik będzie nieaktualny, a smoke test nie sprawdzi alertów. Zalecenie: nie zmieniaj hasła `admin`, twórz osobne konta dla ludzi.

Reset zapomnianego hasła (PowerShell jako administrator):

```powershell
& C:\Observability\bin\Grafana\bin\grafana.exe cli --homepath C:\Observability\bin\Grafana `
    --config C:\Observability\config\grafana\grafana.ini admin reset-admin-password (Get-Content C:\Observability\secrets\grafana-admin.txt)
```
