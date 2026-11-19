# Pojęcia

## Słownik

| Pojęcie | Znaczenie | Przykład |
|---|---|---|
| **Metryka** | liczba mierzona w czasie, zbierana co minutę | liczba przejść ścieżek, czas odpowiedzi Portalu |
| **Licznik** (counter) | metryka, która tylko rośnie (od startu procesu); na wykresach pokazujemy jej przyrost | `webcon_elements_management_path_transitions_all_total` |
| **… / s, … / min** | tempo – ile zdarzeń na sekundę / minutę, uśrednione w oknie kilku minut | 12 przejść / min |
| **Przyrost w zakresie** | ile zdarzeń było w całym wybranym zakresie czasu (kafelki „zakres dashboardu”) | 3 błędy kolejki Serwisu w ostatnich 6 h |
| **Histogram** | rozkład czasów: ile operacji trwało 0–100 ms, 100–250 ms, … – z niego liczone są percentyle | czas przejścia ścieżki |
| **p50 (mediana)** | połowa operacji była szybsza niż ta wartość – „typowy” czas | p50 = 0,3 s |
| **p95** | 95 % operacji było szybszych, 5 % wolniejszych – czas, którego doświadcza co dwudziesty użytkownik. **Podstawowa miara wydajności** w tych dashboardach | p95 = 2 s → 1 na 20 otwarć trwa ponad 2 s |
| **p99** | 1 % najwolniejszych operacji – pojedyncze skrajne przypadki | |
| **Ślad** (trace) | zapis przebiegu jednej operacji (żądania Portalu, przejścia ścieżki, zadania Serwisu) z czasem każdego kroku | otwarcie formularza elementu 1234 |
| **Span** | jeden krok w śladzie: nazwa, czas trwania, atrybuty, status; spany zagnieżdżają się | `webcon.rule.execute` (reguła 18) w `element.model.load` |
| **Atrybut** | dodatkowa informacja w spanie | `webcon.path.id = 11`, `db.query.text = SELECT …` |
| **Exemplar** | punkt na wykresie metryki powiązany z konkretnym śladem – most z wykresu do szczegółów | romb na wykresie czasu odpowiedzi |
| **Spanmetrics** | metryki (liczba, czas) liczone automatycznie ze spanów – dlatego są wykresy dla reguł, akcji, etapów formularza, mimo że WEBCON nie wysyła takich metryk | `traces_spanmetrics_latency_bucket{span_name="webcon.action.execute"}` |
| **TraceQL metrics** | statystyki liczone bezpośrednio ze śladów w Tempo (tabele „Gdzie ucieka czas”) – działają dla zakresu do 7 dni, p95 jest przybliżone | ranking ścieżek |
| **Log** | komunikat zapisany przez WEBCON (Serilog), z poziomem i często z `trace_id` | `Error getting data for DataSource …` |
| **Poziom logu** | `Information`, `Warning`, `Error`, `Fatal` | |
| **Usługa** (`job`, `service`) | źródło telemetrii: `Portal` (aplikacja WWW pod IIS) albo `WebCon.WorkFlow` (Serwis WEBCON) | |
| **Próg filtra SQL** | spany zapytań SQL krótsze niż próg (domyślnie 1 s) są odrzucane, żeby nie zalać magazynu – w śladach widać tylko **wolne** zapytania | |
| **Retencja** | jak długo dane są przechowywane: metryki 15 dni, ślady 8 dni, logi 7 dni (domyślnie) | |

## Jak WEBCON przekłada się na telemetrię

| Co robisz / co się dzieje w WEBCON | Metryka (wykres) | Span (ślad) | Atrybuty / identyfikatory |
|---|---|---|---|
| użytkownik otwiera stronę Portalu | `http_server_request_duration_seconds` (czas żądania HTTP) | span `server` z `http.route` | `http.route`, `http.response.status_code`, `webcon.user.login` |
| otwarcie formularza elementu | `webcon_…_element_open_total` | `webcon.elements_management.element.model.load` | `webcon.process.id`, `webcon.step.id` |
| przejście ścieżki (przycisk na formularzu, Serwis) | `webcon_elements_management_path_transitions_*` (liczba, udane, czas) | `webcon.elements_management.path.transitions` | `webcon.path.id` = ID ścieżki (WFP_ID) |
| reguła biznesowa / formularza | – (spanmetrics) | `webcon.rule.execute` | `webcon.rule.id` (nazwa w 2026.2.5 pusta) |
| źródło danych (SQL, REST, SOAP, …) | – (spanmetrics) | `webcon.data_source.data.load` + span HTTP / SQL pod spodem | `webcon.data_source.id`, `webcon.data_source.type.name` |
| akcja (REST, „Start workflow”, …) | – (spanmetrics) | `webcon.action.execute` | `webcon.action.id`, `webcon.action.name` |
| wywołanie zewnętrznego API (akcja / źródło REST) | `http_client_request_duration_seconds` | span `client` HTTP | `server.address`, `error.type` |
| zapytanie SQL WEBCON (dłuższe niż próg) | – | span SqlClient, np. `SELECT [WFElements]` | `db.namespace`, `db.query.text` |
| praca Serwisu (kolejki, timery, Solr) | `webcon_service_queue_*`, `webcon_timers_*`, `webcon_solr_queue_*` | `webcon.service.activity`, `webcon.service.heartbeat` | `webcon.service.role.name` |
| błąd w WEBCON | – | span ze statusem error (nie zawsze) | log `Error` z `trace_id` |

> **Ważne:** spany źródeł danych i akcji **nie mają statusu błędu**, nawet gdy wywołanie się nie udało – błąd widać w spanie HTTP pod spodem (`error.type`) i w logach. Dlatego błędy źródeł danych pokazujemy z logów, a błędy akcji – z wywołań HTTP.

Identyfikatory (`path.id`, `rule.id`, `data_source.id`, `action.id`, `process.id`, `step.id`) to te same ID, które widać w **WEBCON Designer Studio** (np. we właściwościach obiektu). Nazwy ścieżek i procesów dashboard „Utrzymanie” pobiera z bazy treści.

## Skąd jest opóźnienie danych

- WEBCON wysyła metryki **co 60 s**, a wykresy uśredniają kilka minut – zmiana obciążenia jest widoczna po 2–5 minutach.
- Ślady i logi są dostępne po kilku sekundach.
- Portal pod IIS po okresie bezczynności jest wyłączany przez IIS – wtedy nie wysyła metryk (przerwy na wykresach to nie awaria).

## Ograniczenia, o których warto wiedzieć

- **p95 jest przybliżone** – liczone z histogramu (kubełków czasu). Dla tabel ze śladów (TraceQL metrics) kubełki to potęgi 2, więc p95 = 1,07 s albo 2,15 s, a nie 1,52 s. Do porównywania, co jest wolniejsze, wystarcza; do dokładnych pomiarów – patrz min / max i pojedyncze ślady.
- **Mało ruchu = mało wiarygodne percentyle.** p95 z 10 operacji to praktycznie najwolniejsza z nich. Patrz zawsze na kolumnę „liczba”.
- **Spany zagnieżdżone liczą się wielokrotnie** w tabelach „łączny czas” – reguła wykonana w ładowaniu formularza zwiększa łączny czas i reguły, i ładowania.
- **Tabele ze śladów obejmują do 7 dni** (limit zapytań Tempo i retencja śladów); dłuższy zakres = błąd albo obcięte wyniki. Na długich zakresach liczą się wolniej.
