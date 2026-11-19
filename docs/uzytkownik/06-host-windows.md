# Dashboard „Windows – obciążenie hosta”

**Folder:** `host` · **Domyślny zakres:** ostatnia 1 h · **Odświeżanie:** co 30 s

**Do czego:** czy serwerowi (WEBCON, IIS, SQL Server) brakuje zasobów – CPU, pamięci, dysku, sieci – i który proces je zużywa.

**Filtry:** *Host* (serwer; w trybie zdalnym kilka hostów), *Procesy* (procesy na wykresach rzędu *Procesy*: WEBCON, w3wp, sqlservr, komponenty stosu).

---

## Przegląd

| Kafelek | Co pokazuje | Progi |
|---|---|---|
| **CPU** | średnie obciążenie wszystkich rdzeni | 🟢 < 70 % · 🟠 70–90 % · 🔴 > 90 % |
| **Pamięć zajęta** | pamięć fizyczna w użyciu (bez cache, który system może odzyskać) | 🟢 < 80 % · 🟠 80–92 % · 🔴 > 92 % |
| **Commit** | pamięć zarezerwowana (RAM + plik stronicowania) względem limitu | 🔴 > 95 % = ryzyko braku pamięci (OutOfMemory) |
| **Kolejka procesora** | wątki czekające na CPU | trwale > 2 × liczba rdzeni = brak CPU |
| **Najmniej wolnego miejsca** | najmniejszy % wolnego miejsca na woluminach | 🔴 < 10 % · 🟠 10–20 % · 🟢 > 20 % |
| **Czas od startu** | czas od uruchomienia systemu | nieoczekiwanie krótki = restart serwera |

---

## CPU

| Panel | Jak czytać |
|---|---|
| **Obciążenie CPU wg trybu** | `user` = aplikacje; `privileged` = jądro, sterowniki, antywirus; wysokie `interrupt` / `dpc` = sterowniki sprzętu / sieć |
| **Obciążenie per rdzeń** | jeden rdzeń na 100 %, reszta wolna = operacja jednowątkowa |
| **Kolejka procesora** | jak kafelek, w czasie |
| **Przełączenia kontekstu / s** | gwałtowny wzrost przy stałym obciążeniu = za dużo wątków / rywalizacja o blokady |
| **Procesy i wątki** | stały wzrost wątków = wyciek wątków w którejś aplikacji |

---

## Pamięć

| Panel | Jak czytać |
|---|---|
| **Pamięć fizyczna** | *dostępna* = wolna + cache (standby), który system odda na żądanie |
| **Commit vs limit** | commit blisko limitu = brak pamięci wirtualnej – więcej RAM lub większy plik stronicowania |
| **Stronicowanie z dysku (hard faults)** | **najlepszy sygnał braku RAM**: trwałe odczyty stron z dysku |
| **Page faults / s** | wszystkie page faults (większość jest „miękka” i nieszkodliwa) |
| **Pule jądra** | stały wzrost puli *nonpaged* = wyciek w sterowniku |

SQL Server domyślnie zajmuje prawie całą wolną pamięć – wysokie *Pamięć zajęta* na serwerze z SQL jest normalne, jeśli nie ma *hard faults* i SQL ma ograniczenie `max server memory`.

---

## Dyski

| Panel | Jak czytać |
|---|---|
| **Zajętość dysku** | % czasu, w którym wolumin obsługiwał żądania; trwale ~100 % = dysk nasycony |
| **Opóźnienie odczytu / zapisu** | SSD: < 5 ms dobrze, > 20 ms problem – **kluczowe dla SQL Server** |
| **Kolejka dysku** | żądania czekające na dysk |
| **IOPS**, **Przepustowość** | operacje i bajty na sekundę |
| **Wolne miejsce** | % wolnego miejsca per wolumin |

---

## Sieć

| Panel | Jak czytać |
|---|---|
| **Ruch sieciowy** | bity / s odebrane i wysłane; linia przerywana (oś prawa) = % przepustowości karty |
| **Błędy i odrzucone pakiety** | powinno być 0 |
| **TCP** | połączenia nawiązane, resety, retransmisje (oś prawa, %) – > 1 % retransmisji = problemy z siecią |

---

## Procesy (WEBCON, IIS, SQL Server, stos)

| Panel | Jak czytać |
|---|---|
| **CPU per proces** | udział procesu w całym CPU (100 % = wszystkie rdzenie) – który proces obciąża serwer |
| **Pamięć prywatna (working set)** | stały wzrost bez spadków = wyciek pamięci |
| **I/O per proces** | operacje dysku i sieci |
| **Uchwyty**, **Wątki** | stały wzrost = wyciek |

| Proces | Co to jest |
|---|---|
| `w3wp` | pula aplikacji IIS (proces hostujący Portal) |
| `WebCon.WorkFlow.Bootstrapper` | Portal (pod IIS) i Serwis WEBCON |
| `WebCon.WorkFlow.Service`, `WebCon.WorkFlow.Module.ServiceModuleRunner` | Serwis WEBCON i jego moduły |
| `sqlservr` | SQL Server |
| `alloy`, `prometheus`, `loki`, `tempo`, `grafana` | stos obserwowalności – zwykle kilka % CPU i 1–3 GB RAM łącznie |

---

## IIS

| Panel | Jak czytać |
|---|---|
| **Żądania / s** | żądania do witryn IIS (wszystkie aplikacje, nie tylko Portal) |
| **Bieżące połączenia** | aktywne połączenia do witryny |
| **Odrzucone żądania async I/O / s** | powinno być 0 |

Panele IIS są puste na serwerze bez IIS (np. host SQL w trybie zdalnym).
