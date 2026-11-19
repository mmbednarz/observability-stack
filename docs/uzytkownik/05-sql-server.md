# Dashboard „SQL Server – WEBCON”

**Folder:** `sql` · **Domyślny zakres:** ostatnia 1 h · **Odświeżanie:** co 30 s

**Do czego:** czy baza danych jest przyczyną wolnego WEBCON – obciążenie, na co czeka SQL Server, blokady, dysk, pamięć, rozmiar baz – oraz lista wolnych zapytań wysłanych przez WEBCON.

**Filtr:** *Bazy* (wykresy per baza). Wymaga metryk SQL (`-SqlServer` przy instalacji).

> Dashboard opisuje **całą instancję** SQL Server. Jeśli na instancji działają też inne systemy, ich obciążenie jest tu widoczne.

---

## Przegląd

| Kafelek | Co pokazuje | Progi / kiedy reagować |
|---|---|---|
| **Zapytania / s** | Batch Requests/sec – ogólna miara obciążenia | punkt odniesienia |
| **Połączenia** | aktywne połączenia do wybranych baz | nagły wzrost = wyciek połączeń lub skok ruchu |
| **Page life expectancy** | ile sekund strona danych zostaje w pamięci | 🔴 < 300 s · 🟠 300–1000 s · 🟢 > 1000 s; niskie = za mało pamięci, dużo odczytów z dysku |
| **Pamięć SQL Server** | pamięć zajęta przez SQL Server | |
| **Zablokowane sesje** | żądania czekające teraz na blokadę innej sesji | 🟢 0 · 🟠 ≥ 1 · 🔴 ≥ 5 |
| **Zakleszczenia (zakres)** | deadlocki w zakresie | każdy deadlock = jedna transakcja WEBCON została wycofana (błąd dla użytkownika) |

---

## Obciążenie

| Panel | Jak czytać |
|---|---|
| **Zapytania i kompilacje / s** | kompilacje > 10 % zapytań = plany nie są ponownie używane (zapytania ad hoc, np. z reguł SQL bez parametrów) |
| **Transakcje / s wg bazy** | która baza (treść, konfiguracja, załączniki) jest najbardziej obciążona |
| **Aktywne żądania** | żądania `running` / `runnable` / `suspended`; dużo `suspended` = czekają na zasób (blokady, dysk) |

---

## Oczekiwania – na co czeka SQL Server

Najlepszy sposób, by ustalić, **co** ogranicza bazę:

| Panel | Jak czytać |
|---|---|
| **Czas oczekiwań wg kategorii** | sekundy oczekiwania na sekundę (suma wszystkich wątków); **dominująca kategoria = wąskie gardło** |
| **Średni czas pojedynczego oczekiwania** | długie pojedyncze oczekiwania przy niewielu zdarzeniach = sporadyczne, ale dotkliwe problemy |
| **Presja CPU (signal wait %)** | trwale > 20–25 % = brak CPU dla SQL Server |

| Kategoria | Znaczenie | Co sprawdzić |
|---|---|---|
| `Blokady` | czekanie na blokady innych transakcji | rząd *Blokady*, długie przejścia ścieżek / akcje |
| `I/O danych`, `I/O logu`, `I/O inne` | czekanie na dysk (pliki danych / log transakcji) | rząd *I/O baz*, opóźnienie dysku na [hoście](06-host-windows.md) |
| `CPU` | brak CPU, zapytania równoległe | presja CPU, ciężkie raporty |
| `Pamiec` | czekanie na przydział pamięci | rząd *Pamięć* |
| `Latch`, `Latch bufora` | rywalizacja o wewnętrzne struktury / strony w pamięci | często tempdb albo „gorące” tabele (np. masowe wstawianie) |
| `Siec / klient` | klient (WEBCON) wolno odbiera wyniki | duże wyniki zapytań, np. raporty bez stronicowania |
| `Wywolania OS`, `Inne` | pozostałe | zwykle tło; istotne tylko gdy dominują |

---

## Blokady

| Panel | Jak czytać |
|---|---|
| **Zablokowane sesje** | liczba zablokowanych i najdłuższe bieżące czekanie (oś prawa); próbka co 30 s – krótkie blokady mogą nie być widoczne |
| **Oczekiwania na blokady / s** | żądania blokad, które musiały czekać / przekroczyły limit czasu |
| **Zakleszczenia / min** | szczegóły zakleszczeń: sesja Extended Events `system_health` w SSMS |

Blokady w WEBCON zwykle wynikają z długich transakcji: przejścia ścieżki z wolną akcją (wywołanie API w trakcie transakcji), masowych operacji, ciężkich raportów.

---

## I/O baz

| Panel | Jak czytać |
|---|---|
| **Średnie opóźnienie I/O wg bazy** | dobre wartości: pliki danych < 20 ms, log < 5 ms |
| **Operacje I/O / s wg bazy**, **Przepustowość I/O wg bazy** | która baza najbardziej obciąża dysk |

---

## Pamięć

| Panel | Jak czytać |
|---|---|
| **Pamięć SQL Server** | zajęta stale poniżej docelowej = SQL ma zapas; zajęta = docelowa i niski PLE = za mało pamięci |
| **Page life expectancy** | gwałtowne spadki = bufor wypłukiwany przez duże skany (np. raport bez indeksu) |
| **Przydziały pamięci i bufor** | *Memory Grants Pending* > 0 = zapytania czekają na pamięć; trafienia w buforze powinny być bliskie 100 % |

---

## Bazy danych

| Panel | Jak czytać |
|---|---|
| **Rozmiar danych**, **Rozmiar logu** | rozmiar plików baz |
| **Zapełnienie logu** | 🟠 > 70 % · 🔴 > 90 %; stale wysokie przy modelu odzyskiwania FULL = brak kopii zapasowych logu |
| **Wzrost baz** | tempo przyrostu – planowanie miejsca, efekt archiwizacji |
| **Przyrosty logu** | częste autogrow spowalnia zapisy – większy krok przyrostu / rozmiar początkowy |

---

## Wolne zapytania SQL (ślady WEBCON)

Tabela zapytań SQL dłuższych niż próg (domyślnie 1 s) wysłanych przez WEBCON: baza, **pełny tekst zapytania**, Trace ID. Kliknij Trace ID → zobaczysz, w jakiej operacji WEBCON (otwarcie formularza, raport, źródło danych, akcja) zapytanie się wykonało i kto je wywołał.

To połączenie widoków DBA i twórcy aplikacji: DBA widzi zapytanie, twórca aplikacji – który formularz / źródło danych je generuje.
