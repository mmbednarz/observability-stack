/*
  Uprawnienia loginu exportera mssql (svc_obs_mssql_exporter) do metryk z bazy treści WEBCON
  (config-templates/alloy/webcon-db-queries.yaml, instalator: -WebconDbMetrics).

    - użytkownik loginu w bazie treści (sys.partitions / sys.tables - rozmiary tabel kolejek i logów z metadanych;
      widoczność metadanych daje VIEW ANY DEFINITION z sql/grant-sql-exporter-permissions.sql)
    - SELECT wyłącznie na kolumnach używanych w zapytaniach: ID, statusy, liczniki i daty -
      bez treści maili, formularzy i logów (bez db_datareader)

  Uruchamia DBA (sysadmin / securityadmin + db_owner w bazie treści). Skrypt jest idempotentny.
  Po aktualizacji WEBCON uruchom go ponownie - aktualizacja może odtworzyć tabele i usunąć uprawnienia.
  Najpierw sql/grant-sql-exporter-permissions.sql (login + VIEW SERVER STATE, VIEW ANY DEFINITION).
*/
USE [master];
GO

DECLARE @login     sysname       = N'svc_obs_mssql_exporter';   -- <== login exportera
DECLARE @databases nvarchar(max) = N'WEBCON_Content';           -- <== bazy treści WEBCON, oddzielone przecinkami

IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = @login)
BEGIN
    RAISERROR(N'Login %s nie istnieje - najpierw sql/grant-sql-exporter-permissions.sql.', 16, 1, @login);
    RETURN;
END;

DECLARE @db sysname, @exec nvarchar(400), @sql nvarchar(max), @u nvarchar(300);
SET @u = QUOTENAME(@login);
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
            N'CREATE USER ' + @u + N' FOR LOGIN ' + @u + N';' +
            -- webcon_db_mails
            N'GRANT SELECT (MAIL_AttemptsNumber) ON dbo.WFMails TO ' + @u + N';' +
            -- webcon_db_recurrent_actions_overdue
            N'GRANT SELECT (RAS_TimeLastFailure, RAS_TimeLastSuccess, RAS_ServiceName, RAS_Status, RAS_NextLaunch) ON dbo.WFRecurrentActionsStats TO ' + @u + N';' +
            -- webcon_db_timeouts_overdue
            N'GRANT SELECT (ETM_TIMID, ETM_ServiceName, ETM_Status, ETM_ExpireTime, ETM_OccurrenceErrorsCount, ETM_OccurrenceCount, ETM_LastAttemptTime, ETM_AttemptsNumber) ON dbo.WFElementTimeouts TO ' + @u + N';' +
            N'GRANT SELECT (TIM_ID, TIM_STPID, TIM_IsNightOnly, TIM_RepeatCount) ON dbo.WFTimeouts TO ' + @u + N';' +
            N'GRANT SELECT (STP_ID, STP_WFID) ON dbo.WFSteps TO ' + @u + N';' +
            N'GRANT SELECT (WF_ID, WF_WFDEFID) ON dbo.WorkFlows TO ' + @u + N';' +
            N'GRANT SELECT (DEF_ID, DEF_EnableTimeouts) ON dbo.WFDefinitions TO ' + @u + N';';
        EXEC @exec @sql;
        RAISERROR(N'Baza %s: uprawnienia nadane.', 10, 1, @db) WITH NOWAIT;
    END;
    FETCH NEXT FROM dbs INTO @db;
END;
CLOSE dbs;
DEALLOCATE dbs;
GO

/*
  Weryfikacja (jako DBA, w bazie treści) - pierwsze zapytanie powinno zwrócić liczbę, drugie błąd uprawnień:

  USE [WEBCON_Content];
  EXECUTE AS LOGIN = 'svc_obs_mssql_exporter';
      SELECT COUNT(MAIL_AttemptsNumber) FROM dbo.WFMails;
      SELECT TOP 1 * FROM dbo.WFMails;              -- oczekiwany błąd: The SELECT permission was denied
  REVERT;
*/
