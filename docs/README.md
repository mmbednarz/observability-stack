# Dokumentacja – Observability Stack (WEBCON)

Stos do analizy wydajności WEBCON 2026.2+: metryki, ślady i logi z Portalu i Serwisu WEBCON, metryki SQL Server i Windows, dashboardy i alerty w Grafanie. Wszystko jako usługi Windows, instalowane jednym skryptem PowerShell.

> **Zastrzeżenia.** Projekt prywatny, udostępniony jako demonstracja możliwości monitorowania. Nie jest produktem WEBCON, nie jest przez WEBCON rozwijany, wspierany ani zatwierdzony. Brak wsparcia i gwarancji – używasz na własne ryzyko; przed użyciem w środowisku produkcyjnym przetestuj rozwiązanie. Szczegóły: licencja MIT ([LICENSE](../LICENSE)). WEBCON, Grafana i inne nazwy są znakami towarowymi ich właścicieli.

## Zacznij tutaj

| Chcę… | Przeczytaj |
|---|---|
| zainstalować stos na maszynie z WEBCON (dev / test) | [Szybki start](instalacja/01-szybki-start.md) |
| zainstalować stos na osobnej VM | [Tryb zdalny](instalacja/04-tryb-zdalny.md) |
| zaktualizować stos albo zmienić parametry | [Aktualizacja](instalacja/05-aktualizacja.md) |
| usunąć stos | [Odinstalowanie](instalacja/06-odinstalowanie.md) |
| coś nie działa | [Rozwiązywanie problemów](instalacja/07-rozwiazywanie-problemow.md) |
| zacząć korzystać z dashboardów | [Grafana w 10 minut](uzytkownik/01-grafana-w-10-minut.md), potem [Scenariusze](uzytkownik/08-scenariusze.md) |
| zrozumieć alert | [Alerty](uzytkownik/07-alerty.md) |

## Instalacja i utrzymanie

Dla administratora / konsultanta instalującego stos.

1. [Szybki start – all-in-one](instalacja/01-szybki-start.md)
2. [Wymagania i przygotowanie (SQL Server, porty)](instalacja/02-wymagania-i-przygotowanie.md)
3. [Konfiguracja WEBCON (`Set-WebconTelemetry.ps1`)](instalacja/03-konfiguracja-webcon.md)
4. [Tryb zdalny – stos na osobnej maszynie](instalacja/04-tryb-zdalny.md)
5. [Aktualizacja i zmiana parametrów](instalacja/05-aktualizacja.md)
6. [Odinstalowanie](instalacja/06-odinstalowanie.md)
7. [Rozwiązywanie problemów](instalacja/07-rozwiazywanie-problemow.md)
8. [Parametry instalatora](instalacja/08-parametry-instalatora.md)

## Dokumentacja użytkownika

Dla osób tworzących aplikacje WEBCON, które chcą zrozumieć, gdzie aplikacja traci czas i co się w niej psuje. Znajomość Grafany nie jest potrzebna.

1. [Grafana w 10 minut](uzytkownik/01-grafana-w-10-minut.md) – nawigacja, zakres czasu, filtry, drążenie od wykresu do śladu
2. [Pojęcia](uzytkownik/02-pojecia.md) – metryka, ślad, p95; jak WEBCON przekłada się na telemetrię
3. [Dashboard WEBCON – Wydajność](uzytkownik/03-webcon-wydajnosc.md)
4. [Dashboard WEBCON – Utrzymanie](uzytkownik/04-webcon-utrzymanie.md)
5. [Dashboard SQL Server – WEBCON](uzytkownik/05-sql-server.md)
6. [Dashboard Windows – obciążenie hosta](uzytkownik/06-host-windows.md)
7. [Alerty](uzytkownik/07-alerty.md)
8. [Scenariusze – od objawu do przyczyny](uzytkownik/08-scenariusze.md)
9. [Dashboard WEBCON – Dostępność i zaległości](uzytkownik/09-dostepnosc-i-zaleglosci.md)
