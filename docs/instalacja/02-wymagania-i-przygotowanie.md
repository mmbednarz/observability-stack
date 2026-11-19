# Wymagania i przygotowanie

## Serwer

| Wymaganie | Szczegóły |
|---|---|
| System | Windows Server 2019+ (zweryfikowano 2025) lub Windows 10/11 (zweryfikowano 11). Wymagany `tar.exe` (jest w systemie od Windows 10 1803 / Server 2019) |
| PowerShell | Windows PowerShell 5.1 (wbudowany) lub PowerShell 7+ |
| Uprawnienia | administrator lokalny – instalacja usług Windows, zapis w `C:\Observability`, odczyt sekretów |
| Internet | `github.com`, `objects.githubusercontent.com`, `dl.grafana.com`, `grafana.com` (dashboardy społecznościowe). Proxy: ustaw w systemie przed instalacją |
| Dysk | ~1 GB binarki + dane: zależnie od ruchu i retencji, na dev zwykle < 10 GB |
| Pamięć | ok. 2–3 GB RAM dla wszystkich usług stosu (Alloy ma limit 1 GiB, parametr `-AlloyMemoryLimit`) |
| WEBCON | **2026.2+** (Portal i Serwis). 2026.1 nie jest wspierany – inne nazwy spanów, panele oparte o ślady byłyby puste |

### Porty (tylko `127.0.0.1`)

| Port | Komponent | Port | Komponent |
|---|---|---|---|
| 3000 | Grafana | 9090 | Prometheus |
| 4317 / 4318 | Alloy – odbiór OTLP (gRPC / HTTP) od WEBCON | 9096 | Loki gRPC |
| 12345 | Alloy – UI | 3100 | Loki HTTP |
| 3200 | Tempo HTTP | 9097 / 14317 / 7947 | Tempo gRPC / OTLP / memberlist |

Instalator sprawdza porty przed instalacją i wypisuje proces, który zajmuje port (np. lokalny Jaeger, Seq albo inny collector OTLP). W trybie lokalnym nie są potrzebne reguły zapory.

## SQL Server

Metryki SQL Server i panele z bazy WEBCON są opcjonalne. Potrzebne są **dwa osobne loginy SQL** (uwierzytelnianie SQL, nie Windows):

### 1. Login exportera metryk – `svc_obs_mssql_exporter`

Zbiera metryki serwera (obciążenie, oczekiwania, blokady, I/O, pamięć). Potrzebuje tylko `VIEW SERVER STATE` i `VIEW ANY DEFINITION` – **bez** dostępu do danych WEBCON i bez `sysadmin`.

DBA wykonuje w SSMS:

```sql
CREATE LOGIN [svc_obs_mssql_exporter] WITH PASSWORD = N'<silne_haslo>', CHECK_POLICY = ON, DEFAULT_DATABASE = [master];
-- następnie skrypt z repozytorium:
-- sql\grant-sql-exporter-permissions.sql
```

Sprawdzenie loginu bez instalacji: `.\scripts\Test-SqlExporterLogin.ps1`.

### 2. Login Grafany do bazy treści – `svc_obs_grafana_reader`

Dashboard „WEBCON – Utrzymanie” pokazuje **nazwy** ścieżek i procesów (ślady zawierają tylko ID) oraz bieżące aktywne zadania. Login dostaje `SELECT` wyłącznie na 5 tabelach: `ActiveTasks`, `WFAvaiblePaths`, `WFSteps`, `WorkFlows`, `WFDefinitions` – bez dostępu do danych formularzy.

```sql
CREATE LOGIN [svc_obs_grafana_reader] WITH PASSWORD = N'<silne_haslo>', CHECK_POLICY = ON, DEFAULT_DATABASE = [master];
-- następnie skrypt z repozytorium (w nagłówku ustaw nazwy baz treści, domyślnie WEBCON_Content):
-- sql\grant-webcon-reader-permissions.sql
```

> Aktualizacja WEBCON może odtworzyć tabele i usunąć uprawnienia – po aktualizacji WEBCON DBA uruchamia ten skrypt ponownie.

Dlaczego dwa loginy: zapytania do źródła danych w Grafanie może pisać każdy edytor dashboardów, a login exportera widzi tekst zapytań innych sesji (`VIEW SERVER STATE`). Login Grafany ma więc minimalny zakres.

### 3. Metryki z bazy treści (opcjonalnie)

Zaległości, których nie widać w telemetrii WEBCON: przeterminowane timeouty, akcje cykliczne z błędem, kolejka maili, rozmiary tabel kolejek i logów (dashboard „WEBCON – Dostępność i zaległości”, alerty D1–D3). Włączane parametrem instalatora `-WebconDbMetrics $true`, wymagają metryk SQL (login exportera).

Login **exportera** (`svc_obs_mssql_exporter`) dostaje użytkownika w bazie treści i `SELECT` **wyłącznie na kolumnach** używanych w zapytaniach (ID, statusy, liczniki, daty) – bez treści maili i formularzy. DBA wykonuje skrypt z repozytorium (w nagłówku ustaw login i nazwy baz treści):

```sql
-- sql\grant-webcon-db-metrics.sql
DECLARE @login     sysname       = N'svc_obs_mssql_exporter';
DECLARE @databases nvarchar(max) = N'WEBCON_Content';
```

Brak uprawnień nie przerywa instalacji – instalator wypisuje ostrzeżenie, a metryki pojawią się po nadaniu uprawnień (bez ponownej instalacji). Po aktualizacji WEBCON uruchom skrypt ponownie.

### SQL Server Express – włączenie TCP

Exporter łączy się z SQL Server **tylko po TCP**. SQL Server Express ma domyślnie wyłączone TCP i usługę SQL Browser, więc adres `localhost\SQLEXPRESS` nie zadziała. Włącz TCP ze stałym portem:

1. **SQL Server Configuration Manager** → *SQL Server Network Configuration* → *Protocols for SQLEXPRESS*.
2. **TCP/IP** → *Enabled* = **Yes**.
3. *TCP/IP* → *Properties* → zakładka **IP Addresses** → sekcja **IPAll**: *TCP Dynamic Ports* = puste, *TCP Port* = **1433**.
4. Zrestartuj usługę **SQL Server (SQLEXPRESS)** – to przerywa połączenia, w tym WEBCON.
5. Sprawdź: `sqlcmd -S localhost,1433 -E -C -Q "SELECT @@VERSION"`.

Zapora Windows nie jest potrzebna, gdy SQL i stos są na tej samej maszynie. W instalatorze podaj `-SqlServer 'localhost,1433'`.

## Przed instalacją – lista kontrolna

- [ ] PowerShell uruchomiony jako administrator
- [ ] pliki repozytorium rozpakowane i odblokowane (`Unblock-File` na ZIP)
- [ ] (opcjonalnie) loginy SQL utworzone, hasła pod ręką
- [ ] (SQL Express) TCP włączone na porcie 1433
- [ ] okno serwisowe na restart WEBCON (krok `Set-WebconTelemetry.ps1`)

Dalej: [Szybki start, krok 3](01-szybki-start.md#krok-3-uruchom-instalator).
