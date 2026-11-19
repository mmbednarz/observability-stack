# Konfiguracja WEBCON (`Set-WebconTelemetry.ps1`)

WEBCON 2026.2+ ma wbudowaną obsługę OpenTelemetry, ale domyślnie nie wysyła danych. Skrypt `scripts\Set-WebconTelemetry.ps1` włącza eksport do lokalnego Alloy (`http://localhost:4318`).

## Co zmienia skrypt

1. Znajduje w `C:\Program Files\WEBCON` i `C:\Program Files (x86)\WEBCON` pliki `appsettings.json` / `appsettings.Production.json` z sekcją `OpenTelemetry` (zwykle Portal i Serwis). Gdy w katalogu jest `appsettings.Production.json`, zmienia tylko jego.
2. W sekcji `OpenTelemetry`:
   - włącza `Metrics`, `Tracing`, `Logs`,
   - ustawia eksporter OTLP/HTTP na `http://localhost:4318/v1/metrics|traces|logs`,
   - wyłącza inne eksportery w tych sekcjach (chyba że `-KeepOtherExporters`),
   - włącza śledzenie zapytań SQL (`SqlTracing`) – krótkie zapytania odrzuca potem Alloy (domyślnie < 1 s).
3. Ustawia zmienne środowiskowe `OTEL_*` (exemplary metryk, limit zdarzeń w spanie) oraz znacznik komponentu `OTEL_RESOURCE_ATTRIBUTES=webcon.component=…` (inne atrybuty w tej zmiennej zostają):
   - Serwis – w rejestrze usługi Windows (`webcon.component=service`),
   - Portal (IIS) – w `web.config` (`<aspNetCore><environmentVariables>`, `webcon.component=portal`).

   Na podstawie znacznika Alloy nadaje usługom stałe nazwy `Portal` i `WebCon.WorkFlow`, których używają dashboardy i alerty – niezależnie od `ServiceName` w appsettings WEBCON (bywa różny w zależności od instalacji). Nazwa z WEBCON zostaje w atrybucie `webcon.service.name.original`.
4. Restartuje Serwis WEBCON; zapis `web.config` restartuje aplikację Portalu.

Przed każdą zmianą tworzy kopię pliku: `appsettings.Production.json.bak-20261106101500`, `web.config.bak-…`.

## Użycie

```powershell
# podgląd – nic nie zmienia
.\scripts\Set-WebconTelemetry.ps1 -WhatIf

# zmiana (pyta o potwierdzenie, restartuje WEBCON)
.\scripts\Set-WebconTelemetry.ps1
```

| Parametr | Kiedy użyć |
|---|---|
| `-SqlTracing Threshold` (domyślnie) / `All` / `Off` | śledzenie zapytań SQL: wolne (próg instalatora), wszystkie, wyłączone. `All` wymaga też instalatora z `-SqlSpanThresholdSeconds 0` |
| `-AppSettingsPath <plik>` | zmiana tylko wybranych plików |
| `-SearchRoot <katalog>` | WEBCON w niestandardowym katalogu (domyślnie `Program Files\WEBCON` i `Program Files (x86)\WEBCON`) |
| `-NoRestart` | zmiana bez restartu – zadziała po najbliższym restarcie WEBCON |
| `-RestartIis` | pełny `iisreset` zamiast restartu samej aplikacji |
| `-Force` | bez pytania o potwierdzenie (skrypty automatyczne) |
| `-DisableLogs` | bez wysyłania logów |

Instalator może uruchomić skrypt sam: `Install-ObservabilityStack.ps1 … -ConfigureWebcon`.

## Sprawdzenie

- `.\Test-ObservabilityStack.ps1` → sekcja „Dane z WEBCON i hosta”: `OTLP źródło: WebCon.WorkFlow` (Serwis), `OTLP źródło: Portal` i `Nazwy usług WEBCON znormalizowane (webcon.component)`.
- `[WARN] Usługa WEBCON o niestandardowej nazwie …` albo `… bez znacznika webcon.component` – WEBCON wysyła telemetrię bez znacznika (np. skonfigurowany ręcznie). Uruchom skrypt ponownie; gdy nie można, użyj awaryjnego mapowania po nazwie: instalator z `-WebconPortalServiceName` / `-WebconServiceServiceName` ([parametry](08-parametry-instalatora.md)).
- Portal pojawia się dopiero po pierwszym żądaniu (otwórz Portal w przeglądarce); metryki WEBCON przychodzą co 60 s.

## Wycofanie zmian

Przywróć kopie i zrestartuj WEBCON:

```powershell
$dir = 'C:\Program Files\WEBCON\WEBCON BPS WorkFlow Service'
Get-ChildItem $dir -Filter 'appsettings.Production.json.bak-*' | Sort-Object Name | Select-Object -Last 1 |
    Copy-Item -Destination (Join-Path $dir 'appsettings.Production.json') -Force
Restart-Service 'WebCon WorkFlow Service'
```

Analogicznie dla katalogu Portalu (`WEBCON BPS Portal`: `appsettings.Production.json` i `web.config`). Wybierz kopię sprzed **pierwszego** uruchomienia skryptu (najstarszą), jeśli skrypt był uruchamiany kilka razy.

## Znane problemy WEBCON 2026.2.5

| Objaw | Przyczyna / obejście |
|---|---|
| WEBCON nie startuje po ręcznej edycji appsettings | `"Headers": ""` w eksporterze wywraca start (IndexOutOfRangeException) – skrypt nigdy nie zapisuje pustego `Headers`. |
| Każdy log dwa razy | drugi sink z domyślną konfiguracją wysyła logi jako `unknown_service:…` – Alloy je odrzuca. |
| Dane połączenia z bazą w śladach | Alloy usuwa ze spanów atrybut `webcon.db.cs` (dane połączenia z bazą), smoke test to sprawdza. |
| Serwis nie startuje w 30 s (zdarzenie 7009) | start Serwisu bywa bliski limitowi SCM – występuje także bez telemetrii; ponów start |
