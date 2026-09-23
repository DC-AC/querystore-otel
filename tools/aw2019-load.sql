/*
  AdventureWorks2019 stored procedure load generator
  -------------------------------------------------
  Calls every user stored procedure in AdventureWorks2019 with realistic,
  randomly chosen parameters so Query Store has workload to capture.

  * Read procedures run as-is.
  * Write procedures run inside a transaction that is always rolled back,
    so no data changes. Query Store still records the executions.
  * Each call is isolated in TRY/CATCH, so one failure never stops the loop.
    (uspSearchCandidateResumes fails if Full-Text Search isn't installed;
    those show up as "Exception" executions in Query Store, which is useful.)

  Run it for longer than one Query Store interval so at least one interval
  closes with data. In SSMS, enable Query > Query Options > Results >
  "Discard results after execution" to avoid thousands of result grids.
*/
USE AdventureWorks2019;
SET NOCOUNT ON;
SET XACT_ABORT OFF;

DECLARE @DurationMinutes int = 20;   -- how long to run
DECLARE @DelayMs         int = 50;   -- pause between calls (0-59999)

------------------------------------------------------------------------------
-- Parameter pools drawn from real data
------------------------------------------------------------------------------
DROP TABLE IF EXISTS #emp, #asm, #comp, #stats;

SELECT ROW_NUMBER() OVER (ORDER BY e.BusinessEntityID) AS rn,
       e.BusinessEntityID, e.NationalIDNumber, e.BirthDate, e.MaritalStatus,
       e.Gender, e.OrganizationNode, e.LoginID, e.JobTitle, e.HireDate,
       e.CurrentFlag, ph.Rate, ph.PayFrequency
INTO #emp
FROM HumanResources.Employee e
CROSS APPLY (SELECT TOP (1) Rate, PayFrequency
             FROM HumanResources.EmployeePayHistory p
             WHERE p.BusinessEntityID = e.BusinessEntityID
             ORDER BY p.RateChangeDate DESC) ph
WHERE e.OrganizationNode IS NOT NULL;

SELECT ROW_NUMBER() OVER (ORDER BY ProductAssemblyID) AS rn,
       ProductAssemblyID AS ProductID,
       DATEADD(day, 30, MIN(StartDate)) AS CheckDate
INTO #asm
FROM Production.BillOfMaterials
WHERE ProductAssemblyID IS NOT NULL
GROUP BY ProductAssemblyID;

SELECT ROW_NUMBER() OVER (ORDER BY ComponentID) AS rn,
       ComponentID AS ProductID,
       DATEADD(day, 30, MIN(StartDate)) AS CheckDate
INTO #comp
FROM Production.BillOfMaterials
GROUP BY ComponentID;

DECLARE @search TABLE (rn int IDENTITY, term nvarchar(100));
INSERT @search (term) VALUES (N'sales'), (N'engineer'), (N'manager'),
                             (N'production'), (N'marketing'), (N'"quality control"');

CREATE TABLE #stats (proc_name sysname PRIMARY KEY, calls int, errors int, total_ms bigint);
INSERT #stats VALUES
 ('dbo.uspGetBillOfMaterials',0,0,0), ('dbo.uspGetWhereUsedProductID',0,0,0),
 ('dbo.uspGetEmployeeManagers',0,0,0), ('dbo.uspGetManagerEmployees',0,0,0),
 ('dbo.uspSearchCandidateResumes',0,0,0),
 ('HumanResources.uspUpdateEmployeePersonalInfo',0,0,0),
 ('HumanResources.uspUpdateEmployeeLogin',0,0,0),
 ('HumanResources.uspUpdateEmployeeHireInfo',0,0,0),
 ('dbo.uspLogError + dbo.uspPrintError',0,0,0);

DECLARE @empN  int = (SELECT COUNT(*) FROM #emp),
        @asmN  int = (SELECT COUNT(*) FROM #asm),
        @compN int = (SELECT COUNT(*) FROM #comp),
        @srchN int = (SELECT COUNT(*) FROM @search);

DECLARE @delay char(12) =
    '00:00:' + RIGHT('0' + CAST(@DelayMs / 1000 AS varchar(2)), 2) + '.' +
               RIGHT('00' + CAST(@DelayMs % 1000 AS varchar(3)), 3);

DECLARE @endAt datetime2 = DATEADD(minute, @DurationMinutes, SYSDATETIME());
DECLARE @r int, @t0 datetime2, @proc sysname, @failed bit, @iter int = 0;

-- Per-call parameters
DECLARE @id int, @nat nvarchar(15), @birth date, @marital nchar(1), @gender nchar(1),
        @node hierarchyid, @login nvarchar(256), @title nvarchar(50), @hire date,
        @flag bit, @rate money, @freq tinyint, @pid int, @check datetime,
        @term nvarchar(100), @errId int, @rcd datetime, @k int;

PRINT CONCAT('Load started ', SYSDATETIME(), ' for ', @DurationMinutes, ' minutes. Employees=',
             @empN, ' Assemblies=', @asmN, ' Components=', @compN);

------------------------------------------------------------------------------
-- Main loop
------------------------------------------------------------------------------
WHILE SYSDATETIME() < @endAt
BEGIN
    SET @iter += 1;
    SET @r = ABS(CHECKSUM(NEWID())) % 100;     -- weighted mix below
    SET @failed = 0;
    SET @t0 = SYSDATETIME();

    -- Random employee for any proc that needs one
    SET @k = 1 + ABS(CHECKSUM(NEWID())) % @empN;
    SELECT @id = BusinessEntityID, @nat = NationalIDNumber, @birth = BirthDate,
           @marital = MaritalStatus, @gender = Gender, @node = OrganizationNode,
           @login = LoginID, @title = JobTitle, @hire = HireDate, @flag = CurrentFlag,
           @rate = Rate, @freq = PayFrequency
    FROM #emp WHERE rn = @k;

    BEGIN TRY
        IF @r < 20          -- 20%: bill of materials (recursive CTE)
        BEGIN
            SET @proc = 'dbo.uspGetBillOfMaterials';
            SET @k = 1 + ABS(CHECKSUM(NEWID())) % @asmN;
            SELECT @pid = ProductID, @check = CheckDate FROM #asm WHERE rn = @k;
            EXEC dbo.uspGetBillOfMaterials @StartProductID = @pid, @CheckDate = @check;
        END
        ELSE IF @r < 35     -- 15%: where-used (recursive CTE)
        BEGIN
            SET @proc = 'dbo.uspGetWhereUsedProductID';
            SET @k = 1 + ABS(CHECKSUM(NEWID())) % @compN;
            SELECT @pid = ProductID, @check = CheckDate FROM #comp WHERE rn = @k;
            EXEC dbo.uspGetWhereUsedProductID @StartProductID = @pid, @CheckDate = @check;
        END
        ELSE IF @r < 50     -- 15%
        BEGIN
            SET @proc = 'dbo.uspGetEmployeeManagers';
            EXEC dbo.uspGetEmployeeManagers @BusinessEntityID = @id;
        END
        ELSE IF @r < 65     -- 15%
        BEGIN
            SET @proc = 'dbo.uspGetManagerEmployees';
            EXEC dbo.uspGetManagerEmployees @BusinessEntityID = @id;
        END
        ELSE IF @r < 75     -- 10%: full-text search (errors without Full-Text Search)
        BEGIN
            SET @proc = 'dbo.uspSearchCandidateResumes';
            SET @k = 1 + ABS(CHECKSUM(NEWID())) % @srchN;
            SELECT @term = term FROM @search WHERE rn = @k;
            EXEC dbo.uspSearchCandidateResumes @searchString = @term;
        END
        ELSE IF @r < 82     -- 7%: write, rolled back
        BEGIN
            SET @proc = 'HumanResources.uspUpdateEmployeePersonalInfo';
            BEGIN TRAN;
            EXEC HumanResources.uspUpdateEmployeePersonalInfo
                 @BusinessEntityID = @id, @NationalIDNumber = @nat, @BirthDate = @birth,
                 @MaritalStatus = @marital, @Gender = @gender;
            IF @@TRANCOUNT > 0 ROLLBACK;
        END
        ELSE IF @r < 89     -- 7%: write, rolled back
        BEGIN
            SET @proc = 'HumanResources.uspUpdateEmployeeLogin';
            BEGIN TRAN;
            EXEC HumanResources.uspUpdateEmployeeLogin
                 @BusinessEntityID = @id, @OrganizationNode = @node, @LoginID = @login,
                 @JobTitle = @title, @HireDate = @hire, @CurrentFlag = @flag;
            IF @@TRANCOUNT > 0 ROLLBACK;
        END
        ELSE IF @r < 96     -- 7%: write, rolled back
        BEGIN
            SET @proc = 'HumanResources.uspUpdateEmployeeHireInfo';
            BEGIN TRAN;
            SET @rcd = DATEADD(second, ABS(CHECKSUM(NEWID())) % 86400, SYSDATETIME());
            EXEC HumanResources.uspUpdateEmployeeHireInfo
                 @BusinessEntityID = @id, @JobTitle = @title, @HireDate = @hire,
                 @RateChangeDate = @rcd, @Rate = @rate, @PayFrequency = @freq, @CurrentFlag = @flag;
            IF @@TRANCOUNT > 0 ROLLBACK;
        END
        ELSE                -- 4%: error logging procs, rolled back
        BEGIN
            SET @proc = 'dbo.uspLogError + dbo.uspPrintError';
            BEGIN TRAN;
            BEGIN TRY
                THROW 50000, N'Synthetic error from Query Store load script', 1;
            END TRY
            BEGIN CATCH
                EXEC dbo.uspPrintError;
                EXEC dbo.uspLogError @ErrorLogID = @errId OUTPUT;
            END CATCH;
            IF @@TRANCOUNT > 0 ROLLBACK;
        END
    END TRY
    BEGIN CATCH
        IF @@TRANCOUNT > 0 ROLLBACK;
        SET @failed = 1;
        IF @iter % 200 = 1   -- don't flood the Messages tab
            PRINT CONCAT(@proc, ' failed: ', ERROR_NUMBER(), ' ', ERROR_MESSAGE());
    END CATCH;

    UPDATE #stats
       SET calls = calls + 1,
           errors = errors + @failed,
           total_ms = total_ms + DATEDIFF(millisecond, @t0, SYSDATETIME())
     WHERE proc_name = @proc;

    IF @DelayMs > 0 WAITFOR DELAY @delay;
END

------------------------------------------------------------------------------
-- Summary
------------------------------------------------------------------------------
PRINT CONCAT('Load finished ', SYSDATETIME(), ' after ', @iter, ' calls.');
SELECT proc_name, calls, errors,
       CAST(total_ms * 1.0 / NULLIF(calls, 0) AS decimal(10,2)) AS avg_ms
FROM #stats
ORDER BY calls DESC;
