# Historia zmian

Format: sekcja na wersję – **Zmiany** oraz **Wymaga działań** (kroki ręczne przy aktualizacji z poprzedniej wersji). Numeracja [SemVer](https://semver.org/lang/pl/): major = zmiana wymagająca ręcznej migracji, minor = nowe funkcje, patch = poprawki.

## [0.9.0] – 2026-11-19

Pierwsze wydanie.

### Zmiany

- Stos obserwowalności jako usługi Windows: Grafana Alloy, Prometheus, Grafana Tempo, Grafana Loki, Grafana (wersje w `versions.psd1`); instalator idempotentny, wszystkie usługi tylko na `127.0.0.1`.
- Telemetria WEBCON 2026.2+ (OTLP): metryki, ślady, logi Portalu i Serwisu; `scripts\Set-WebconTelemetry.ps1` konfiguruje WEBCON. Stałe nazwy usług `Portal` / `WebCon.WorkFlow` niezależnie od `ServiceName` w appsettings.
- Metryki hosta Windows i IIS, metryki SQL Server (dedykowany login), filtr krótkich spanów SQL, usuwanie atrybutu `webcon.db.cs` (dane połączenia z bazą) ze spanów.
- Dashboardy: Start, WEBCON – Wydajność, WEBCON – Utrzymanie, WEBCON – Dostępność i zaległości, Windows – obciążenie hosta, SQL Server – WEBCON.
- Sonda dostępności Portalu (`/health`, adresy z powiązań IIS) i metryki z bazy treści WEBCON (zaległe timeouty, akcje cykliczne, kolejka maili, rozmiary tabel kolejek i logów).
- 30 reguł alertów Grafany (tylko UI).
- Tryb zdalny: stos na osobnej maszynie + paczka agenta dla hostów WEBCON i SQL Server (niezweryfikowany na produkcyjnych hostach).
- Wydania z wersją: paczka ZIP, kopia skryptów w `C:\Observability\app` (smoke test, odinstalowanie, zmiana parametrów bez paczki), ochrona przed obniżeniem wersji (`-AllowDowngrade`) i przed usunięciem obcych plików przy `-RemoveFiles`.

### Wymaga działań

- Instalacje sprzed wydań (klon repozytorium): uruchom instalator z rozpakowanej paczki (`.\Install-ObservabilityStack.ps1 -NonInteractive`). Jeśli repozytorium leży w `C:\Observability`, instalator poprosi o przeniesienie go.
