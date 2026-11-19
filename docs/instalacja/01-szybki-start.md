# Szybki start – instalacja na jednej maszynie (all-in-one)

Ten przewodnik prowadzi od zera do działających dashboardów w Grafanie, gdy **WEBCON, SQL Server i stos obserwowalności działają na tej samej maszynie** (typowe środowisko dev / test). Zajmie ok. 30 minut, z czego ok. 10 minut to pobieranie i instalacja komponentów.

Stos na osobnej maszynie (WEBCON i SQL na innych hostach): [Tryb zdalny](04-tryb-zdalny.md).

> **Czego nie musisz znać:** Prometheusa, Grafany, Tempo ani OpenTelemetry. Instalator konfiguruje wszystko sam, a ten przewodnik mówi, co powinieneś zobaczyć po każdym kroku.

## Co zostanie zainstalowane

Pięć usług Windows (nazwy zaczynają się od `obs-`) w katalogu `C:\Observability`:

| Usługa | Do czego służy |
|---|---|
| `obs-alloy` | odbiera telemetrię z WEBCON, zbiera metryki Windows i SQL Server |
| `obs-prometheus` | przechowuje metryki (liczniki, czasy, obciążenie) |
| `obs-tempo` | przechowuje ślady – szczegółowy przebieg pojedynczych operacji WEBCON |
| `obs-loki` | przechowuje logi WEBCON |
| `obs-grafana` | strona WWW z dashboardami i alertami – <http://localhost:3000> |

Wszystkie usługi nasłuchują tylko na `127.0.0.1` – z innego komputera nie będą widoczne (zmiana: [parametry](08-parametry-instalatora.md), `-GrafanaListenAll`).

## Krok 0. Sprawdź wymagania

- Windows Server 2019+ lub Windows 10/11, konto z **uprawnieniami administratora**.
- **WEBCON 2026.2 lub nowszy** (2026.1 nie jest wspierany).
- Dostęp do internetu z serwera (GitHub, dl.grafana.com, grafana.com) – instalator pobiera komponenty.
- ~10 GB wolnego miejsca na dysku `C:`.
- Wolne porty: 3000, 3100, 3200, 4317, 4318, 7947, 9090, 9096, 9097, 12345, 14317 (instalator sprawdza i wskaże konflikt).

Szczegóły i przygotowanie SQL Server: [Wymagania i przygotowanie](02-wymagania-i-przygotowanie.md).

## Krok 1. Pobierz pliki instalacyjne

1. Pobierz najnowszą paczkę `observability-stack-<wersja>.zip` i plik `.sha256` ze strony [Releases](https://github.com/mmbednarz/observability-stack/releases).
2. Sprawdź sumę kontrolną, odblokuj archiwum (inaczej Windows zablokuje skrypty pobrane z internetu) i rozpakuj, np. do `C:\Install`:

   ```powershell
   (Get-FileHash .\observability-stack-0.9.0.zip -Algorithm SHA256).Hash   # porównaj z plikiem .sha256
   Unblock-File .\observability-stack-0.9.0.zip
   Expand-Archive .\observability-stack-0.9.0.zip -DestinationPath C:\Install
   ```

Nie rozpakowuj paczki do katalogu instalacji `C:\Observability` – instalator odmówi (odinstalowanie z `-RemoveFiles` usunęłoby ją razem z danymi).

Po instalacji paczka nie jest potrzebna: instalator kopiuje skrypty do `C:\Observability\app` (smoke test, odinstalowanie, zmiana parametrów, `Set-WebconTelemetry.ps1`, skrypty SQL).

## Krok 2. Przygotuj loginy SQL (zalecane)

Bez tego kroku stos działa, ale **bez** dashboardu SQL Server i bez części paneli dashboardu „WEBCON – Utrzymanie”. Możesz go pominąć i wrócić do niego później (instalator uruchomiony ponownie doda SQL).

Potrzebne są dwa loginy SQL – szczegóły i skrypty dla DBA: [Wymagania i przygotowanie → SQL Server](02-wymagania-i-przygotowanie.md#sql-server).

| Login | Do czego | Skrypt dla DBA |
|---|---|---|
| `svc_obs_mssql_exporter` | metryki SQL Server (obciążenie, blokady, oczekiwania) | `sql\grant-sql-exporter-permissions.sql` |
| `svc_obs_grafana_reader` | odczyt nazw ścieżek i aktywnych zadań z bazy treści WEBCON | `sql\grant-webcon-reader-permissions.sql` |

> **SQL Server Express:** domyślnie ma wyłączony protokół TCP, a instalator łączy się z SQL tylko po TCP. Włącz TCP ze stałym portem 1433 – instrukcja: [Wymagania → SQL Server Express](02-wymagania-i-przygotowanie.md#sql-server-express--włączenie-tcp).

## Krok 3. Uruchom instalator

Otwórz **PowerShell jako administrator** (prawy przycisk → *Uruchom jako administrator*) i przejdź do katalogu z plikami:

```powershell
cd C:\Install\observability-stack-0.9.0
Set-ExecutionPolicy -Scope Process Bypass -Force
```

Wybierz jeden wariant:

```powershell
# a) bez SQL Server (najprostszy)
.\Install-ObservabilityStack.ps1 -SqlServer ''

# b) z metrykami SQL Server – instalator zapyta o login i hasło
.\Install-ObservabilityStack.ps1 -SqlServer 'localhost,1433' -SqlLogin svc_obs_mssql_exporter

# c) jak b) + dane z bazy treści WEBCON dla dashboardu „WEBCON – Utrzymanie” (zalecany)
.\Install-ObservabilityStack.ps1 -SqlServer 'localhost,1433' -SqlLogin svc_obs_mssql_exporter `
    -WebconSqlReaderLogin svc_obs_grafana_reader -WebconContentDatabase WEBCON_Content
```

`localhost,1433` to adres instancji SQL w formacie `host,port`. Instancja nazwana na porcie dynamicznym (np. `localhost\SQLEXPRESS`) nie zadziała – patrz uwaga o SQL Express wyżej.

**Co zobaczysz:** kolejne sekcje `==> …` z wierszami `[OK]`. Instalator:

1. sprawdza wolne porty i uprawnienia loginów SQL (przy braku uprawnień wypisze polecenia dla DBA i zatrzyma się),
2. pobiera komponenty i sprawdza ich sumy kontrolne,
3. generuje konfigurację i hasło administratora Grafany,
4. rejestruje i uruchamia usługi `obs-*`.

Na końcu wypisuje podsumowanie z adresami i – **tylko przy pierwszej instalacji** – hasło administratora Grafany:

```
Podsumowanie
    Grafana     http://localhost:3000  (admin / hasło: C:\Observability\secrets\grafana-admin.txt)
                Nowe hasło admina: ************************
```

Zapisz hasło w menedżerze haseł. Komunikaty `Ingester not ready` w trakcie startu Loki / Tempo są normalne – instalator czeka, aż komponenty będą gotowe.

## Krok 4. Skieruj telemetrię WEBCON do stosu

WEBCON domyślnie nie wysyła metryk, śladów ani logów. Skrypt `Set-WebconTelemetry.ps1` włącza to w plikach `appsettings` Portalu i Serwisu. Najpierw podgląd:

```powershell
.\scripts\Set-WebconTelemetry.ps1 -WhatIf
```

Skrypt znajdzie pliki w `C:\Program Files\WEBCON` i wypisze, co zmieni. Następnie właściwa zmiana:

```powershell
.\scripts\Set-WebconTelemetry.ps1
```

Po potwierdzeniu (`T`) skrypt robi kopie plików (`*.bak-<data>`), zmienia konfigurację i **restartuje Serwis WEBCON oraz aplikację Portalu** – zaplanuj to poza godzinami pracy użytkowników. Szczegóły i wycofanie zmian: [Konfiguracja WEBCON](03-konfiguracja-webcon.md).

## Krok 5. Sprawdź, czy wszystko działa

```powershell
.\Test-ObservabilityStack.ps1
```

Smoke test wysyła testowy ślad, log i metrykę i sprawdza, czy dotarły do magazynów danych. Oczekiwany wynik (fragment):

```
==> Przepływ OTLP end-to-end
    [OK]   Tempo: ślad testowy odnaleziony
    [OK]   Loki: log testowy odnaleziony
    [OK]   Prometheus: metryka testowa odnaleziona
==> Dane z WEBCON i hosta (informacyjnie)
    [OK]   OTLP źródło: WebCon.WorkFlow
    [OK]   OTLP źródło: Portal
    [OK]   Metryki webcon_* obecne
    [OK]   mssql exporter: up
==> Alerty
    [OK]   Reguły alertów załadowane: 30
Wynik: OK
```

- `OTLP źródło: Portal` pojawia się dopiero po pierwszym wejściu na Portal po restarcie (IIS uruchamia aplikację przy pierwszym żądaniu). Otwórz Portal w przeglądarce i powtórz test po 2 minutach – WEBCON wysyła metryki co 60 s.
- `[WARN]` przy „pattern ingester” Loki to tylko ostrzeżenie – może trwać do 2 h po starcie.
- Inne problemy: [Rozwiązywanie problemów](07-rozwiazywanie-problemow.md).

## Krok 6. Zaloguj się do Grafany

1. Otwórz <http://localhost:3000>.
2. Użytkownik `admin`, hasło z kroku 3. Gdy go nie masz, odczytaj je w PowerShell jako administrator:

   ```powershell
   Get-Content C:\Observability\secrets\grafana-admin.txt
   ```

3. Zobaczysz ekran domowy **Start** – stan WEBCON w skrócie, odnośniki i aktywne alerty. Wszystkie dashboardy: menu (☰) → **Dashboards**, w folderach:

   | Folder | Dashboard | Od czego zacząć |
   |---|---|---|
   | `webcon` | **WEBCON – Wydajność** | bieżąca wydajność: Portal, formularze, ścieżki, reguły, SQL, Serwis |
   | `webcon` | **WEBCON – Utrzymanie** | przegląd tygodnia: najczęstsze akcje i ścieżki, zadania, zewnętrzne API |
   | `sql` | **SQL Server – WEBCON** | obciążenie i problemy bazy danych |
   | `host` | **Windows – obciążenie hosta** | CPU, pamięć, dyski, procesy |

Pierwsze sensowne wykresy pojawią się po kilkunastu minutach pracy użytkowników w WEBCON. Jak czytać dashboardy: [Grafana w 10 minut](../uzytkownik/01-grafana-w-10-minut.md).

## Co dalej

- Inni użytkownicy Grafany: menu → **Administration → Users and access → Users → New user** (rola *Viewer* wystarcza do oglądania).
- Dostęp do Grafany z innych komputerów: ponowna instalacja z `-GrafanaListenAll` ([Aktualizacja](05-aktualizacja.md#zmiana-parametrów)).
- Po aktualizacji WEBCON: uruchom ponownie `C:\Observability\app\scripts\Set-WebconTelemetry.ps1` ([Aktualizacja](05-aktualizacja.md#po-aktualizacji-webcon)).
- Nowa wersja stosu: [Aktualizacja](05-aktualizacja.md).
