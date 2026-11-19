# Alerty

Grafana sprawdza co minutę 30 reguł i oznacza problem jako **alert**. Alerty są widoczne **tylko w Grafanie** – nie wysyłają e-maili ani wiadomości Teams (można to dodać później).

## Gdzie je zobaczyć

| Miejsce | Co tam jest |
|---|---|
| Menu → **Alerting → Alert rules** | wszystkie reguły w dwóch folderach: *WEBCON – alerty* i *Stos obserwowalności – alerty*; stan każdej reguły |
| Menu → **Alerting → Active notifications** | aktualnie aktywne alerty |
| Menu → **Alerting → Silences** | wyciszenia (np. na czas planowanych prac) |

## Stany reguły

| Stan | Znaczenie |
|---|---|
| **Normal** | warunek niespełniony – wszystko w porządku |
| **Normal (NoData)** | brak danych – np. maszyna bez SQL Server; **nie** jest problemem (reguły celowo nie alarmują przy braku danych) |
| **Pending** | warunek spełniony, ale jeszcze nie dość długo (np. reguła wymaga 10 min) |
| **Firing** (Alerting) | alert aktywny |
| **Error** | reguła nie mogła się wykonać – zwykle niedziałający Prometheus lub Loki (`DatasourceError`); dotyczy wielu reguł naraz |

Kliknij regułę, aby zobaczyć opis, aktualną wartość, historię stanu i link **View panel** do panelu dashboardu, którego dotyczy.

Ważność (etykieta `severity`): **critical** – reaguj od razu; **warning** – sprawdź w ciągu dnia.

## Reguły WEBCON

| ID | Alert | Kiedy | Ważność | Co zrobić |
|---|---|---|---|---|
| W1 | Wolne przejścia ścieżek (p95) | p95 przejść > 5 s przez 10 min (min. 10 przejść) | warning | [Scenariusz: wolne przejście](08-scenariusze.md#2-przejście-ścieżki-trwa-długo) |
| W2 | Wolny Portal (p95) | p95 Portalu > 3 s przez 10 min (min. 50 żądań) | warning | [Scenariusz: wolny formularz](08-scenariusze.md#1-formularz-otwiera-się-wolno) |
| W3 | Błędy 5xx Portalu | > 5 % odpowiedzi z błędem serwera (min. 10 błędów) przez 5 min | **critical** | *Wydajność → Błędy HTTP według trasy*, *Logi* |
| W4 | Brak heartbeat Serwisu | Serwis działał w ostatnich 24 h, a od 10 min nie daje znaku życia | **critical** | usługa `WebCon WorkFlow Service` – stan, Dziennik zdarzeń; [scenariusz](08-scenariusze.md#4-serwis-nie-przetwarza). Usługa w stanie *Running*, a alert trwa (np. po wstrzymaniu maszyny wirtualnej) = pętla pracy Serwisu stanęła – zrestartuj usługę |
| W5 | Błędy heartbeat / health check | heartbeat lub health check zakończony błędem | warning | logi Serwisu i Portalu; łączność z bazą |
| W6 | Błędy kolejki Serwisu | element kolejki Serwisu nie został przetworzony | warning | *Wydajność → Serwis WEBCON*, logi `WebCon.WorkFlow` |
| W7 | Rosnące zaległości indeksowania Solr | > 1000 elementów zaległości w 30 min i rośnie | warning | *Solr – kolejki indeksowania*; usługa Solr |
| W8 | Błędy źródeł danych | ≥ 5 błędów pobierania danych z jednego źródła w 15 min | warning | *Utrzymanie → Źródła danych zakończone błędem*; [scenariusz](08-scenariusze.md#3-źródło-danych-albo-akcja-rest-zwraca-błędy) |
| W9 | Błędy wywołań zewnętrznych API | ≥ 10 błędów HTTP do jednego serwera w 15 min | warning | *Utrzymanie → Zewnętrzne API* |
| W10 | Skok błędów w logach | ≥ 50 błędów w logach usługi w 10 min | warning | *Wydajność → Logi* |

## Reguły dostępności i zaległości w bazie

Dashboard: [WEBCON – Dostępność i zaległości](09-dostepnosc-i-zaleglosci.md). Reguły D1–D3 działają, gdy włączone są metryki z bazy treści (`-WebconDbMetrics`).

| ID | Alert | Kiedy | Ważność | Co zrobić |
|---|---|---|---|---|
| B1 | Portal niedostępny | sonda `/health` Portalu (albo adres dodatkowy) bez odpowiedzi 200 / stanu Healthy przez 3 min | **critical** | panel *Kod HTTP*: 0 = brak połączenia (IIS, DNS, certyfikat), 5xx / `Unhealthy` = WEBCON (np. brak dostępu do bazy konfiguracyjnej), 401 = patrz [rozwiązywanie problemów](../instalacja/07-rozwiazywanie-problemow.md) |
| B2 | Certyfikat wkrótce wygaśnie | certyfikat adresu wygasa za mniej niż 14 dni | warning | odnów certyfikat powiązania IIS |
| D1 | Zaległe timeouty | przeterminowane timeouty nie zeszły do zera przez 30 min | warning | Serwis ich nie podejmuje – sprawdź alert W4 i [scenariusz](08-scenariusze.md#4-serwis-nie-przetwarza) |
| D2 | Przybywa nieudanych maili | w ostatnich 30 min przybyło maili po ≥ 3 nieudanych próbach (maile po wyczerpaniu prób zostają w kolejce, więc liczy się przyrost) | warning | konfiguracja SMTP, logi Serwisu |
| D3 | Akcje cykliczne z błędem | akcje cykliczne z błędem ostatniego wykonania przez 30 min | warning | Designer Studio (akcje cykliczne), logi Serwisu |

## Reguły SQL Server i hostów

| ID | Alert | Kiedy | Ważność | Co zrobić |
|---|---|---|---|---|
| S1 | Zakleszczenia | wystąpił deadlock (15 min) | warning | [SQL Server → Blokady](05-sql-server.md#blokady) |
| S2 | Długie blokady | sesje zablokowane przez 10 min | warning | jak wyżej; [scenariusz](08-scenariusze.md#5-baza-danych-zwalnia) |
| S3 | Presja pamięci SQL | Page Life Expectancy < 300 s przez 15 min | warning | [SQL Server → Pamięć](05-sql-server.md#pamięć) |
| H1 | CPU hosta | > 90 % przez 15 min | warning | [Host → Procesy](06-host-windows.md#procesy-webcon-iis-sql-server-stos) – który proces |
| H2 | Pamięć hosta | > 90 % przez 15 min | warning | [Host → Pamięć](06-host-windows.md#pamięć) |
| H3 / H4 | Mało miejsca na dysku | < 10 % (H3, warning) / < 5 % (H4, critical) | warning / **critical** | zwolnij miejsce; logi, kopie zapasowe, pliki tymczasowe |

## Reguły stosu obserwowalności

Dotyczą samego narzędzia – czy dane w ogóle są zbierane.

| ID | Alert | Kiedy | Ważność | Co zrobić |
|---|---|---|---|---|
| O1 | Komponent stosu nie odpowiada | usługa `obs-*` przestała odpowiadać | **critical** | [Rozwiązywanie problemów](../instalacja/07-rozwiazywanie-problemow.md) |
| O2 | Host przestał wysyłać metryki | metryki hosta były w ostatnich 24 h, od 10 min ich nie ma | **critical** | Alloy / agent na hoście; po wznowieniu wstrzymanej VM alert jest oczekiwany i sam ustępuje |
| O3 | Brak telemetrii WEBCON | Portal / Serwis wysyłał dane, od 15 min przestał | **critical** | WEBCON zatrzymany? konfiguracja nadpisana aktualizacją WEBCON? (Portal pod IIS bez ruchu też przestaje wysyłać) |
| O4 | Tempo – błędy zapytań | zapytania o ślady kończą się błędem | warning | [uszkodzony indeks Tempo](../instalacja/07-rozwiazywanie-problemow.md#uszkodzony-indeks-tempo) |
| O5 | Tempo – limit serii spanmetrics | > 80 % limitu (krytyczny, gdy limit przekroczony) | warning / **critical** | bardzo dużo ścieżek / akcji – zgłoś administratorowi stosu |
| O6 | Alloy – odrzucona lub niewysłana telemetria | Alloy nie przyjmuje lub nie zapisuje danych przez 5 min | warning | logi Alloy (Dziennik zdarzeń), miejsce na dysku |
| O7 | Mało miejsca na dysku danych stosu | < 15 % na woluminie `C:\Observability\data` | **critical** | skróć retencję lub zwolnij miejsce |

## Wyciszanie

Na czas planowanych prac (aktualizacja WEBCON, restart serwera):

1. **Alerting → Silences → New silence**.
2. Czas trwania (np. 2 h) i warunek, np. `severity = critical` albo `alertname = W4 Brak heartbeat Serwisu`.
3. Komentarz (powód) → **Save silence**.

## Zmiana progów

Reguły są w repozytorium (`config-templates/grafana/provisioning/alerting/`) i w Grafanie są tylko do odczytu. Zmiana progu = zmiana pliku w repozytorium i ponowna instalacja ([Aktualizacja](../instalacja/05-aktualizacja.md)).
