# Dashboard „WEBCON – Utrzymanie”

**Folder:** `webcon` · **Domyślny zakres:** ostatnie 7 dni · **Odświeżanie:** co 5 min

**Do czego:** przegląd tygodniowy dla osoby utrzymującej aplikacje – jak bardzo obciążony jest serwer, ile osób korzysta z Portalu, które **akcje** i **ścieżki** są najwolniejsze (z **nazwami** z bazy), kto ma najwięcej zadań i czy **zewnętrzne systemy** (API wołane przez źródła danych i akcje) działają.

W odróżnieniu od „Wydajności” (diagnostyka bieżąca, techniczna) ten dashboard odpowiada na pytania z przeglądu tygodnia albo spotkania z właścicielem procesu.

**Filtry:**

| Zmienna | Znaczenie |
|---|---|
| *Usługa* | `Portal`, `WebCon.WorkFlow` (Serwis) |
| *Pomiń porty* | porty pomijane w panelach zewnętrznych API (domyślnie `4317|4318` – własna telemetria WEBCON) |
| *Pomiń hosty* | hosty pomijane (domyślnie `localhost` – Solr, moduły Serwisu) |
| *Hosty WEBCON* | nazwy serwerów WEBCON – wywołania Portal → Serwis nie są „zewnętrzne” |

Panele z bazy treści (nazwy ścieżek, zadania) wymagają źródła danych **WEBCON SQL** – bez niego pokazują błąd albo same ID ([instalacja](../instalacja/01-szybki-start.md#krok-3-uruchom-instalator), wariant c).

---

## Host

| Panel | Co pokazuje | Progi |
|---|---|---|
| **CPU – średnio** / **CPU – maksimum** | średnie i najwyższe 5-minutowe obciążenie CPU w tygodniu | 🟢 < 70 % · 🟡 70–90 % · 🔴 > 90 % |
| **Pamięć – maksimum** | najwyższe zajęcie pamięci fizycznej | 🟢 < 70 % · 🟡 70–90 % · 🔴 > 90 % |
| **Najbardziej zajęty dysk** / **Wolne miejsce (min)** | zajętość najpełniejszego woluminu (teraz) | 🟢 < 80 % · 🟡 80–90 % · 🔴 > 90 % |
| **Opóźnienie dysku – maks.** | najgorsze średnie opóźnienie I/O w tygodniu | 🟢 < 20 ms · 🟡 20–50 ms · 🔴 > 50 ms – dysk spowalnia SQL i WEBCON |
| **CPU i pamięć** | przebieg w tygodniu | szczyty o stałych porach = zadania cykliczne, raporty, backup |

**Maksimum na czerwono, średnia na zielono** = krótkie szczyty; zobacz, kiedy wystąpiły (wykres), i porównaj z *Akcje TOP 10 – średni czas dziennie*.

Szczegóły hosta: [Windows – obciążenie hosta](06-host-windows.md).

---

## Portal – wejścia

| Panel | Co pokazuje | Uwagi |
|---|---|---|
| **Otwarcia strony głównej – dziś** | otwarcia strony głównej Portalu od północy | |
| **Logowania – dziś** | logowania od północy | logowanie ≠ wizyta: użytkownik z zapamiętaną sesją nie loguje się ponownie |
| **Unikalni użytkownicy (7 dni)** | unikalni użytkownicy z 7 dni, ale nie wcześniej niż od startu Portalu | restart Portalu (np. recykling puli IIS, aktualizacja) zeruje licznik. Dziennej liczby unikalnych WEBCON nie udostępnia |
| **Unikalni od startu Portalu** | od ostatniego startu procesu | |
| **Otwarcia i logowania dziennie** | słupki na dobę (doby UTC) | trend użycia – dni robocze vs weekend, wdrożenie nowej aplikacji |

---

## Akcje – TOP 10

| Panel | Co pokazuje |
|---|---|
| **Akcje – TOP 10 według średniego czasu** | 10 akcji (ID i nazwa z Designer Studio) o najwyższym średnim czasie: **liczba, średnia, mediana, p95, min, max** |
| **Akcje TOP 10 – średni czas dziennie** | średni czas tych akcji w kolejnych dniach |

**Jak czytać tabelę:**

- **Min / max** są dokładne (ze śladów), **mediana i p95** przybliżone (histogram) – mogą wypaść poza zakres min–max; to nie błąd.
- **Średnia ≫ mediana** = większość wykonań jest szybka, ale zdarzają się bardzo długie (np. timeout zewnętrznego API).
- **Min ≈ max, wysoko** = akcja zawsze wolna – do optymalizacji (np. zapytanie SQL akcji, wywołanie API).
- Kliknij **ID akcji** → ślady wykonań – w śladzie widać, co akcja robiła (HTTP, SQL, start podprocesu).

**Wykres dzienny:** wzrost średniego czasu jednej akcji od konkretnego dnia = zmiana w aplikacji (publikacja) albo w systemie zewnętrznym.

---

## Ścieżki – TOP 10

| Panel | Co pokazuje |
|---|---|
| **Ścieżki – TOP 10 według średniego czasu przejścia** | 10 ścieżek o najwyższym średnim czasie przejścia, z **nazwą ścieżki, kroku, obiegu i procesu** (z bazy treści) |
| **Ścieżki TOP 10 – średni czas przejścia dziennie** | przebieg w kolejnych dniach (ID ścieżki – nazwy w tabeli) |

Czas przejścia obejmuje wszystko, co dzieje się po kliknięciu przycisku ścieżki: walidację, reguły, akcje na ścieżce i przy wejściu do kolejnego kroku, zapis do bazy. Wolną ścieżkę rozbierasz w śladzie (kliknij ID) – zwykle winna jest jedna akcja albo jedno zapytanie.

---

## Zadania – stan bieżący

Dane prosto z bazy treści – **stan teraz**, niezależny od wybranego zakresu czasu.

| Panel | Co pokazuje |
|---|---|
| **Aktywne zadania** | liczba aktywnych zadań i przeterminowanych |
| **Użytkownicy z największą liczbą aktywnych zadań** | TOP 10 użytkowników: zadania, przeterminowane, grupowe (przypisane do grupy – login jest wtedy loginem grupy) |

Zastosowanie: wąskie gardła w procesach (jedna osoba z setkami zadań), zastępstwa, porządki po odejściu pracownika.

---

## Zewnętrzne API wołane przez WEBCON

Wywołania HTTP wychodzące z Portalu i Serwisu: źródła danych i akcje REST / SOAP, uwierzytelnianie, licencje. Wywołania wewnętrzne (Solr, moduły Serwisu, Portal → Serwis) są pomijane filtrami.

| Panel | Co pokazuje | Jak czytać |
|---|---|---|
| **Serwery docelowe – TOP 10 według liczby wywołań** | serwer, liczba wywołań, p95, % błędów, z ilu usług | który system zewnętrzny jest najczęściej wołany i jak szybko odpowiada |
| **Błędy według serwera i typu** | liczba błędów według rodzaju | rodzaje błędów – niżej |
| **Wywołania na godzinę według serwera** | ruch w czasie | |
| **Błędy na godzinę według serwera i typu** | błędy w czasie | od kiedy system zewnętrzny zwraca błędy |
| **p95 czasu odpowiedzi według serwera** | czas odpowiedzi w oknach godzinnych | spowolnienie po stronie dostawcy API |
| **Źródła danych według łącznego czasu** | źródła danych (ID, typ): p95, liczba, łączny czas | kliknij ID → ślad z wywołaniem HTTP i serwerem docelowym |
| **Źródła danych zakończone błędem** | błędy pobierania danych ze źródła (z logów): ID i nazwa źródła, usługa, liczba | źródło do poprawy w Designer Studio albo niedostępny system zewnętrzny. Przycisk **Pokaż logi** – treść błędu |
| **Akcje z błędem wywołania HTTP** | akcje, w których wywołanie HTTP zwróciło błąd | WEBCON może zakończyć akcję „sukcesem” mimo błędu HTTP – tu to widać. Liczba przybliżona. Przycisk **Pokaż ślady** |

**Rodzaje błędów (`error.type`):**

| Wartość | Znaczenie | Typowa przyczyna |
|---|---|---|
| `400`–`499` | system zewnętrzny odrzucił żądanie | zły adres / parametry (404), brak uprawnień (401, 403) – konfiguracja źródła / akcji |
| `500`–`599` | błąd po stronie systemu zewnętrznego | awaria / przeciążenie dostawcy API |
| `connection_error` | nie udało się nawiązać połączenia | serwer wyłączony, zapora, zły port; **czas ~21 s** = timeout połączenia (serwer nie odpowiada), krótki = odmowa połączenia |
| `name_resolution_error` | nie znaleziono nazwy hosta w DNS | literówka w adresie, brak wpisu DNS |

Uwaga: źródło danych, które dostaje odpowiedź 404, nie zawsze zapisuje błąd w logu (WEBCON zwraca pusty wynik) – nie będzie go w *Źródła danych zakończone błędem*, ale błąd widać w panelach HTTP wyżej.

**Przykład:** serwer `httpbin.org:443` – 120 wywołań w tygodniu, 40 % błędów typu `500`. *Akcje z błędem wywołania HTTP* wskazują akcję ID 6. To akcja testowa wywołująca adres zwracający zawsze 500 – w prawdziwej aplikacji: zgłoszenie do właściciela API albo poprawa adresu w akcji.
