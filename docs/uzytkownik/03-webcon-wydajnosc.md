# Dashboard „WEBCON – Wydajność”

**Folder:** `webcon` · **Domyślny zakres:** ostatnie 6 h · **Odświeżanie:** co 1 min

**Do czego:** bieżąca diagnostyka – czy WEBCON działa szybko, a jeśli nie, to **gdzie** traci czas: Portal, formularz, reguła, źródło danych, akcja, SQL czy Serwis.

**Filtry:** *Usługa* (`Portal`, `WebCon.WorkFlow` = Serwis), *Baza (DB ID)* (baza treści). **Linki** (prawy górny róg): *Windows – obciążenie hosta*, *SQL Server*, *Ślady (Explore)*.

**Adnotacje** (przełączniki obok filtrów) – pionowe linie na wszystkich wykresach:

| Przełącznik | Kolor | Znaczenie |
|---|---|---|
| *Start procesu WEBCON* (domyślnie włączony) | pomarańczowy | start procesu Portalu / Serwisu (restart, recykling puli IIS, start po bezczynności). Skoki czasu odpowiedzi tuż po linii to „zimny start” – ładowanie cache |
| *Oznaczenie cache do odświeżenia* | fioletowy | WEBCON oznaczył cache konfiguracji do odświeżenia (np. publikacja aplikacji w Designer Studio) – następne żądania przeładowują konfigurację |

Rzędy od ogólnego do szczegółowego:

| Rząd | Pytanie |
|---|---|
| [Stan](#stan) | Czy jest problem? (jedno spojrzenie) |
| [Portal – doświadczenie użytkownika](#portal--doświadczenie-użytkownika) | Jak szybko odpowiada Portal i które strony są wolne? |
| [Formularze i przejścia ścieżek](#formularze-i-przejścia-ścieżek) | Ile przejść, jak długo trwają, który etap formularza jest wolny? |
| [Gdzie ucieka czas](#gdzie-ucieka-czas-ścieżki-reguły-źródła-danych) | Która konkretna ścieżka / reguła / źródło danych / akcja? |
| [SQL z perspektywy WEBCON](#sql-z-perspektywy-webcon) | Które zapytania SQL są wolne? |
| [Serwis WEBCON](#serwis-webcon) | Czy Serwis nadąża z kolejkami, timerami, indeksowaniem? |
| [Runtime .NET](#runtime-net) | Czy procesom WEBCON brakuje CPU / pamięci / wątków? |
| [Logi](#logi) | Jakie błędy i ostrzeżenia zapisuje WEBCON? |

---

## Stan

Kafelki – stan w jednym spojrzeniu. Zacznij od kolorów.

| Kafelek | Co pokazuje | Progi | Co zrobić, gdy nie jest zielony |
|---|---|---|---|
| **Żądania Portalu / s** | ile żądań HTTP obsługuje Portal (bez health check) | – (informacyjnie) | punkt odniesienia: wolny Portal przy dużym ruchu ≠ wolny Portal bez ruchu |
| **p95 HTTP Portalu** | 95 % żądań Portalu jest szybszych niż ta wartość | 🟢 < 1 s · 🟡 1–3 s · 🔴 > 3 s | rząd *Portal* → tabela *Trasy według łącznego czasu* |
| **Błędy 5xx** | % odpowiedzi z błędem serwera (wybrane usługi) | 🟢 < 1 % · 🟡 1–5 % · 🔴 > 5 % | *Błędy HTTP według trasy*, rząd *Logi* |
| **Przejścia ścieżek / min** | wszystkie przejścia ścieżek (Portal + Serwis), łącznie z nieudanymi | – | |
| **Przejścia udane** | udane / wszystkie przejścia w zakresie | 🔴 < 95 % · 🟡 95–99 % · 🟢 ≥ 99 % | nieudane przejście = błąd walidacji, reguły, akcji; rząd *Logi*, ślady przejść |
| **p95 przejścia ścieżki** | 95 % przejść jest szybszych niż ta wartość | 🟢 < 2 s · 🟡 2–5 s · 🔴 > 5 s | tabela *Ścieżki – najdłuższe przejścia* |
| **Użytkownicy (7 dni)** | unikalni użytkownicy Portalu z ostatnich 7 dni (od startu aplikacji) | – | restart Portalu zeruje licznik |
| **Kolejka Serwisu / min** | elementy pobierane z kolejek Serwisu | – | |
| **Błędy kolejki Serwisu** | elementy kolejki, których przetwarzanie się nie udało (zakres) | 🟢 0 · 🔴 ≥ 1 | rząd *Serwis WEBCON*, *Logi* (usługa `WebCon.WorkFlow`) |
| **Solr – przyrost zaległości** | dodane do indeksowania minus przetworzone (zakres) | 🟢 ≤ 0 · 🟡 1–99 · 🔴 ≥ 100 | > 0 = indeksowanie nie nadąża; *Solr – kolejki indeksowania* |
| **Serwis żyje** | czy w ostatnich 5 min Serwis wysłał „heartbeat” | 🟢 tak · 🔴 nie | Serwis zatrzymany lub zawieszony – sprawdź usługę `WebCon WorkFlow Service` |
| **Uruchomienia procesów** | ile razy w zakresie startowały procesy WEBCON | 🟡 ≥ 1 | restart = utrata cache, wolniejsze pierwsze żądania; nieplanowane restarty – logi, Dziennik zdarzeń |

---

## Portal – doświadczenie użytkownika

| Panel | Co pokazuje | Jak czytać |
|---|---|---|
| **Żądania / s według grupy tras** | ruch Portalu w grupach: strona główna / nawigacja, formularz, raporty / dashboardy, zadania, inne API | która część Portalu jest najczęściej używana; skok jednej grupy = np. masowe otwieranie raportu |
| **Czas odpowiedzi Portalu (p50 / p95 / p99)** | typowy (p50), wolny (p95) i skrajny (p99) czas odpowiedzi | p50 rośnie = wolne jest wszystko (serwer, SQL); rośnie tylko p95/p99 = wolne są wybrane strony. **Punkty = exemplary** – kliknij punkt wysoko na wykresie, aby otworzyć ślad wolnego żądania |
| **Rozkład czasu odpowiedzi Portalu** | heatmapa: ile żądań trwało ile w danym momencie | jasne pola wysoko = wiele wolnych żądań; pojedyncza „smuga” u góry = cykliczna wolna operacja |
| **Błędy HTTP według trasy** | liczba odpowiedzi 4xx i 5xx na trasę | **5xx** = błąd WEBCON; **401** po wygaśnięciu sesji jest normalne; **404** = brakujący zasób / zły link |
| **Trasy według łącznego czasu** | tabela tras: liczba, p95, łączny czas (liczba × średni czas), % błędów 5xx | **łączny czas** pokazuje, co najbardziej obciąża Portal – trasa wołana 10 000 razy po 0,2 s waży więcej niż 10 razy po 5 s. Kliknięcie trasy otwiera dashboard *ASP.NET Core Endpoint* |
| **Aktywne żądania i kolejka połączeń** | żądania w trakcie obsługi i połączenia czekające w kolejce serwera | rosnąca kolejka = Portal nie nadąża (brak wątków / CPU) – patrz *Runtime .NET* |
| **Otwarcia Portalu i formularzy** | otwarcia strony głównej i formularzy elementów / s | |
| **Użytkownicy Portalu** | unikalni od startu aplikacji i z ostatnich 7 dni | |

**Trasy (`http.route`)** to szablony adresów Portalu z parametrami w nawiasach klamrowych (np. `{controller=Home}/{action=Index}/{id?}`), a nie konkretne adresy – wszystkie otwarcia formularzy różnych elementów trafiają do jednej trasy. Konkretne ID elementu i użytkownika są w śladzie żądania.

---

## Formularze i przejścia ścieżek

| Panel | Co pokazuje | Jak czytać |
|---|---|---|
| **Przejścia ścieżek** | wszystkie, udane i nieudane przejścia / min | nieudane > 0 – sprawdź logi i ślady przejść z błędem |
| **Udane przejścia według rodzaju** | podział: nowy element (`element_new`), sam zapis (`only_save`), źródło wywołania (Portal, Serwis, API) | czy obciążenie to tworzenie nowych elementów, zapisy czy przejścia z Serwisu (np. timery, „Start workflow”) |
| **Czas przejścia ścieżki (p50 / p95 / p99)** | czas przejścia (histogram WEBCON) | punkty = exemplary – ślad konkretnego przejścia |
| **Rozkład czasu przejścia ścieżki** | heatmapa czasów przejścia | |
| **Przejścia w toku, historia, cache modeli** | przejścia trwające w danej chwili, zapisy historii / s, modele elementów w cache | rosnąca liczba przejść w toku = przejścia się blokują (np. blokady SQL) |
| **Etapy obsługi formularza – p95** | p95 kolejnych etapów: pobranie / ładowanie modelu, reguły i wartości domyślne, budowa modelu JS, zapis, przejście, akcje, źródła danych | który **etap** formularza jest wolny |
| **Etapy obsługi formularza (zakres dashboardu)** | tabela etapów: liczba, p95, łączny czas | etap z największym łącznym czasem to najlepszy kandydat do optymalizacji. Etapy zagnieżdżone liczą się wielokrotnie (reguła w ładowaniu modelu zwiększa oba) |

---

## Gdzie ucieka czas (ścieżki, reguły, źródła danych)

Najważniejszy rząd do optymalizacji aplikacji. Tabele liczone są ze **śladów** (TraceQL metrics) albo spanmetrics, dla całego zakresu dashboardu (do 7 dni). Kolumny zwykle: **p95**, **liczba**, **łączny czas**.

| Panel | Co pokazuje | Identyfikator | Drążenie |
|---|---|---|---|
| **Spany WEBCON według łącznego czasu** | wszystkie operacje WEBCON (`webcon.*`) posortowane po łącznym czasie | nazwa spanu | ogólny obraz – co WEBCON robi najdłużej łącznie |
| **Potok MVC Portalu (filtry)** | autoryzacja i filtry żądań Portalu | nazwa spanu | długie `on_authorization` = sprawdzanie uprawnień / aplikacji |
| **Ścieżki – najdłuższe przejścia** | przejścia według ID ścieżki | `webcon.path.id` (ID ścieżki w Designer Studio) | kliknij ID → ślady przejść tej ścieżki → co trwa (akcje, reguły, SQL) |
| **Reguły biznesowe** | wykonania reguł według ID | `webcon.rule.id` | kliknij ID → ślady; nazwa reguły w WEBCON 2026.2.5 nie jest wysyłana – znajdź ID w Designer Studio |
| **Źródła danych** | ładowania danych ze źródeł według ID i typu (SQL, REST, …) | `webcon.data_source.id`, typ | wolne źródło REST = wolne zewnętrzne API; wolne źródło SQL = zapytanie do optymalizacji |
| **Akcje** | wykonania akcji według ID i nazwy | `webcon.action.id`, nazwa | |
| **Ładowanie formularza według procesu i kroku** | czas otwarcia formularza per proces i krok | `webcon.process.id`, `webcon.step.id` | który formularz (krok) otwiera się wolno |
| **Budowa modelu JS formularza – kroki** | etapy budowy modelu formularza po stronie serwera | nazwa kroku | szczegóły dla zaawansowanych |
| **Najwolniejsze żądania (ślady > 2 s)** | ostatnie żądania Portalu / Serwisu dłuższe niż 2 s: trasa, status, login użytkownika | Trace ID | kliknij Trace ID → cały ślad |

**Jak czytać rankingi:**

- **Wysokie p95, mała liczba** – rzadka, ale wolna operacja (np. raport miesięczny). Dotyka niewielu użytkowników.
- **Średnie p95, ogromna liczba** – „tysiąc drobnych cięć”: najwięcej łącznego czasu, największy zysk z optymalizacji.
- **Łączny czas** = liczba × średni czas – najlepsza kolumna do ustalenia priorytetów.
- p95 w tych tabelach jest przybliżone (kubełki = potęgi 2: 0,5 s, 1 s, 2 s, 4 s…) – porównuj rzędy wielkości, a dokładne czasy sprawdzaj w śladach.

**Przykład:** tabela *Źródła danych* pokazuje źródło ID 66 (typ REST), p95 = 21 s, liczba 40. Kliknięcie ID → ślad → pod spanem `webcon.data_source.data.load` jest span HTTP do `10.255.255.1` trwający 21 s ze statusem błędu `connection_error` – serwer docelowy nie odpowiada, WEBCON czeka do limitu czasu połączenia. Rozwiązanie po stronie aplikacji: poprawny adres / timeout w konfiguracji źródła.

---

## SQL z perspektywy WEBCON

Zapytania SQL wykonywane przez WEBCON – z jego punktu widzenia (ile czekał na bazę).

| Panel | Co pokazuje | Jak czytać |
|---|---|---|
| **Wolne zapytania SQL (ponad próg filtra Alloy)** | ostatnie zapytania SQL dłuższe niż próg (domyślnie 1 s): tabela, baza, **pełny tekst zapytania** | kliknij Trace ID → w jakiej operacji WEBCON (formularz, raport, źródło danych) padło zapytanie |
| **Wolne zapytania według operacji** | wolne zapytania pogrupowane po nazwie, np. `SELECT [WFElements]` | która tabela / operacja najczęściej jest wolna |
| **SQL Server – obciążenie** | zapytania (batch requests), transakcje, kompilacje / s | szczegóły: [SQL Server](05-sql-server.md) |
| **SQL Server – oczekiwania (top 5 kategorii)** | na co SQL Server czeka najdłużej | |
| **SQL Server – blokady i pamięć** | zablokowane sesje, najdłuższe czekanie na blokadę, zakleszczenia, Page Life Expectancy | blokady w trakcie wolnych przejść = przejścia czekają na siebie nawzajem |

Zapytania krótsze niż próg **nie są zapisywane** – brak wolnych zapytań w tabeli to dobra wiadomość, a nie błąd.

---

## Serwis WEBCON

| Panel | Co pokazuje | Jak czytać |
|---|---|---|
| **Kolejki Serwisu – pobrane elementy według roli** | elementy przetwarzane przez role Serwisu (np. `SolrElementQueue`, `UserSynchronization`) / s | która rola pracuje; nieznane role = „rola <id>” |
| **Kolejki Serwisu – błędy według roli** | nieudane przetworzenia elementów kolejki | każda wartość > 0 wymaga sprawdzenia logów Serwisu |
| **Czas pracy Serwisu według roli – p95** | jak długo trwa jednostka pracy roli | rosnący czas = rola nie nadąża |
| **Timery i akcje cykliczne** | timery i akcje cykliczne w toku oraz wykonania / min | duża liczba wykonań = zapętlony timer albo masowa operacja |
| **Solr – kolejki indeksowania** | dodane (linia ciągła) vs przetworzone (przerywana) elementy, załączniki, aktywności / min | linia ciągła trwale nad przerywaną = zaległości rosną |
| **Solr – czasy (p95)** | zapytania do Solr, indeksowanie, ekstrakcja tekstu z załączników | wolna ekstrakcja = duże / nietypowe załączniki |
| **Cache bazy – odświeżenia** | odświeżenia cache konfiguracji | skok po publikacji aplikacji jest normalny; częste odświeżanie = skoki czasu odpowiedzi |
| **Cache bazy – czas (p95)** | czas odświeżenia cache | |
| **Heartbeat i health check** | czas heartbeat Portalu / Serwisu i health check; błędy na osi prawej | błędy heartbeat = problem z bazą lub komunikacją Portal ↔ Serwis |

---

## Runtime .NET

Stan procesów WEBCON (Portal, Serwis) od strony .NET. Przydatne, gdy wszystko jest wolne naraz.

| Panel | Co pokazuje | Kiedy reagować |
|---|---|---|
| **CPU procesów WEBCON** | zużycie CPU w rdzeniach (1 = jeden pełny rdzeń) | blisko liczby rdzeni serwera = brak CPU |
| **Pamięć: working set i sterta GC** | pamięć procesu i obiektów .NET | stały wzrost bez spadków = możliwy wyciek / rosnący cache |
| **Pauzy GC** | % czasu, w którym aplikacja stała przez odśmiecanie pamięci | > 5 % = presja pamięci |
| **Kolekcje GC według generacji** | częstotliwość odśmiecania | częste gen2 = dużo długo żyjących obiektów (cache, duże modele) |
| **Pula wątków** | wątki i zadania czekające w kolejce puli | rosnąca kolejka przy stałej liczbie wątków = zagłodzenie puli wątków (wszystko zwalnia) |
| **Wyjątki i rywalizacja o blokady** | wyjątki .NET / s i konflikty blokad / s | skok wyjątków = sprawdź logi |

---

## Logi

| Panel | Co pokazuje | Jak czytać |
|---|---|---|
| **Logi według poziomu** | liczba rekordów logu według usługi i poziomu | skok `error` = zdarzenie do zbadania |
| **Błędy i ostrzeżenia** | rekordy Warning / Error / Fatal | rozwiń rekord – pola `exception_message`, `RequestPath`, `AuthenticatedUserLogin`; przycisk **Otwórz ślad** przy `trace_id` |

Wyszukiwanie w logach: menu panelu **⋮ → Explore** i dopisz filtr, np. `|= "DataSource"` (zawiera tekst).
