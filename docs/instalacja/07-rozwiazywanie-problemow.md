# Rozwiązywanie problemów

Zawsze zacznij od smoke testu (PowerShell jako administrator, katalog repozytorium):

```powershell
.\Test-ObservabilityStack.ps1
```

## Wyniki smoke testu

| Sekcja / komunikat | Co znaczy | Co zrobić |
|---|---|---|
| **Usługi**: `obs-… - Stopped` | usługa nie działa | `Start-Service obs-…`; gdy nie startuje – log usługi (niżej) |
| **Gotowość**: komponent nie odpowiada | usługa działa, ale komponent nie jest gotowy | odczekaj 1–2 min po starcie; potem log usługi |
| `Loki: pattern ingester jeszcze nie gotowy` (WARN) | wewnętrzny moduł Loki startuje do ~2 h | nic – logi są przyjmowane |
| **Przepływ OTLP**: brak śladu / logu / metryki testowej | Alloy nie przekazuje danych do magazynu | Alloy UI <http://localhost:12345> (komponenty na czerwono), Dziennik zdarzeń Application, źródło `Alloy` |
| `Tempo: TraceQL metrics` błąd `parquet` | uszkodzony indeks bloków Tempo | procedura niżej |
| **Dane z WEBCON**: brak `OTLP źródło: Portal` | Portal nie wysłał jeszcze nic | otwórz Portal w przeglądarce, odczekaj 2 min |
| brak `OTLP źródło: WebCon.WorkFlow` / `Metryki webcon_*` | WEBCON nie wysyła telemetrii | [Set-WebconTelemetry.ps1](03-konfiguracja-webcon.md); po aktualizacji WEBCON uruchom ponownie |
| `Usługa WEBCON o niestandardowej nazwie …` / `… bez znacznika webcon.component` (WARN) | WEBCON wysyła telemetrię bez znacznika komponentu – nazwa usługi pochodzi z `ServiceName` w appsettings | `Set-WebconTelemetry.ps1` ([znacznik](03-konfiguracja-webcon.md#co-zmienia-skrypt)); awaryjnie `-WebconPortalServiceName` / `-WebconServiceServiceName` instalatora |
| `Dostępność (portal): … niedostępny (HTTP 401)` | WEBCON przestał odpowiadać anonimowo na `/health` dla nagłówka `Host: localhost` (zachowanie zaobserwowane na 2026.2.5) | sprawdź z serwera Portalu: `Invoke-WebRequest https://<host>/health -Headers @{Host='localhost'}`; zgłoś – sonda wymaga zmiany |
| `Dostępność … (HTTP 0)` | brak połączenia: DNS, IIS zatrzymany, certyfikat niezgodny z nazwą powiązania lub wygasły | panel *Fazy żądania HTTP*; log sondy: Alloy UI → `prometheus.exporter.blackbox.webcon` |
| `Dostępność … (HTTP 302)` | przekierowanie, np. na logowanie – adres nie wskazuje `/health` Portalu | `-ProbeUrl` z poprawnym adresem |
| `Metryki z bazy WEBCON: 0 z 4 metryk` (WARN) | login exportera bez dostępu do bazy treści / kolumn | DBA: `sql\grant-webcon-db-metrics.sql`; błędy zapytań: Dziennik zdarzeń Application, źródło `Alloy`, `component_id=prometheus.exporter.mssql.webcon_data` |
| `mssql exporter: down` | brak połączenia z SQL | `.\scripts\Test-SqlExporterLogin.ps1`; TCP włączone? ([SQL Express](02-wymagania-i-przygotowanie.md#sql-server-express--włączenie-tcp)) |
| `Grafana: źródło 'WEBCON SQL'` błąd | login Grafany nie ma uprawnień / złe hasło | DBA: `sql\grant-webcon-reader-permissions.sql` (zwłaszcza po aktualizacji WEBCON) |
| **Alerty**: błąd ewaluacji reguły | zapytanie reguły nie działa | log Grafany; zgłoś (reguły są w repozytorium) |
| `Alerty: N reguł z błędem sprzed restartu Grafany` (informacja) | Grafana po restarcie odtwarza ostatni stan reguł, także błąd z chwili, gdy źródło danych było niedostępne (np. ręczny restart Prometheusa) | nic – powtórz test za 1 min; błąd zniknie po kolejnej ewaluacji |
| **Alerty**: `Alert aktywny: …` (WARN) | reguła wykryła problem | [Alerty](../uzytkownik/07-alerty.md) – co znaczy dany alert |
| `Alerty nie sprawdzone - brak dostępu do hasła` | test uruchomiony bez administratora | uruchom PowerShell jako administrator |

## Problemy z instalacją

| Objaw | Rozwiązanie |
|---|---|
| `Zajęte porty: …` | instalator podaje proces zajmujący port – zatrzymaj go (np. lokalny Jaeger, Seq, inny collector OTLP) |
| skrypt nie uruchamia się / „is not digitally signed” | `Unblock-File` na pobranym ZIP przed rozpakowaniem; `Set-ExecutionPolicy -Scope Process Bypass -Force` |
| polskie znaki zniekształcone w komunikatach | plik skryptu zmieniony edytorem bez BOM – pobierz pliki ponownie |
| błąd pobierania / SHA256 niezgodna | brak internetu lub proxy; ponów z `-ForceDownload` |
| `Weryfikacja loginu SQL nie powiodła się` | instalator wypisuje brakujące uprawnienia – przekaż DBA |
| Grafana nie startuje po aktualizacji | `C:\Observability\logs\grafana\grafana.log` – `Failed to provision alerting` = błąd w regułach alertów z repozytorium |

## Problemy z WEBCON

| Objaw | Rozwiązanie |
|---|---|
| WEBCON nie startuje po `Set-WebconTelemetry.ps1` | przywróć kopie `*.bak-*` ([wycofanie](03-konfiguracja-webcon.md#wycofanie-zmian)); błąd zobaczysz, uruchamiając `WebCon.WorkFlow.Bootstrapper.exe` z konsoli w katalogu Serwisu |
| panele Portalu puste, a panele Serwisu pokazują trasy Portalu | nazwy usług z appsettings zamiast stałych `Portal` / `WebCon.WorkFlow` – uruchom `Set-WebconTelemetry.ps1` (znacznik `webcon.component`); `Nie znaleziono plików appsettings` = WEBCON poza `Program Files[ (x86)]\WEBCON` → `-SearchRoot` |
| dashboardy WEBCON puste po aktualizacji WEBCON | aktualizacja nadpisała appsettings – uruchom ponownie `Set-WebconTelemetry.ps1` |
| brak wolnych zapytań SQL w śladach | spany SQL krótsze niż próg (domyślnie 1 s) są odrzucane – to zamierzone; `-SqlSpanThresholdSeconds` instalatora |

## Gdzie są logi

| Komponent | Log |
|---|---|
| Grafana, Prometheus, Loki, Tempo | `C:\Observability\logs\<komponent>\` (`*.out.log`, `*.err.log`; Grafana: `grafana.log`) |
| Alloy | **Dziennik zdarzeń** → Application, źródło `Alloy` (nie pliki) oraz UI <http://localhost:12345> |
| usługi WinSW | `C:\Observability\logs\<komponent>\*.wrapper.log` |
| konfiguracja instalacji | `C:\Observability\config\install-settings.json` |

## Uszkodzony indeks Tempo

Objaw: panele „Gdzie ucieka czas” i inne oparte o TraceQL pokazują `reading parquet file metadata: missing required field`; smoke test: błąd `Tempo: TraceQL metrics`.

```powershell
Stop-Service obs-tempo -Force          # zatrzyma też obs-alloy (zależność)
Remove-Item C:\Observability\data\tempo\blocks\single-tenant\index.json.gz, `
            C:\Observability\data\tempo\blocks\single-tenant\index.pb.zst -ErrorAction SilentlyContinue
Start-Service obs-tempo, obs-alloy
```

Tempo odbuduje indeks z bloków; dane nie są tracone.

## Komponenty bezpośrednio (diagnostyka)

| Adres | Co pokazuje |
|---|---|
| <http://localhost:12345> | Alloy – graf przetwarzania, stan komponentów |
| <http://localhost:9090/query?g0.expr=up> | Prometheus – `up` = 1 dla każdego źródła metryk zbieranego przez Alloy (windows, mssql, komponenty stosu) |
| <http://localhost:3200/ready>, <http://localhost:3100/ready> | gotowość Tempo, Loki |
