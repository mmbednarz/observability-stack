# Observability Stack (WEBCON)

Nieoficjalny, samodzielnie hostowany stos obserwowalności (metryki, ślady, logi) do analizy wydajności instalacji **WEBCON 2026.2+** na Windows Server – pokaz możliwości monitorowania.

> **Zastrzeżenia.** Projekt prywatny, udostępniony jako demonstracja możliwości monitorowania. Nie jest produktem WEBCON, nie jest przez WEBCON rozwijany, wspierany ani zatwierdzony. Brak wsparcia i gwarancji – używasz na własne ryzyko; przed użyciem w środowisku produkcyjnym przetestuj rozwiązanie. Szczegóły: licencja MIT ([LICENSE](LICENSE)). WEBCON, Grafana i inne nazwy są znakami towarowymi ich właścicieli.

| Sygnał | Źródło | Komponent |
|---|---|---|
| Metryki | WEBCON Portal/Serwis (OTLP), host Windows/IIS, SQL Server | **Prometheus** |
| Ślady (OTLP) | WEBCON Portal/Serwis | **Grafana Tempo** |
| Logi | Portal i Serwis (OTLP; od 2026.2), opcjonalnie pliki Serilog | **Grafana Loki** |
| Collector | wszystko powyżej | **Grafana Alloy** |
| Wizualizacja | korelacja metryki ↔ ślady ↔ logi | **Grafana** |

```
WEBCON Portal ──OTLP/HTTP :4318──┐
WEBCON Serwis ──OTLP/HTTP :4318──┤
Serilog (pliki Serwisu) ─────────┤                  ┌─> Prometheus :9090 (remote write + exemplary)
windows_exporter (wbudowany) ────┼─> Grafana Alloy ─┼─> Tempo      :3200 (OTLP gRPC :14317)
SQL Server (dedykowany login) ───┘   :12345 (UI)    └─> Loki       :3100 (/otlp, push)
                                                              │
                                Tempo metrics-generator ──────┘ (span metrics, service graph -> Prometheus)
                                                    Grafana :3000 (datasources z korelacją)
```

Wszystkie komponenty działają jako **usługi Windows** (WinSW, prefiks `obs-`) i nasłuchują wyłącznie na `127.0.0.1` (Grafana opcjonalnie na wszystkich interfejsach).

## Dokumentacja

**[docs/README.md](docs/README.md)** – spis treści. Najważniejsze:

- [Szybki start (all-in-one)](docs/instalacja/01-szybki-start.md) · [Wymagania i SQL Server](docs/instalacja/02-wymagania-i-przygotowanie.md) · [Konfiguracja WEBCON](docs/instalacja/03-konfiguracja-webcon.md)
- [Tryb zdalny (stos na osobnej VM)](docs/instalacja/04-tryb-zdalny.md) · [Aktualizacja](docs/instalacja/05-aktualizacja.md) · [Odinstalowanie](docs/instalacja/06-odinstalowanie.md)
- [Rozwiązywanie problemów](docs/instalacja/07-rozwiazywanie-problemow.md) · [Parametry instalatora](docs/instalacja/08-parametry-instalatora.md)

## Szybki start (skrót)

Wymagania: Windows Server 2019+ / Windows 10+, administrator, internet, WEBCON 2026.2+ na tej samej maszynie.

1. Pobierz `observability-stack-<wersja>.zip` z [Releases](https://github.com/mmbednarz/observability-stack/releases), odblokuj (`Unblock-File`) i rozpakuj, np. do `C:\Install`.
2. PowerShell jako administrator, w katalogu rozpakowanej paczki:

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
.\Install-ObservabilityStack.ps1 -SqlServer 'localhost,1433' -SqlLogin svc_obs_mssql_exporter   # albo -SqlServer '' (bez SQL)
C:\Observability\app\scripts\Set-WebconTelemetry.ps1    # włącza telemetrię WEBCON (restart WEBCON)
C:\Observability\app\Test-ObservabilityStack.ps1        # smoke test
```

Instalator kopiuje skrypty do `C:\Observability\app` – paczkę można potem usunąć.

Grafana: <http://localhost:3000> – użytkownik `admin`, hasło w `C:\Observability\secrets\grafana-admin.txt`. Krok po kroku (loginy SQL, SQL Express, weryfikacja): [Szybki start](docs/instalacja/01-szybki-start.md).

## Dashboardy

| Folder / dashboard | Zawartość |
|---|---|
| `webcon` / WEBCON – Wydajność | stan, Portal, formularze i przejścia, „gdzie ucieka czas” (ścieżki, reguły, źródła danych, akcje – TraceQL metrics), SQL z perspektywy WEBCON, Serwis (kolejki, timery, Solr, cache), runtime .NET, logi. |
| `webcon` / WEBCON – Utrzymanie | przegląd tygodniowy (7 dni): host, wejścia do Portalu, TOP 10 akcji i ścieżek (średnia, mediana, p95, min, max; nazwy ścieżek z bazy), aktywne zadania wg użytkowników (stan bieżący z bazy), zewnętrzne API wołane przez WEBCON (wywołania, p95, błędy), błędy źródeł danych i akcji. Panele z bazy wymagają `-WebconSqlReaderLogin`. |
| `webcon` / WEBCON – Dostępność i zaległości | sonda `/health` Portalu (adresy z powiązań IIS; kod HTTP, czas, certyfikat), zaległości w bazie treści (przeterminowane timeouty, akcje cykliczne z błędem, kolejka maili, tabele kolejek i logów). Metryki z bazy wymagają `-WebconDbMetrics $true`. |
| `host` / Windows – obciążenie hosta | CPU, pamięć, dyski, sieć, procesy (WEBCON, IIS, SQL), IIS |
| `sql` / SQL Server – WEBCON | obciążenie, oczekiwania wg kategorii, blokady, I/O i rozmiar baz, pamięć, wolne zapytania SQL z Tempo |
| `dotnet` | ASP.NET Core (grafana.com 19924, 19925) |

Metryki SQL Server definiuje `config-templates/alloy/mssql-queries.yaml` (domyślne metryki exportera + rozszerzenia), metryki z bazy treści WEBCON – `config-templates/alloy/webcon-db-queries.yaml`.

Katalog dashboardów na serwerze jest zarządzany przez instalator: pliki `.json` spoza repozytorium i spoza `CommunityDashboards` są przy instalacji usuwane. Własne dashboardy zapisuj w Grafanie (baza) albo dodaj do `dashboards/`.

## Alerty

30 reguł Grafana Alerting provisionowanych z `config-templates/grafana/provisioning/alerting/` (opis: [Alerty](docs/uzytkownik/07-alerty.md)):

| Folder | Reguły |
|---|---|
| WEBCON – alerty | W1–W10: p95 przejść ścieżek (> 5 s) i Portalu (> 3 s), 5xx Portalu (> 5 %), brak / błędy heartbeat Serwisu, błędy kolejki Serwisu, rosnące zaległości Solr, błędy źródeł danych (Loki), błędy wywołań zewnętrznych API, skok błędów w logach; B1–B2: Portal niedostępny, certyfikat wkrótce wygaśnie; D1–D3: zaległe timeouty, maile nie wychodzą, akcje cykliczne z błędem; S1–S3: zakleszczenia, blokady, Page Life Expectancy; H1–H4: CPU, pamięć, dysk (per host) |
| Stos obserwowalności – alerty | O1–O7: komponent stosu nie odpowiada, host przestał wysyłać metryki (także agenci zdalni), brak telemetrii Serwisu, błędy zapytań Tempo, limit serii spanmetrics, odrzucona telemetria w Alloy, dysk danych stosu |

- Powiadomienia: **tylko UI Grafany** (Alerting → Alert rules / Active notifications) – bez kontaktpunktów. Wyciszanie: Alerting → Silences.
- Brak danych nie alarmuje (maszyna bez WEBCON / SQL jest cicha); zatrzymanie Serwisu lub agenta wykrywają reguły „dane były w ciągu 24 h, brak od 10–15 min” (W4, O2, O3).
- Awaria Prometheusa / Loki = stan `Error` (`DatasourceError`) reguł korzystających z danego źródła.
- Reguły są tylko do odczytu w UI – zmiana = edycja YAML w repozytorium i ponowna instalacja. Błąd w pliku reguł blokuje start Grafany (log: `Failed to provision alerting`).
- `Test-ObservabilityStack.ps1` (sekcja „Alerty”) liczy reguły, zgłasza błędy ewaluacji i wypisuje aktywne alerty.

## Bezpieczeństwo danych telemetrii

Alloy usuwa ze spanów atrybut `webcon.db.cs` (dane połączenia z bazą) przed zapisem (`otelcol.processor.attributes "webcon_secrets"`), a `Test-ObservabilityStack.ps1` to sprawdza.

## Tryby SQL tracingu

| Tryb | WEBCON `SqlTracing` | Alloy | Zastosowanie |
|---|---|---|---|
| Próg (domyślny) | włączony | odrzuca spany SQL < `-SqlSpanThresholdSeconds` | analiza wolnych zapytań przy rozsądnym wolumenie |
| Wszystkie | włączony | `-SqlSpanThresholdSeconds 0` | pełny obraz, duży wolumen |
| Wyłączony | `Set-WebconTelemetry.ps1 -SqlTracing Off` | – | minimalny wolumen |

Filtr obejmuje span WEBCON `SqlQuery` oraz spany SqlClient (`db.system` / `db.system.name`).

## Wersje

Wydania: [Releases](https://github.com/mmbednarz/observability-stack/releases), zmiany i kroki ręczne przy aktualizacji: [CHANGELOG.md](CHANGELOG.md). Zainstalowaną wersję pokazuje smoke test (`C:\Observability\config\install-settings.json`, pole `StackVersion`). Aktualizacja: [docs/instalacja/05-aktualizacja.md](docs/instalacja/05-aktualizacja.md).

## Struktura paczki

```
Install-ObservabilityStack.ps1     instalacja / aktualizacja stosu
Uninstall-ObservabilityStack.ps1   usunięcie usług (-RemoveFiles: także danych)
Test-ObservabilityStack.ps1        smoke test end-to-end
Install-ObservabilityAgent.ps1     agent na hoście WEBCON / SQL (tryb zdalny, uruchamiany z paczki agent-bundle)
Uninstall-ObservabilityAgent.ps1   usunięcie agenta
versions.psd1                      przypięte wersje + URL-e + dashboardy społecznościowe
scripts/
  Set-WebconTelemetry.ps1          konfiguracja OpenTelemetry w appsettings WEBCON
  Test-SqlExporterLogin.ps1        samodzielna weryfikacja loginu SQL
  modules/ObservabilityStack.psm1  funkcje wspólne
config-templates/                  szablony konfiguracji ({{ZMIENNE}}, bloki @@BEGIN/@@END)
dashboards/                        dashboardy provisionowane do Grafany (podkatalog = folder)
config-templates/grafana/provisioning/alerting/   reguły alertów Grafany
sql/                               T-SQL dla DBA
webcon/                            przykładowa sekcja OpenTelemetry WEBCON
docs/                              dokumentacja (instalacja/, uzytkownik/)
VERSION, CHANGELOG.md, LICENSE     wersja, historia zmian, licencja MIT
```

## Układ na serwerze

```
C:\Observability\
  bin\<komponent>\        binarki (plik .version = zainstalowana wersja)
  config\                 wygenerowane konfiguracje + install-settings.json
  data\                   TSDB, bloki Tempo, chunki Loki, baza Grafany
  logs\<komponent>\       logi usług (WinSW, rotacja 10 MB x 8)
  services\obs-*\         wrappery WinSW (exe + xml)
  secrets\                hasło Grafany, connection string SQL, hasło loginu Grafany do bazy (ACL: SYSTEM + Administrators)
  downloads\              cache pobranych archiwów
  app\                    kopia skryptów zainstalowanej wersji (smoke test, odinstalowanie, zmiana parametrów)
```

## Diagnostyka

Tabela problemów i rozwiązań, logi komponentów, naprawa indeksu Tempo: [Rozwiązywanie problemów](docs/instalacja/07-rozwiazywanie-problemow.md).

## Bezpieczeństwo (dev)

- Usługi tylko na localhost, brak uwierzytelnienia między komponentami.
- `ShowDbStatements = true` – treść zapytań SQL trafia do śladów (założenie: dostęp administracyjny/DBA).
- Sekrety w plikach z ACL ograniczonym do SYSTEM i Administrators; nigdy w repozytorium.
