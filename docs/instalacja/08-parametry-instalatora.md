# Parametry instalatora (`Install-ObservabilityStack.ps1`)

Opis parametrów jest też w nagłówku skryptu (`.PARAMETER`); lista składni: `Get-Help .\Install-ObservabilityStack.ps1`.

Kolumna **Zachowany** – czy przy ponownym uruchomieniu bez parametru instalator użyje poprzedniej wartości ([Aktualizacja](05-aktualizacja.md#które-ustawienia-są-zachowywane)). „Nie” = wraca wartość domyślna.

## Podstawowe

| Parametr | Domyślnie | Zachowany | Opis |
|---|---|---|---|
| `-Root` | `C:\Observability` | – | katalog instalacji (podawaj zawsze ten sam) |
| `-EnvironmentName` | nazwa komputera | nie | etykieta środowiska w telemetrii |
| `-NonInteractive` | – | – | bez pytań – brakujące wartości = błąd (skrypty automatyczne) |
| `-ConfigureWebcon` | – | – | po instalacji uruchamia `scripts\Set-WebconTelemetry.ps1` |
| `-AllowDowngrade` | – | – | zezwala na instalację wersji starszej niż zainstalowana (bez przełącznika: błąd) |
| `-ForceDownload` | – | – | pobiera komponenty ponownie (zamiast z `C:\Observability\downloads`) |
| `-SkipCommunityDashboards` | – | nie | bez dashboardów ASP.NET Core z grafana.com |

## SQL Server – metryki

| Parametr | Domyślnie | Zachowany | Opis |
|---|---|---|---|
| `-SqlServer` | pytanie | tak | instancja w formacie `host,port` (np. `localhost,1433`); `''` = bez metryk SQL |
| `-SqlLogin` | pytanie | tak | login exportera ([uprawnienia](02-wymagania-i-przygotowanie.md#1-login-exportera-metryk--svc_obs_mssql_exporter)) |
| `-SqlPassword` | pytanie | tak (sekret) | `SecureString`, np. `(Read-Host -AsSecureString)` |
| `-SqlEncrypt` / `-SqlTrustServerCertificate` | `$true` / `$true` | nie | szyfrowanie połączenia / akceptacja certyfikatu bez weryfikacji |

## SQL Server – źródło „WEBCON SQL” (baza treści)

| Parametr | Domyślnie | Zachowany | Opis |
|---|---|---|---|
| `-WebconSqlReaderLogin` | – | tak | login tylko do odczytu ([uprawnienia](02-wymagania-i-przygotowanie.md#2-login-grafany-do-bazy-treści--svc_obs_grafana_reader)); `''` = bez źródła |
| `-WebconSqlReaderPassword` | pytanie | tak (sekret) | `SecureString` |
| `-WebconSqlServer` | `-SqlServer` | tak | instancja z bazą treści |
| `-WebconContentDatabase` | `WEBCON_Content` | tak | nazwa bazy treści |

## Dostępność i metryki z bazy WEBCON

| Parametr | Domyślnie | Zachowany | Opis |
|---|---|---|---|
| `-PortalProbe` | `$true` | tak | sonda `/health` Portalu – adresy z powiązań IIS witryny Portalu (w trybie zdalnym: agent na hoście WEBCON) |
| `-ProbeUrl` | – | tak | dodatkowe adresy HTTP(S) do sprawdzania (kod 2xx), np. Portal produkcyjny; `''` = bez dodatkowych |
| `-WebconDbMetrics` | `$false` | tak | metryki z bazy treści (`-WebconContentDatabase`): zaległe timeouty, akcje cykliczne, maile, tabele kolejek i logów; uprawnienia: `sql\grant-webcon-db-metrics.sql` |

## Telemetria i retencja

| Parametr | Domyślnie | Zachowany | Opis |
|---|---|---|---|
| `-SqlSpanThresholdSeconds` | `1` | nie | spany zapytań SQL krótsze niż próg są odrzucane; `0` = wszystkie (duży wolumen) |
| `-RetentionMetricsDays` | `15` | nie | ile dni trzymać metryki |
| `-RetentionTracesDays` | `8` | nie | ślady (dashboard „WEBCON – Utrzymanie” pokazuje 7 dni) |
| `-RetentionLogsDays` | `7` | nie | logi |
| `-AlloyMemoryLimit` | `1GiB` | nie | limit pamięci Alloy |
| `-WebconPortalServiceName` / `-WebconServiceServiceName` | – | tak | **awaryjne** mapowanie nazw usług: nazwa (`ServiceName` z appsettings WEBCON), pod którą Portal / Serwis wysyła telemetrię bez znacznika `webcon.component`; Alloy zamienia ją na `Portal` / `WebCon.WorkFlow`. Niepotrzebne po `Set-WebconTelemetry.ps1`; wartości muszą się różnić; `''` = bez mapowania |
| `-ServiceLogPath` | – | nie | ścieżka plików logów Serwisu – tylko dla Serwisu bez eksportu logów OTLP (WEBCON 2026.2 eksportuje, nie używaj) |

## Sieć

| Parametr | Domyślnie | Zachowany | Opis |
|---|---|---|---|
| `-GrafanaListenAll` | – | nie | Grafana na wszystkich interfejsach + reguła zapory `Observability - Grafana` (TCP 3000, profile Domain/Private) |
| `-OtlpListenAll` | – | nie | odbiór OTLP z sieci (WEBCON na innej maszynie **bez** agenta) + reguła `Observability - OTLP` |

## Tryb zdalny

Opis: [Tryb zdalny](04-tryb-zdalny.md).

| Parametr | Domyślnie | Zachowany | Opis |
|---|---|---|---|
| `-WebconHost` / `-SqlHost` | – | tak | hosty agentów; `''` dla obu = powrót do trybu lokalnego |
| `-SqlInstanceName` | `MSSQLSERVER` | tak | instancja na `-SqlHost` |
| `-SqlPort` | `1433` | tak | port TCP instancji |
| `-CentralAddress` | FQDN VM stosu | tak | adres stosu wpisywany do konfiguracji agentów |
| `-AgentAddress` | adresy IP hostów z DNS | tak | adresy dopuszczone w zaporze |

## Przykłady

```powershell
# minimalna instalacja bez SQL
.\Install-ObservabilityStack.ps1 -SqlServer '' -NonInteractive

# pełna instalacja all-in-one (pyta o hasła)
.\Install-ObservabilityStack.ps1 -SqlServer 'localhost,1433' -SqlLogin svc_obs_mssql_exporter `
    -WebconSqlReaderLogin svc_obs_grafana_reader -GrafanaListenAll -ConfigureWebcon

# bez pytań (hasła ze zmiennych)
$exp = Read-Host 'Hasło exportera' -AsSecureString
$rdr = Read-Host 'Hasło czytelnika' -AsSecureString
.\Install-ObservabilityStack.ps1 -SqlServer 'localhost,1433' -SqlLogin svc_obs_mssql_exporter -SqlPassword $exp `
    -WebconSqlReaderLogin svc_obs_grafana_reader -WebconSqlReaderPassword $rdr -NonInteractive
```
