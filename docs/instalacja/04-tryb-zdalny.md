# Tryb zdalny – stos na osobnej maszynie

Stos (Grafana, Prometheus, Tempo, Loki) instalujesz na **osobnej, pustej VM**. Na hostach WEBCON i SQL Server działa tylko lekki **agent** (usługa `obs-alloy`), który zbiera dane i przesyła je do stosu.

```
Host WEBCON                                    VM stosu
  Portal / Serwis ─OTLP─> agent obs-alloy ──TCP 4317 (ślady, logi)──> Alloy ─> Tempo / Loki / Prometheus
  metryki Windows / IIS ─┘                └─TCP 9999 (metryki)──────>          Grafana :3000
Host SQL
  metryki Windows + SQL ─> agent obs-alloy ──TCP 9999──────────────>
  SQL Server <──────────────── TCP 1433 ── Grafana (źródło „WEBCON SQL”)
```

Kiedy wybrać: produkcja-podobne środowisko, WEBCON i SQL na różnych serwerach, brak zgody na dodatkowe usługi na serwerze WEBCON poza agentem.

> **Status:** tryb zweryfikowany na jednej VM z symulowanym agentem. Instalacja agenta na prawdziwych hostach WEBCON / SQL nie została jeszcze przetestowana – zgłaszaj problemy.

## Wymagania

- VM stosu: jak w [Wymaganiach](02-wymagania-i-przygotowanie.md#serwer); internet potrzebny tylko na VM stosu (paczka agenta zawiera binarki).
- Łączność sieciowa:

  | Skąd | Dokąd | Port | Po co |
  |---|---|---|---|
  | host WEBCON, host SQL | VM stosu | TCP 4317 | ślady i logi (OTLP gRPC) |
  | host WEBCON, host SQL | VM stosu | TCP 9999 | metryki |
  | VM stosu | host SQL | TCP 1433 (`-SqlPort`) | źródło danych „WEBCON SQL” w Grafanie |
  | przeglądarki użytkowników | VM stosu | TCP 3000 | Grafana (`-GrafanaListenAll`) |

- Na hostach: administrator lokalny; na hoście SQL konto Windows z rolą `sysadmin` (skrypt tworzy loginy i nadaje uprawnienia).
- Połączenia agent → stos są **bez TLS i bez uwierzytelnienia**; zapora VM stosu dopuszcza tylko adresy hostów. Filtry (m.in. usuwanie atrybutu `webcon.db.cs` ze śladów) działają już w agencie.

## Krok 1. VM stosu – instalacja stosu i paczki agenta

```powershell
.\Install-ObservabilityStack.ps1 -WebconHost WEBCON01 -SqlHost SQL01 -SqlInstanceName SQLEXPRESS -GrafanaListenAll
```

| Parametr | Znaczenie |
|---|---|
| `-WebconHost` | nazwa hosta z WEBCON (Portal + Serwis) |
| `-SqlHost` | nazwa hosta SQL Server z bazami WEBCON |
| `-SqlInstanceName` | nazwa instancji (`MSSQLSERVER` = domyślna) |
| `-SqlPort` | port TCP instancji (domyślnie 1433) |
| `-WebconContentDatabase` | baza treści (domyślnie `WEBCON_Content`) |
| `-CentralAddress` | adres VM stosu, którego użyją agenci (domyślnie FQDN) |
| `-AgentAddress` | adresy IP dopuszczone w zaporze (domyślnie z DNS nazw hostów) |

Instalator tworzy paczkę `C:\Observability\agent-bundle` i archiwum `agent-bundle.zip` z:

- `README.txt` – kolejność kroków z nazwami Twoich hostów,
- `01-Sql-SQL01.ps1`, `02-Webcon-WEBCON01.ps1` – gotowe skrypty dla hostów (WEBCON i SQL na jednym hoście: jeden skrypt `01-WebconSql-<host>.ps1`),
- binarki Alloy i WinSW, skrypty SQL, `Set-WebconTelemetry.ps1`,
- **hasła loginów SQL** (`secrets\sql-logins.json`) – paczka jest poufna; usuń ją z hostów po instalacji.

## Krok 2. Host SQL

Skopiuj `agent-bundle.zip` na host SQL, rozpakuj, uruchom PowerShell jako administrator w katalogu paczki:

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
.\01-Sql-SQL01.ps1
```

Skrypt tworzy loginy `svc_obs_mssql_exporter` i `svc_obs_grafana_reader`, nadaje uprawnienia, instaluje agenta (metryki Windows + SQL Server) i dodaje regułę zapory dla Grafany.

Gdy instancja ma wyłączone TCP (typowo SQL Express), skrypt zatrzyma się z komunikatem. Wtedy:

```powershell
.\01-Sql-SQL01.ps1 -EnableSqlTcp     # UWAGA: restartuje instancję SQL Server
```

## Krok 3. Host WEBCON

```powershell
Set-ExecutionPolicy -Scope Process Bypass -Force
.\02-Webcon-WEBCON01.ps1
```

Skrypt instaluje agenta (odbiór telemetrii WEBCON na `127.0.0.1:4318`, metryki Windows i IIS) i uruchamia `Set-WebconTelemetry.ps1` – **restartuje Serwis WEBCON i aplikację Portalu** (z potwierdzeniem; `-Force` bez pytania, `-SkipWebconConfig` bez zmiany WEBCON).

Kolejność „najpierw SQL, potem WEBCON” pozwala zmieścić oba przestoje (restart SQL, restart WEBCON) w jednym oknie serwisowym.

## Krok 4. VM stosu – sprawdzenie

```powershell
.\Test-ObservabilityStack.ps1
```

Sekcja „Agenci zdalni” sprawdza metryki hostów, metryki SQL, telemetrię WEBCON i log testowy wysłany przez agenta. Telemetria Portalu pojawia się po pierwszym wejściu na Portal.

Na koniec usuń paczkę (`agent-bundle`, `agent-bundle.zip`) z hostów WEBCON i SQL – skrypt agenta kopiuje do `C:\Observability\app` na hoście wszystko, co potrzebne później (odinstalowanie, `Set-WebconTelemetry.ps1`, skrypty SQL), bez haseł. Nie rozpakowuj paczki do `C:\Observability` – skrypt odmówi.

## Aktualizacja i zmiany

- Ponowne uruchomienie instalatora stosu **bez** `-WebconHost` / `-SqlHost` zachowuje hosty i hasła (paczka jest generowana ponownie z tymi samymi hasłami).
- Aktualizacja agenta: po aktualizacji stosu do nowej wersji instalator generuje nową paczkę agenta (z tą samą wersją) → ponowne uruchomienie skryptu hosta (skrypt jest idempotentny).
- Powrót do trybu lokalnego: `.\Install-ObservabilityStack.ps1 -WebconHost '' -SqlHost ''`.
- Usunięcie agenta z hosta: [Odinstalowanie → agent](06-odinstalowanie.md#tryb-zdalny--usunięcie-agenta).
