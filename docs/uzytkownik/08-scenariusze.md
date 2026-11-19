# Scenariusze – od objawu do przyczyny

Przepisy krok po kroku dla typowych zgłoszeń. Każdy zaczyna się od objawu („użytkownicy mówią, że…”), a kończy na konkretnym obiekcie w WEBCON Designer Studio (formularz, ścieżka, reguła, źródło danych, akcja) albo na zasobie serwera.

Podstawy nawigacji (zakres czasu, exemplary, widok śladu): [Grafana w 10 minut](01-grafana-w-10-minut.md#drążenie-od-wykresu-do-przyczyny).

---

## 1. Formularz otwiera się wolno

**Objaw:** „Otwarcie wniosku trwa kilka sekund”. Alert W2.

1. **WEBCON – Wydajność**, zakres obejmujący zgłoszony moment (np. *Last 3 hours*; przybliż wykres zaznaczeniem).
2. Rząd **Stan**: *p95 HTTP Portalu* żółty / czerwony? Jeśli tak – problem dotyczy wielu użytkowników. Jeśli zielony – problem jest punktowy (jeden formularz / użytkownik).
3. Rząd **Portal → Czas odpowiedzi Portalu**: rośnie **p50** (wolne wszystko → krok 7) czy tylko **p95 / p99** (wolne wybrane operacje → krok 4)?
4. Rząd **Formularze i przejścia → Etapy obsługi formularza (zakres dashboardu)**: który etap ma największe p95 – reguły i wartości domyślne (`rules_and_defaults.apply`), budowa modelu JS, źródła danych?
5. Rząd **Gdzie ucieka czas → Ładowanie formularza według procesu i kroku**: znajdź proces i krok z najwyższym p95 (ID procesu / kroku = Designer Studio). Kliknij ID → ślady.
6. W śladzie szukaj najdłuższego paska najgłębiej w drzewie:
   - `webcon.data_source.data.load` – źródło danych (atrybut `webcon.data_source.id`) → scenariusz 3, jeśli pod spodem jest wolny span HTTP; wolny span SQL → zapytanie źródła do optymalizacji,
   - `webcon.rule.execute` – reguła (`webcon.rule.id`) – np. reguła wykonywana dla każdego wiersza listy pozycji,
   - span SQL (`SELECT [...]`) – atrybut `db.query.text` pokazuje zapytanie.
7. Wolne wszystko: **Runtime .NET** (CPU, pule wątków, GC), dashboardy **Windows – obciążenie hosta** i **SQL Server** (linki w prawym górnym rogu – zakres czasu zostaje).

**Przykład (ilustracyjny):** formularz kroku „Weryfikacja” otwiera się 4 s. Ślad: `element.model.load` 3,9 s → `rules_and_defaults.apply` 3,6 s → 12 × `webcon.data_source.data.load` (`data_source.id = 58`, typ `WebServiceREST`) po 0,3 s. Źródło danych REST jest wywoływane osobno dla każdego z 12 pól. Rozwiązanie: jedno wywołanie źródła z cache albo pola wypełniane jedną regułą.

---

## 2. Przejście ścieżki trwa długo

**Objaw:** „Po kliknięciu »Zatwierdź« długo się kręci”. Alert W1.

1. **WEBCON – Wydajność → Stan**: *p95 przejścia ścieżki*.
2. **Gdzie ucieka czas → Ścieżki – najdłuższe przejścia**: ID ścieżki z najwyższym p95 lub łącznym czasem. Nazwę ścieżki, kroku i procesu podaje dashboard **WEBCON – Utrzymanie → Ścieżki – TOP 10** (z bazy).
3. Kliknij ID ścieżki → ślady przejść → wybierz najdłuższy.
4. W śladzie: pod `webcon.elements_management.path.transitions` są akcje (`webcon.action.execute`, atrybut `webcon.action.name`), reguły, zapis (SQL). Najdłuższy element to kandydat:
   - akcja REST / SOAP – czas zewnętrznego systemu (span HTTP pod akcją),
   - akcja „Start workflow” / podprocesy – przejścia w podprocesach,
   - SQL – blokady (scenariusz 5) albo ciężkie zapytanie.
5. **Utrzymanie → Ścieżki TOP 10 – średni czas przejścia dziennie**: od kiedy jest wolno? Porównaj z datą publikacji aplikacji.

**Wskazówka:** akcja wywołująca zewnętrzne API w trakcie przejścia wydłuża transakcję bazy – inne przejścia czekają na blokady. Rozważ przeniesienie wywołania do akcji asynchronicznej / Serwisu.

---

## 3. Źródło danych albo akcja REST zwraca błędy

**Objaw:** „Lista wyboru jest pusta”, „Akcja nie wysłała danych do systemu X”. Alerty W8, W9.

1. **WEBCON – Utrzymanie → Zewnętrzne API wołane przez WEBCON** (zakres: dzień / tydzień).
2. **Serwery docelowe – TOP 10**: który serwer ma błędy (% błędów) i jak długo odpowiada (p95).
3. **Błędy według serwera i typu** – rodzaj błędu:
   - `404` / `401` / `403` – konfiguracja w WEBCON (adres, uwierzytelnienie),
   - `500`–`599` – problem po stronie systemu zewnętrznego,
   - `connection_error` ~21 s – serwer nie odpowiada (zapora, zły adres IP),
   - `name_resolution_error` – zła nazwa hosta.
4. **Źródła danych zakończone błędem**: ID i nazwa źródła → Designer Studio. **Pokaż logi** – pełna treść błędu.
5. **Akcje z błędem wywołania HTTP**: ID i nazwa akcji. **Pokaż ślady** – w śladzie span HTTP z adresem i kodem odpowiedzi.
6. **Błędy na godzinę według serwera i typu**: od kiedy? Nagły początek = zmiana po stronie systemu zewnętrznego albo publikacja aplikacji.

**Przykład (dane testowe dev):** źródło 66 – p95 21 s, `connection_error` do `10.255.255.1` (adres, który nie odpowiada). Każde otwarcie formularza z tym źródłem czeka 21 s. Akcja 6 (`httpbin.org/status/500`) – 100 % błędów `500`; WEBCON kończy przejście mimo błędu, więc użytkownik go nie widzi.

---

## 4. Serwis nie przetwarza

**Objaw:** „Timery się nie wykonują”, „Wyszukiwarka nie znajduje nowych dokumentów”, „Synchronizacja użytkowników nie działa”. Alerty W4, W6, W7, O3.

1. **WEBCON – Wydajność → Stan**: *Serwis żyje* (czerwony = Serwis nie wysyła heartbeat), *Błędy kolejki Serwisu*, *Solr – przyrost zaległości*, *Uruchomienia procesów*.
2. *Serwis żyje* czerwony: usługa `WebCon WorkFlow Service` (services.msc) – zatrzymana? Dziennik zdarzeń → Application / System. Po starcie Serwisu kafelek zmieni kolor w ciągu 5 min.
   - Usługa działa (*Running*), a heartbeat nie wraca: pętla pracy Serwisu stanęła. Zaobserwowane po wstrzymaniu maszyny wirtualnej (skok zegara w Dzienniku System, źródło Kernel-General, zdarzenie 1): Serwis nadal odpowiadał na `/health`, ale przestał wysyłać heartbeat i wykonywać timery. Naprawa: restart usługi.
3. Rząd **Serwis WEBCON**:
   - *Kolejki Serwisu – błędy według roli* – która rola (np. `SolrElementQueue`, `UserSynchronization`),
   - *Solr – kolejki indeksowania* – linia „dodane” trwale nad „przetworzone” = zaległości rosną,
   - *Timery i akcje cykliczne* – wykonania / min (gwałtowny wzrost = zapętlony timer),
   - *Heartbeat i health check* – błędy = problem z bazą lub komunikacją.
4. **Logi**: zmienna *Usługa* = `WebCon.WorkFlow`, panel *Błędy i ostrzeżenia* – treść błędów.

---

## 5. Baza danych zwalnia

**Objaw:** wolne jest wszystko, szczególnie zapis i listy / raporty. Alerty S1–S3.

1. **WEBCON – Wydajność → SQL z perspektywy WEBCON**: *Wolne zapytania SQL* – które zapytania WEBCON przekraczają próg (domyślnie 1 s). Kliknij Trace ID → w której operacji WEBCON (formularz, raport, źródło danych).
2. Dashboard **SQL Server – WEBCON** (link w prawym górnym rogu):
   - **Oczekiwania → Czas oczekiwań wg kategorii** – dominująca kategoria:
     - `Blokady` → rząd *Blokady*; przyczyną zwykle są długie przejścia ścieżek (scenariusz 2) lub masowe operacje,
     - `I/O danych` / `I/O logu` → rząd *I/O baz* i opóźnienie dysku w dashboardzie hosta,
     - `CPU` → *Presja CPU*, ciężkie raporty / zapytania bez indeksów,
     - `Pamiec` → rząd *Pamięć*, *Page life expectancy*.
3. **Zapytania i kompilacje / s**: kompilacje > 10 % = zapytania bez parametrów (np. reguły SQL budujące tekst zapytania).
4. Zapytanie z *Wolne zapytania SQL* przekaż DBA razem z kontekstem (formularz / źródło danych z śladu).

---

## 6. Przyszedł alert – co teraz?

1. **Alerting → Alert rules** → kliknij aktywną regułę: opis, aktualna wartość, **View panel** – panel dashboardu, którego dotyczy.
2. Ustal zakres: od kiedy (historia stanu reguły), czy dotyczy jednej usługi / hosta (etykiety alertu).
3. Przejdź do scenariusza dla reguły – tabela „Co zrobić” w [Alertach](07-alerty.md).
4. Planowane prace? Wycisz alert (**Silences**), zamiast go ignorować.
5. Wiele reguł w stanie **Error** naraz = problem samego stosu (Prometheus / Loki) – [Rozwiązywanie problemów](../instalacja/07-rozwiazywanie-problemow.md).

---

## 7. Przegląd tygodniowy (bez zgłoszenia)

Raz w tygodniu, 15 minut, dashboard **WEBCON – Utrzymanie** (domyślnie 7 dni):

1. **Host**: maksima CPU / pamięci / dysku – czy zbliżamy się do limitów?
2. **Portal – wejścia**: trend użycia (dni robocze, nowe aplikacje).
3. **Akcje – TOP 10**, **Ścieżki – TOP 10**: czy na liście są nowe pozycje? Czy średni czas któregoś obiektu rośnie (wykres dzienny)?
4. **Zadania**: użytkownicy z dużą liczbą zadań / przeterminowanych.
5. **Zewnętrzne API**: nowe błędy, rosnące p95 dostawców.
6. **Alerting → Alert rules**: alerty z tygodnia (historia stanów) – czy progi są sensowne?
