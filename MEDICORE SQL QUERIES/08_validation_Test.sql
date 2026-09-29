USE MediCoreDW;
GO
SET NOCOUNT ON;
GO

DECLARE @LoadID INT = (SELECT MAX(LoadID) FROM audit.LoadControl);

/* T001 — stg to ods row count */
DECLARE @stg INT = (SELECT COUNT(DISTINCT AppointmentID) FROM stg.HospitalRaw);
DECLARE @ods INT = (SELECT COUNT(*) FROM ods.Appointment);
INSERT INTO audit.DQResults (LoadID, TestCode, TestName, Layer, ExpectedValue, ActualValue, RowsFailed, TestResult)
VALUES (@LoadID,'T001','Distinct appointments in STG match ODS','ods',
        CAST(@stg AS VARCHAR), CAST(@ods AS VARCHAR), ABS(@stg-@ods),
        CASE WHEN @stg=@ods THEN 'PASS' ELSE 'FAIL' END);

/* T002 — ods to dw row count */
DECLARE @fact INT = (SELECT COUNT(*) FROM dw.FactAppointment);
INSERT INTO audit.DQResults (LoadID, TestCode, TestName, Layer, ExpectedValue, ActualValue, RowsFailed, TestResult)
VALUES (@LoadID,'T002','ODS appointments match FactAppointment','dw',
        CAST(@ods AS VARCHAR), CAST(@fact AS VARCHAR), ABS(@ods-@fact),
        CASE WHEN @ods=@fact THEN 'PASS' ELSE 'FAIL' END);

/* T003 — revenue reconciliation */
DECLARE @odsRev DECIMAL(18,2) = (SELECT SUM(TotalAmount) FROM ods.Bill);
DECLARE @dwRev  DECIMAL(18,2) = (SELECT SUM(TotalAmount) FROM dw.FactBilling);
INSERT INTO audit.DQResults (LoadID, TestCode, TestName, Layer, ExpectedValue, ActualValue, RowsFailed, TestResult)
VALUES (@LoadID,'T003','Total revenue reconciles ODS to DW','dw',
        CAST(@odsRev AS VARCHAR), CAST(@dwRev AS VARCHAR), 0,
        CASE WHEN ABS(ISNULL(@odsRev,0)-ISNULL(@dwRev,0)) <= 1 THEN 'PASS' ELSE 'FAIL' END);

/* T004 — orphan dimension keys */
DECLARE @orphan INT = (SELECT COUNT(*) FROM dw.FactAppointment f
    WHERE NOT EXISTS (SELECT 1 FROM dw.DimPatient d WHERE d.PatientSK=f.PatientSK)
       OR NOT EXISTS (SELECT 1 FROM dw.DimDoctor  d WHERE d.DoctorSK =f.DoctorSK)
       OR NOT EXISTS (SELECT 1 FROM dw.DimDate    d WHERE d.DateKey  =f.AppointmentDateKey));
INSERT INTO audit.DQResults (LoadID, TestCode, TestName, Layer, ExpectedValue, ActualValue, RowsFailed, TestResult)
VALUES (@LoadID,'T004','No orphan dimension keys in FactAppointment','dw','0',
        CAST(@orphan AS VARCHAR), @orphan, CASE WHEN @orphan=0 THEN 'PASS' ELSE 'FAIL' END);

/* T005 — one current row per patient */
DECLARE @scd INT = (SELECT COUNT(*) FROM (
    SELECT PatientID FROM dw.DimPatient WHERE IsCurrent=1
    GROUP BY PatientID HAVING COUNT(*)>1) x);
INSERT INTO audit.DQResults (LoadID, TestCode, TestName, Layer, ExpectedValue, ActualValue, RowsFailed, TestResult)
VALUES (@LoadID,'T005','Exactly one current row per patient','dw','0',
        CAST(@scd AS VARCHAR), @scd, CASE WHEN @scd=0 THEN 'PASS' ELSE 'FAIL' END);

/* T006 — no overlapping SCD2 ranges */
DECLARE @ovl INT = (SELECT COUNT(*) FROM dw.DimPatient a
    JOIN dw.DimPatient b ON a.PatientID=b.PatientID AND a.PatientSK<b.PatientSK
    WHERE a.EffectiveFrom<=b.EffectiveTo AND b.EffectiveFrom<=a.EffectiveTo);
INSERT INTO audit.DQResults (LoadID, TestCode, TestName, Layer, ExpectedValue, ActualValue, RowsFailed, TestResult)
VALUES (@LoadID,'T006','No overlapping SCD2 validity ranges','dw','0',
        CAST(@ovl AS VARCHAR), @ovl, CASE WHEN @ovl=0 THEN 'PASS' ELSE 'FAIL' END);

/* T007 — duplicate business keys */
DECLARE @dup INT = (SELECT COUNT(*) FROM (
    SELECT AppointmentID FROM dw.FactAppointment GROUP BY AppointmentID HAVING COUNT(*)>1) x);
INSERT INTO audit.DQResults (LoadID, TestCode, TestName, Layer, ExpectedValue, ActualValue, RowsFailed, TestResult)
VALUES (@LoadID,'T007','No duplicate AppointmentID in fact','dw','0',
        CAST(@dup AS VARCHAR), @dup, CASE WHEN @dup=0 THEN 'PASS' ELSE 'FAIL' END);

/* T008 — the billing assertion. EXPECTED TO FAIL. */
DECLARE @bad INT = (SELECT COUNT(*) FROM dw.FactBilling WHERE BillIsValid=0);
DECLARE @tot INT = (SELECT COUNT(*) FROM dw.FactBilling);
INSERT INTO audit.DQResults (LoadID, TestCode, TestName, Layer, ExpectedValue, ActualValue, RowsFailed, TestResult)
VALUES (@LoadID,'T008','Total = Subtotal - Discount + GST','dw','0',
        CAST(@bad AS VARCHAR)+' of '+CAST(@tot AS VARCHAR), @bad,
        CASE WHEN @bad=0 THEN 'PASS' ELSE 'FAIL' END);

/* T009 — no negative measures */
DECLARE @neg INT = (SELECT COUNT(*) FROM dw.FactBilling
    WHERE TotalAmount<0 OR Discount<0 OR Subtotal<0);
INSERT INTO audit.DQResults (LoadID, TestCode, TestName, Layer, ExpectedValue, ActualValue, RowsFailed, TestResult)
VALUES (@LoadID,'T009','No negative amounts in FactBilling','dw','0',
        CAST(@neg AS VARCHAR), @neg, CASE WHEN @neg=0 THEN 'PASS' ELSE 'FAIL' END);

/* T010 — no future dates */
DECLARE @future INT = (SELECT COUNT(*) FROM dw.FactAppointment f
    JOIN dw.DimDate d ON d.DateKey=f.AppointmentDateKey
    WHERE d.FullDate > CAST(SYSDATETIME() AS DATE));
INSERT INTO audit.DQResults (LoadID, TestCode, TestName, Layer, ExpectedValue, ActualValue, RowsFailed, TestResult)
VALUES (@LoadID,'T010','No future-dated appointments','dw','0',
        CAST(@future AS VARCHAR), @future, CASE WHEN @future=0 THEN 'PASS' ELSE 'WARN' END);
GO

SELECT TestCode, TestName, ExpectedValue, ActualValue, RowsFailed, TestResult
FROM   audit.DQResults
WHERE  RunAt >= DATEADD(MINUTE,-2,SYSDATETIME())
ORDER  BY TestCode;
GO

/* ================= SAMPLE ANALYTICS ================= */

-- Revenue by fiscal year and department
SELECT d.FiscalYear, dep.DepartmentName,
       COUNT(*) AS Bills, SUM(f.TotalAmount) AS Revenue, SUM(f.Discount) AS Discounts
FROM   dw.FactBilling f
JOIN   dw.DimDate d         ON d.DateKey = f.BillDateKey
JOIN   dw.DimDepartment dep ON dep.DepartmentSK = f.DepartmentSK
GROUP  BY d.FiscalYear, dep.DepartmentName
ORDER  BY d.FiscalYear, Revenue DESC;

-- No-show rate by doctor
SELECT doc.DoctorName, doc.Specialization, COUNT(*) AS Appointments,
       SUM(CAST(f.IsNoShow AS INT)) AS NoShows,
       CAST(100.0*SUM(CAST(f.IsNoShow AS INT))/COUNT(*) AS DECIMAL(5,2)) AS NoShowPct
FROM   dw.FactAppointment f
JOIN   dw.DimDoctor doc ON doc.DoctorSK = f.DoctorSK
GROUP  BY doc.DoctorName, doc.Specialization
ORDER  BY NoShowPct DESC;

-- Billing defect rate by branch — the headline problem, quantified
SELECT br.BranchCode, COUNT(*) AS Bills,
       SUM(CASE WHEN f.BillIsValid=0 THEN 1 ELSE 0 END) AS InvalidBills,
       CAST(100.0*SUM(CASE WHEN f.BillIsValid=0 THEN 1 ELSE 0 END)/COUNT(*) AS DECIMAL(5,2)) AS DefectPct,
       SUM(ABS(f.TotalVariance)) AS AbsVarianceINR
FROM   dw.FactBilling f
LEFT   JOIN dw.DimBranch br ON br.BranchSK = f.BranchSK
GROUP  BY br.BranchCode
ORDER  BY DefectPct DESC;

-- Abnormal lab rate by test
SELECT t.TestName, COUNT(*) AS Tests,
       SUM(CAST(ISNULL(f.IsAbnormal,0) AS INT)) AS Abnormal,
       CAST(100.0*SUM(CAST(ISNULL(f.IsAbnormal,0) AS INT))/COUNT(*) AS DECIMAL(5,2)) AS AbnormalPct
FROM   dw.FactLabResult f
JOIN   dw.DimLabTest t ON t.LabTestSK = f.LabTestSK
GROUP  BY t.TestName
HAVING COUNT(*) >= 20
ORDER  BY AbnormalPct DESC;