# Dashboard WEBCON – Dostępność i zaległości

Folder `webcon`, dashboard **WEBCON – Dostępność i zaległości** (kafelki *Portal dostępny* i *Zaległości w bazie* na ekranie **Start**). Odpowiada na dwa pytania:

1. **Czy Portal odpowiada?** – sonda HTTP co 30 s.
2. **Czy w bazie nie rosną zaległości**, których Serwis nie podejmuje? – odczyt z bazy treści co 60 s.

Telemetria WEBCON (dashboard *WEBCON – Wydajność*) pokazuje to, co Portal i Serwis **wykonują**. Ten dashboard pokazuje to, co **czeka** – np. timeouty po terminie, gdy Serwis stanął.

## Dostępność

| Panel | Jak czytać |
|---|---|
| **Stan** | *Dostępny* / *Niedostępny* dla każdego sprawdzanego adresu (zmienna *Adres* u góry) |
| **Certyfikat – dni do wygaśnięcia** | czerwony < 14 dni (alert B2), pomarańczowy < 30 dni |
| **Kod HTTP** | 200 = OK; 0 = brak odpowiedzi (DNS, połączenie, certyfikat); 302 = przekierowanie (np. na logowanie); 401 = WEBCON nie odpowiada anonimowo; 5xx = błąd aplikacji |
| **Czas odpowiedzi**, **Fazy żądania HTTP** | czas sondy i jego składowe: `resolve` (DNS), `connect`, `tls`, `processing` (czas aplikacji), `transfer` |
| **Dostępność w czasie** | przerwy dostępności na osi czasu |

Co jest sprawdzane:

- **Portal WEBCON** – adresy z powiązań (bindings) witryny IIS Portalu, ścieżka `/health`. Wynik *Dostępny* wymaga odpowiedzi 200 i stanu `Healthy` – WEBCON sprawdza przy tym m.in. dostęp do bazy konfiguracyjnej. Sonda działa na serwerze Portalu: łączy się z adresem z IIS (sprawdza certyfikat dla tej nazwy), a wysyła nagłówek `Host: localhost`, bo WEBCON 2026.2 odpowiada anonimowo na `/health` tylko lokalnie.
- **Adresy dodatkowe** (parametr instalatora `-ProbeUrl`) – np. Portal produkcyjny, load balancer; wymagany kod 2xx.

## Zaległości w bazie

| Panel | Jak czytać |
|---|---|
| **Przeterminowane timeouty** | timeouty elementów po terminie, których Serwis jeszcze nie podjął. Chwilowo > 0 – normalne (Serwis podejmuje je cyklicznie); **utrzymuje się 30 min** – alert D1 |
| **Akcje cykliczne z błędem** | aktywne akcje cykliczne, których ostatnie wykonanie skończyło się błędem (alert D3) |
| **Nowe nieudane maile (30 min)** | ile w ostatnich 30 min przybyło maili po co najmniej 3 nieudanych próbach – > 0 = problem z wysyłką, np. SMTP (alert D2) |
| **Maile wg liczby prób** | kolejka maili wg liczby prób wysłania. Maile po wyczerpaniu prób (zwykle 5) **zostają w kolejce** – duża stała liczba przy 5 próbach to dawne, trwale nieudane maile, nie bieżący problem |
| **Maile w kolejce** | wszystkie maile czekające na wysłanie lub ponowienie |
| **Tabele kolejek** | liczba wierszy tabel kolejek WEBCON (nazwa zawiera `QUEUE`; bez tabel dodatkowych `ZWEBCON_*` spoza schematu WEBCON) – trend rosnący bez spadków = kolejka nie jest przetwarzana |

## Baza

| Panel | Jak czytać |
|---|---|
| **Elementy – zmiana dzienna** | przyrost liczby elementów (wierszy `WFElements`) w ciągu dnia – netto, czyli utworzone minus usunięte |
| **Elementy – łącznie** | liczba elementów w bazie treści |
| **Tabele logów** | największe tabele logów (nazwa zawiera `LOGS`, bez słownika `DicLogSources`; logi administracyjne `AdminWFEventLogs` i `AdminServiceLogs` są w bazie konfiguracyjnej, której stos nie monitoruje) – kandydaci do archiwizacji lub czyszczenia |

Liczby wierszy tabel pochodzą z metadanych SQL Server (bez przeszukiwania tabel), więc mogą nieznacznie odbiegać od `COUNT(*)`.

## Gdy panele są puste

- **Dostępność** – Portal nie został wykryty w IIS (witryna zatrzymana albo stos na osobnej maszynie bez agenta na hoście WEBCON). Smoke test: sekcja „Dane z WEBCON i hosta”, wiersz *Sondy dostępności*.
- **Zaległości / Baza** – metryki z bazy nie są włączone (`-WebconDbMetrics $true`) albo login exportera nie ma uprawnień (`sql\grant-webcon-db-metrics.sql`). Smoke test: wiersz *Metryki z bazy WEBCON*. Szczegóły: [Wymagania – metryki z bazy](../instalacja/02-wymagania-i-przygotowanie.md#3-metryki-z-bazy-treści-opcjonalnie).
