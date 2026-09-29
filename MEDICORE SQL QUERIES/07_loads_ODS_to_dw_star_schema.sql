USE MediCoreDW;
GO
SET NOCOUNT ON;
GO

INSERT INTO audit.LoadControl (LoadName, SourceSystem) VALUES ('ODS_TO_DW','ODS');
GO

/* ===== 1. DIMDATE — generated, not loaded ===== */
IF NOT EXISTS (SELECT 1 FROM dw.DimDate)
BEGIN
    DECLARE @d DATE = '2019-01-01', @end DATE = '2027-12-31';
    ;WITH N AS (
        SELECT TOP (DATEDIFF(DAY,@d,@end)+1)
               DATEADD(DAY, ROW_NUMBER() OVER (ORDER BY (SELECT NULL))-1, @d) AS FullDate
        FROM sys.all_objects a CROSS JOIN sys.all_objects b)
    INSERT INTO dw.DimDate (DateKey, FullDate, DayOfMonth, DayName, DayOfWeek,
        IsWeekend, WeekOfYear, MonthNumber, MonthName, MonthYear,
        QuarterNumber, QuarterName, CalendarYear, FiscalYear, FiscalQuarter, FiscalMonthNo)
    SELECT CONVERT(INT, FORMAT(FullDate,'yyyyMMdd')), FullDate,
           DAY(FullDate), DATENAME(WEEKDAY, FullDate), DATEPART(WEEKDAY, FullDate),
           CASE WHEN DATENAME(WEEKDAY,FullDate) IN ('Saturday','Sunday') THEN 1 ELSE 0 END,
           DATEPART(WEEK, FullDate), MONTH(FullDate), DATENAME(MONTH, FullDate),
           FORMAT(FullDate,'MMM yyyy'), DATEPART(QUARTER, FullDate),
           'Q' + CAST(DATEPART(QUARTER,FullDate) AS VARCHAR(1)), YEAR(FullDate),
           CASE WHEN MONTH(FullDate) >= 4
                THEN 'FY'+CAST(YEAR(FullDate) AS VARCHAR(4))+'-'+RIGHT(CAST(YEAR(FullDate)+1 AS VARCHAR(4)),2)
                ELSE 'FY'+CAST(YEAR(FullDate)-1 AS VARCHAR(4))+'-'+RIGHT(CAST(YEAR(FullDate) AS VARCHAR(4)),2) END,
           'Q' + CAST(((MONTH(FullDate)+8)%12)/3 + 1 AS VARCHAR(1)),
           ((MONTH(FullDate)+8)%12) + 1
    FROM N;
END
GO

/* ===== 2. UNKNOWN MEMBERS (SK = -1) ===== */
SET IDENTITY_INSERT dw.DimPatient ON;
IF NOT EXISTS (SELECT 1 FROM dw.DimPatient WHERE PatientSK = -1)
INSERT INTO dw.DimPatient (PatientSK, PatientID, PatientName, EffectiveFrom, EffectiveTo, IsCurrent)
VALUES (-1, 'UNKNOWN', 'Unknown Patient', '1900-01-01', '9999-12-31', 1);
SET IDENTITY_INSERT dw.DimPatient OFF;

--A fact row must point at a dimension. 
--But sometimes the dimension data is missing. 
--Say a bill arrives for patient P9999, and that patient hasn't loaded into DimPatient yet.
-- point it at a known placeholder. 
--The row loads, the join works, and the report shows a line labelled "Unknown Patient" with the amount visible.

--Why −1 specifically

--Surrogate keys come from IDENTITY(1,1) — they start at 1 and count up. 
--So −1 can never collide with a real generated key. It's reserved territory.
--By convention: −1 = unknown, and some teams add −2 = not applicable. 
--Any negative number works; −1 is just what everyone uses.

SET IDENTITY_INSERT dw.DimDoctor ON;
IF NOT EXISTS (SELECT 1 FROM dw.DimDoctor WHERE DoctorSK = -1)
INSERT INTO dw.DimDoctor (DoctorSK, DoctorID, DoctorName) VALUES (-1,'UNK','Unknown Doctor');
SET IDENTITY_INSERT dw.DimDoctor OFF;

SET IDENTITY_INSERT dw.DimDepartment ON;
IF NOT EXISTS (SELECT 1 FROM dw.DimDepartment WHERE DepartmentSK = -1)
INSERT INTO dw.DimDepartment (DepartmentSK, DepartmentID, DepartmentName)
VALUES (-1, -1, 'Unknown Department');
SET IDENTITY_INSERT dw.DimDepartment OFF;

SET IDENTITY_INSERT dw.DimInsurer ON;
IF NOT EXISTS (SELECT 1 FROM dw.DimInsurer WHERE InsurerSK = -1)
INSERT INTO dw.DimInsurer (InsurerSK, InsurerName, IsSelfPay) VALUES (-1,'Self Pay',1);
SET IDENTITY_INSERT dw.DimInsurer OFF;
GO

/* ===== 3. SCD TYPE 1 DIMENSIONS (overwrite) ===== */
DECLARE @LoadID INT = (SELECT MAX(LoadID) FROM audit.LoadControl WHERE LoadName='ODS_TO_DW');

MERGE dw.DimDepartment AS tgt
USING (SELECT DepartmentID, DepartmentName FROM ods.Department) AS src
   ON tgt.DepartmentID = src.DepartmentID
WHEN MATCHED AND tgt.DepartmentName <> src.DepartmentName
     THEN UPDATE SET tgt.DepartmentName = src.DepartmentName, tgt.LoadID = @LoadID
WHEN NOT MATCHED BY TARGET
     THEN INSERT (DepartmentID, DepartmentName, LoadID)
          VALUES (src.DepartmentID, src.DepartmentName, @LoadID);

MERGE dw.DimBranch AS tgt
USING (SELECT BranchCode, BranchName, City FROM ods.Branch) AS src
   ON tgt.BranchCode = src.BranchCode
WHEN MATCHED THEN UPDATE SET tgt.BranchName = src.BranchName,
                             tgt.City = src.City, tgt.LoadID = @LoadID
WHEN NOT MATCHED BY TARGET
     THEN INSERT (BranchCode, BranchName, City, LoadID)
          VALUES (src.BranchCode, src.BranchName, src.City, @LoadID);

MERGE dw.DimInsurer AS tgt
USING (SELECT InsurerName FROM ods.Insurer) AS src
   ON tgt.InsurerName = src.InsurerName
WHEN NOT MATCHED BY TARGET
     THEN INSERT (InsurerName, IsSelfPay, LoadID) VALUES (src.InsurerName, 0, @LoadID);

MERGE dw.DimDoctor AS tgt
USING (SELECT d.DoctorID, d.DoctorName, d.Specialization,
              t.DepartmentName, d.StandardConsultFee
       FROM ods.Doctor d
       LEFT JOIN ods.Department t ON t.DepartmentID = d.DepartmentID) AS src
   ON tgt.DoctorID = src.DoctorID
WHEN MATCHED THEN UPDATE SET                      -- SCD1: overwrite, no history
        tgt.DoctorName = src.DoctorName, tgt.Specialization = src.Specialization,
        tgt.DepartmentName = src.DepartmentName,
        tgt.StandardConsultFee = src.StandardConsultFee, tgt.LoadID = @LoadID
WHEN NOT MATCHED BY TARGET
     THEN INSERT (DoctorID, DoctorName, Specialization, DepartmentName, StandardConsultFee, LoadID)
          VALUES (src.DoctorID, src.DoctorName, src.Specialization,
                  src.DepartmentName, src.StandardConsultFee, @LoadID);
GO

/* ===== 4. LAB TEST / MEDICINE / PAYMENT MODE ===== */
DECLARE @LoadID INT = (SELECT MAX(LoadID) FROM audit.LoadControl WHERE LoadName='ODS_TO_DW');

INSERT INTO dw.DimLabTest (TestName, LoadID)
SELECT DISTINCT l.TestName, @LoadID FROM ods.LabResult l
WHERE NOT EXISTS (SELECT 1 FROM dw.DimLabTest x WHERE x.TestName = l.TestName);

INSERT INTO dw.DimMedicine (MedicineName, LoadID)
SELECT DISTINCT p.MedicineName, @LoadID FROM ods.Prescription p
WHERE NOT EXISTS (SELECT 1 FROM dw.DimMedicine x WHERE x.MedicineName = p.MedicineName);

INSERT INTO dw.DimPaymentMode (PaymentMode, PaymentStatus, IsDigital, IsSettled)
SELECT DISTINCT ISNULL(b.PaymentMode,'Unknown'), ISNULL(b.PaymentStatus,'unknown'),
       CASE WHEN b.PaymentMode IN ('UPI','Net Banking','Credit Card','Debit Card') THEN 1 ELSE 0 END,
       CASE WHEN b.PaymentStatus = 'paid' THEN 1 ELSE 0 END
FROM ods.Bill b
WHERE NOT EXISTS (SELECT 1 FROM dw.DimPaymentMode x
                  WHERE x.PaymentMode = ISNULL(b.PaymentMode,'Unknown')
                  AND   x.PaymentStatus = ISNULL(b.PaymentStatus,'unknown'));
GO

/* ===== 5. DIMPATIENT — SCD TYPE 2 =====
   Two passes: MERGE cannot both close and open a row for the same key. */
DECLARE @LoadID INT = (SELECT MAX(LoadID) FROM audit.LoadControl WHERE LoadName='ODS_TO_DW');
DECLARE @Today DATE = CAST(SYSDATETIME() AS DATE);

;WITH Src AS (
    SELECT p.PatientID, p.PatientName, p.DateOfBirth, p.Gender, p.BloodGroup,
           p.City, p.AddressLine,
           CASE WHEN EXISTS (SELECT 1 FROM ods.PatientAllergy a WHERE a.PatientID=p.PatientID)
                THEN 1 ELSE 0 END AS HasAllergies,
           HASHBYTES('SHA2_256', CONCAT(p.PatientName,'|',ISNULL(p.City,''),'|',
                ISNULL(p.AddressLine,''),'|',ISNULL(p.Gender,''),'|',ISNULL(p.BloodGroup,''))) AS RowHash
    FROM ods.Patient p
)
UPDATE d SET d.EffectiveTo = DATEADD(DAY,-1,@Today), d.IsCurrent = 0
FROM   dw.DimPatient d
JOIN   Src s ON s.PatientID = d.PatientID
WHERE  d.IsCurrent = 1 AND d.PatientSK <> -1
AND    (d.RowHash IS NULL OR d.RowHash <> s.RowHash);

;WITH Src AS (
    SELECT p.PatientID, p.PatientName, p.DateOfBirth, p.Gender, p.BloodGroup,
           p.City, p.AddressLine,
           CASE WHEN EXISTS (SELECT 1 FROM ods.PatientAllergy a WHERE a.PatientID=p.PatientID)
                THEN 1 ELSE 0 END AS HasAllergies,
           CASE WHEN p.DateOfBirth IS NULL THEN 'Unknown'
                WHEN DATEDIFF(YEAR,p.DateOfBirth,@Today) < 18 THEN '0-17'
                WHEN DATEDIFF(YEAR,p.DateOfBirth,@Today) < 35 THEN '18-34'
                WHEN DATEDIFF(YEAR,p.DateOfBirth,@Today) < 55 THEN '35-54'
                WHEN DATEDIFF(YEAR,p.DateOfBirth,@Today) < 70 THEN '55-69'
                ELSE '70+' END AS AgeBand,
           HASHBYTES('SHA2_256', CONCAT(p.PatientName,'|',ISNULL(p.City,''),'|',
                ISNULL(p.AddressLine,''),'|',ISNULL(p.Gender,''),'|',ISNULL(p.BloodGroup,''))) AS RowHash
    FROM ods.Patient p
)
INSERT INTO dw.DimPatient (PatientID, PatientName, DateOfBirth, AgeBand, Gender,
        BloodGroup, City, AddressLine, HasAllergies,
        EffectiveFrom, EffectiveTo, IsCurrent, RowHash, LoadID)
SELECT s.PatientID, s.PatientName, s.DateOfBirth, s.AgeBand, s.Gender,
       s.BloodGroup, s.City, s.AddressLine, s.HasAllergies,
       @Today, '9999-12-31', 1, s.RowHash, @LoadID
FROM   Src s
WHERE  NOT EXISTS (SELECT 1 FROM dw.DimPatient d
                   WHERE d.PatientID = s.PatientID AND d.IsCurrent = 1);
GO

/* ===== 6. FACTS ===== */
DECLARE @LoadID INT = (SELECT MAX(LoadID) FROM audit.LoadControl WHERE LoadName='ODS_TO_DW');

TRUNCATE TABLE dw.FactPrescription;
TRUNCATE TABLE dw.FactLabResult;
TRUNCATE TABLE dw.FactBilling;
TRUNCATE TABLE dw.FactAppointment;

INSERT INTO dw.FactAppointment (AppointmentDateKey, BookingDateKey, FollowUpDateKey,
        PatientSK, DoctorSK, DepartmentSK, BranchSK, AppointmentID, ERPTransactionID,
        AppointmentTime, AppointmentStatus, ChiefComplaint, Diagnosis, ConsultationFee,
        IsCompleted, IsNoShow, IsCancelled, LoadID)
SELECT dd.DateKey, db.DateKey, NULL,
       ISNULL(dp.PatientSK,-1), ISNULL(doc.DoctorSK,-1), ISNULL(dep.DepartmentSK,-1), br.BranchSK,
       a.AppointmentID, a.ERPTransactionID, a.AppointmentTime, a.AppointmentStatus,
       a.ChiefComplaint, a.Diagnosis, a.ConsultationFee,
       CASE WHEN a.AppointmentStatus='completed' THEN 1 ELSE 0 END,
       CASE WHEN a.AppointmentStatus='no_show'   THEN 1 ELSE 0 END,
       CASE WHEN a.AppointmentStatus='cancelled' THEN 1 ELSE 0 END, @LoadID
FROM   ods.Appointment a
JOIN   dw.DimDate dd ON dd.FullDate = a.AppointmentDate
LEFT   JOIN dw.DimDate db ON db.FullDate = DATEADD(DAY,-7,a.AppointmentDate)
LEFT   JOIN dw.DimPatient dp ON dp.PatientID = a.PatientID AND dp.IsCurrent = 1
LEFT   JOIN dw.DimDoctor doc ON doc.DoctorID = a.DoctorID
LEFT   JOIN dw.DimDepartment dep ON dep.DepartmentID = a.DepartmentID
LEFT   JOIN dw.DimBranch br ON br.BranchCode = a.BranchCode;

INSERT INTO dw.FactBilling (BillDateKey, AppointmentDateKey, PatientSK, DoctorSK,
        DepartmentSK, BranchSK, InsurerSK, PaymentModeSK, AppointmentID,
        ConsultationFee, LabCharge, MedicineCharge, Subtotal, Discount,
        GSTAmount, TotalAmount, BillIsValid, TotalVariance, LoadID)
SELECT dd.DateKey, dd.DateKey,
       ISNULL(dp.PatientSK,-1), ISNULL(doc.DoctorSK,-1), ISNULL(dep.DepartmentSK,-1),
       br.BranchSK, ISNULL(ins.InsurerSK,-1), pm.PaymentModeSK, b.AppointmentID,
       b.ConsultationFee, b.LabCharge, b.MedicineCharge, b.Subtotal, b.Discount,
       b.GSTAmount, b.TotalAmount, b.BillIsValid, b.TotalAmount - b.ExpectedTotal, @LoadID
FROM   ods.Bill b
JOIN   ods.Appointment a ON a.AppointmentID = b.AppointmentID
JOIN   dw.DimDate dd ON dd.FullDate = a.AppointmentDate
LEFT   JOIN dw.DimPatient dp ON dp.PatientID = a.PatientID AND dp.IsCurrent = 1
LEFT   JOIN dw.DimDoctor doc ON doc.DoctorID = a.DoctorID
LEFT   JOIN dw.DimDepartment dep ON dep.DepartmentID = a.DepartmentID
LEFT   JOIN dw.DimBranch br ON br.BranchCode = a.BranchCode
OUTER  APPLY (SELECT TOP 1 pp.InsurerID FROM ods.PatientPolicy pp
              WHERE pp.PatientID = a.PatientID) pol
LEFT   JOIN ods.Insurer oi ON oi.InsurerID = pol.InsurerID
LEFT   JOIN dw.DimInsurer ins ON ins.InsurerName = oi.InsurerName
LEFT   JOIN dw.DimPaymentMode pm ON pm.PaymentMode = ISNULL(b.PaymentMode,'Unknown')
                               AND pm.PaymentStatus = ISNULL(b.PaymentStatus,'unknown');

INSERT INTO dw.FactLabResult (AppointmentDateKey, ResultDateKey, PatientSK,
        DoctorSK, LabTestSK, BranchSK, AppointmentID, ResultValue,
        ReferenceRange, IsAbnormal, LabCharge, LoadID)
SELECT dd.DateKey, dr.DateKey, ISNULL(dp.PatientSK,-1), ISNULL(doc.DoctorSK,-1),
       dlt.LabTestSK, br.BranchSK, l.AppointmentID, l.ResultValue, l.ReferenceRange,
       l.IsAbnormal, l.LabCharge, @LoadID
FROM   ods.LabResult l
JOIN   ods.Appointment a ON a.AppointmentID = l.AppointmentID
JOIN   dw.DimDate dd ON dd.FullDate = a.AppointmentDate
LEFT   JOIN dw.DimDate dr ON dr.FullDate = DATEADD(DAY,1,a.AppointmentDate)
JOIN   dw.DimLabTest dlt ON dlt.TestName = l.TestName
LEFT   JOIN dw.DimPatient dp ON dp.PatientID = a.PatientID AND dp.IsCurrent = 1
LEFT   JOIN dw.DimDoctor doc ON doc.DoctorID = a.DoctorID
LEFT   JOIN dw.DimBranch br ON br.BranchCode = a.BranchCode;

INSERT INTO dw.FactPrescription (AppointmentDateKey, PatientSK, DoctorSK,
        MedicineSK, BranchSK, AppointmentID, Dosage, Frequency,
        DurationDays, MedicineCharge, LoadID)
SELECT dd.DateKey, ISNULL(dp.PatientSK,-1), ISNULL(doc.DoctorSK,-1),
       dm.MedicineSK, br.BranchSK, p.AppointmentID, p.Dosage, p.Frequency,
       p.DurationDays, p.MedicineCharge, @LoadID
FROM   ods.Prescription p
JOIN   ods.Appointment a ON a.AppointmentID = p.AppointmentID
JOIN   dw.DimDate dd ON dd.FullDate = a.AppointmentDate
JOIN   dw.DimMedicine dm ON dm.MedicineName = p.MedicineName
LEFT   JOIN dw.DimPatient dp ON dp.PatientID = a.PatientID AND dp.IsCurrent = 1
LEFT   JOIN dw.DimDoctor doc ON doc.DoctorID = a.DoctorID
LEFT   JOIN dw.DimBranch br ON br.BranchCode = a.BranchCode;

UPDATE audit.LoadControl
SET CompletedAt = SYSDATETIME(), LoadStatus = 'SUCCESS',
    RowsInserted = (SELECT COUNT(*) FROM dw.FactAppointment)
WHERE LoadID = @LoadID;
GO

SELECT 'DimDate' t, COUNT(*) n FROM dw.DimDate
UNION ALL SELECT 'DimPatient (current)', COUNT(*) FROM dw.DimPatient WHERE IsCurrent=1
UNION ALL SELECT 'DimDoctor',        COUNT(*) FROM dw.DimDoctor
UNION ALL SELECT 'DimDepartment',    COUNT(*) FROM dw.DimDepartment
UNION ALL SELECT 'DimBranch',        COUNT(*) FROM dw.DimBranch
UNION ALL SELECT 'DimInsurer',       COUNT(*) FROM dw.DimInsurer
UNION ALL SELECT 'DimPaymentMode',   COUNT(*) FROM dw.DimPaymentMode
UNION ALL SELECT 'DimLabTest',       COUNT(*) FROM dw.DimLabTest
UNION ALL SELECT 'DimMedicine',      COUNT(*) FROM dw.DimMedicine
UNION ALL SELECT 'FactAppointment',  COUNT(*) FROM dw.FactAppointment
UNION ALL SELECT 'FactBilling',      COUNT(*) FROM dw.FactBilling
UNION ALL SELECT 'FactLabResult',    COUNT(*) FROM dw.FactLabResult
UNION ALL SELECT 'FactPrescription', COUNT(*) FROM dw.FactPrescription;