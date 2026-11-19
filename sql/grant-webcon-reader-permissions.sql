/*
  Odczyt bieżącego stanu z bazy treści WEBCON przez Grafanę (źródło danych Microsoft SQL Server):
    - ActiveTasks                         - aktywne zadania (TOP użytkowników według liczby zadań)
    - WFAvaiblePaths, WFSteps, WorkFlows, WFDefinitions - nazwy ścieżek, kroków, obiegów i procesów
      (słownik do rankingów ze śladów: PATH_STPID -> STP_ID, STP_WFID -> WF_ID, WF_WFDEFID -> DEF_ID)

  Osobny login tylko do odczytu (NIE login exportera mssql): zapytania w Grafanie może pisać każdy edytor
  dashboardów, a login exportera ma VIEW SERVER STATE (podgląd tekstu zapytań innych sesji).
  Login dostaje wyłącznie SELECT na powyższych tabelach - bez db_datareader i bez dostępu do danych formularzy.

  Uruchamia DBA (sysadmin / securityadmin + db_owner w bazach treści). Skrypt jest idempotentny.
  Po aktualizacji WEBCON uruchom go ponownie - aktualizacja może odtworzyć tabele i usunąć uprawnienia.
*/
USE [master];
GO

DECLARE @login     sysname       = N'svc_obs_grafana_reader';   -- <== nazwa loginu
DECLARE @databases nvarchar(max) = N'WEBCON_Content';           -- <== bazy treści WEBCON, oddzielone przecinkami

-- Utworzenie loginu (jeśli nie istnieje) - hasło ustaw ręcznie i zapisz w C:\Observability\secrets (Set-SecretFile):
-- CREATE LOGIN [svc_obs_grafana_reader] WITH PASSWORD = N'<silne_haslo>', CHECK_POLICY = ON, DEFAULT_DATABASE = [master];

IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = @login)
BEGIN
    RAISERROR(N'Login %s nie istnieje - utwórz go (CREATE LOGIN wyżej) i uruchom skrypt ponownie.', 16, 1, @login);
    RETURN;
END;

DECLARE @db sysname, @exec nvarchar(400), @sql nvarchar(max);
DECLARE dbs CURSOR LOCAL FAST_FORWARD FOR
    SELECT LTRIM(RTRIM(value)) FROM STRING_SPLIT(@databases, N',') WHERE LTRIM(RTRIM(value)) <> N'';
OPEN dbs;
FETCH NEXT FROM dbs INTO @db;
WHILE @@FETCH_STATUS = 0
BEGIN
    IF DB_ID(@db) IS NULL
        RAISERROR(N'Baza %s nie istnieje - pominięta.', 10, 1, @db) WITH NOWAIT;
    ELSE
    BEGIN
        SET @exec = QUOTENAME(@db) + N'.sys.sp_executesql';
        SET @sql =
            N'IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = ' + QUOTENAME(@login, '''') + N') ' +
            N'CREATE USER ' + QUOTENAME(@login) + N' FOR LOGIN ' + QUOTENAME(@login) + N';' +
            N'GRANT SELECT ON dbo.ActiveTasks    TO ' + QUOTENAME(@login) + N';' +
            N'GRANT SELECT ON dbo.WFAvaiblePaths TO ' + QUOTENAME(@login) + N';' +
            N'GRANT SELECT ON dbo.WFSteps        TO ' + QUOTENAME(@login) + N';' +
            N'GRANT SELECT ON dbo.WorkFlows      TO ' + QUOTENAME(@login) + N';' +
            N'GRANT SELECT ON dbo.WFDefinitions  TO ' + QUOTENAME(@login) + N';';
        EXEC @exec @sql;
        RAISERROR(N'Baza %s: uprawnienia nadane.', 10, 1, @db) WITH NOWAIT;
    END;
    FETCH NEXT FROM dbs INTO @db;
END;
CLOSE dbs;
DEALLOCATE dbs;
GO

/*
  Weryfikacja (jako DBA, w bazie treści) - powinny zwrócić dane, a ostatnie zapytanie błąd uprawnień:

  USE [WEBCON_Content];
  EXECUTE AS LOGIN = 'svc_obs_grafana_reader';
      SELECT TOP 10 TSK_User, TSK_UserName, COUNT(*) AS zadania
      FROM dbo.ActiveTasks WHERE TSK_IsFinished = 0 AND TSK_IsDeleted = 0
      GROUP BY TSK_User, TSK_UserName ORDER BY zadania DESC;
      SELECT TOP 5 PATH_ID, PATH_Name FROM dbo.WFAvaiblePaths;
      SELECT TOP 1 * FROM dbo.WFElements;   -- oczekiwany błąd: The SELECT permission was denied
  REVERT;
*/
