USE MediCoreDW;
GO
SET NOCOUNT ON;
GO

DECLARE @LoadID INT;
INSERT INTO audit.LoadControl (LoadName, SourceSystem)
VALUES ('STG_TO_ODS', 'Oracle ERP');
SET @LoadID = SCOPE_IDENTITY();

BEGIN TRY
BEGIN TRANSACTION;

/* 1. BRANCH */
INSERT INTO ods.Branch (BranchCode, BranchName, City, LoadID)
SELECT DISTINCT LTRIM(RTRIM(s.BranchCode)),
       'MediCore ' + LTRIM(RTRIM(s.BranchCode)), NULL, @LoadID
FROM   stg.HospitalRaw s
WHERE  NULLIF(LTRIM(RTRIM(s.BranchCode)),'') IS NOT NULL
AND    NOT EXISTS (SELECT 1 FROM ods.Branch b
                   WHERE b.BranchCode = LTRIM(RTRIM(s.BranchCode)));

/* 2. DEPARTMENT */
INSERT INTO ods.Department (DepartmentID, DepartmentName, LoadID)
SELECT DISTINCT TRY_CAST(s.DepartmentID AS INT),
       LTRIM(RTRIM(s.DepartmentName)), @LoadID
FROM   stg.HospitalRaw s
WHERE  TRY_CAST(s.DepartmentID AS INT) IS NOT NULL
AND    NULLIF(LTRIM(RTRIM(s.DepartmentName)),'') IS NOT NULL
AND    NOT EXISTS (SELECT 1 FROM ods.Department d
                   WHERE d.DepartmentID = TRY_CAST(s.DepartmentID AS INT));

/* 3. DOCTOR — 2NF fix. StandardConsultFee = modal fee per doctor. */
WITH FeeRank AS (
    SELECT LTRIM(RTRIM(DoctorID)) AS DoctorID,
           TRY_CAST(ConsultationFeeINR AS DECIMAL(10,2)) AS Fee,
           ROW_NUMBER() OVER (PARTITION BY LTRIM(RTRIM(DoctorID))
                              ORDER BY COUNT(*) DESC,
                                       TRY_CAST(ConsultationFeeINR AS DECIMAL(10,2))) AS rn
    FROM   stg.HospitalRaw
    WHERE  TRY_CAST(ConsultationFeeINR AS DECIMAL(10,2)) IS NOT NULL
    GROUP  BY LTRIM(RTRIM(DoctorID)), TRY_CAST(ConsultationFeeINR AS DECIMAL(10,2))
),
DocSrc AS (
    SELECT LTRIM(RTRIM(s.DoctorID)) AS DoctorID,
           MAX(LTRIM(RTRIM(s.DoctorName)))      AS DoctorName,
           MAX(LTRIM(RTRIM(s.Specialization)))  AS Specialization,
           MAX(TRY_CAST(s.DepartmentID AS INT)) AS DepartmentID
    FROM   stg.HospitalRaw s
    WHERE  NULLIF(LTRIM(RTRIM(s.DoctorID)),'') IS NOT NULL
    GROUP  BY LTRIM(RTRIM(s.DoctorID))
)
INSERT INTO ods.Doctor (DoctorID, DoctorName, Specialization,
                        DepartmentID, StandardConsultFee, LoadID)
SELECT d.DoctorID, d.DoctorName, d.Specialization, d.DepartmentID, f.Fee, @LoadID
FROM   DocSrc d
LEFT   JOIN FeeRank f ON f.DoctorID = d.DoctorID AND f.rn = 1
WHERE  NOT EXISTS (SELECT 1 FROM ods.Doctor x WHERE x.DoctorID = d.DoctorID);

/* 4. INSURER — null provider = self-pay, legitimately excluded */
INSERT INTO ods.Insurer (InsurerName, LoadID)
SELECT DISTINCT LTRIM(RTRIM(s.InsuranceProvider)), @LoadID
FROM   stg.HospitalRaw s
WHERE  NULLIF(LTRIM(RTRIM(s.InsuranceProvider)),'') IS NOT NULL
AND    NOT EXISTS (SELECT 1 FROM ods.Insurer i
                   WHERE i.InsurerName = LTRIM(RTRIM(s.InsuranceProvider)));

/* 5. PATIENT — dedup on PatientID, keep most recent appointment's details */
WITH PatSrc AS (
    SELECT LTRIM(RTRIM(PatientID)) AS PatientID,
           LTRIM(RTRIM(PatientName)) AS PatientName,
           TRY_CONVERT(DATE, DateOfBirth, 23) AS DateOfBirth,
           CASE UPPER(LEFT(LTRIM(RTRIM(Gender)),1))
                WHEN 'M' THEN 'Male' WHEN 'F' THEN 'Female'
                WHEN 'O' THEN 'Other' ELSE NULL END AS Gender,
           NULLIF(UPPER(LTRIM(RTRIM(BloodGroup))),'') AS BloodGroup,
           NULLIF(LTRIM(RTRIM(Phone)),'')  AS Phone,
           LOWER(NULLIF(LTRIM(RTRIM(Email)),'')) AS Email,
           NULLIF(LTRIM(RTRIM([Address])),'') AS AddressLine,
           NULLIF(LTRIM(RTRIM(City)),'') AS City,
           ROW_NUMBER() OVER (PARTITION BY LTRIM(RTRIM(PatientID))
                              ORDER BY TRY_CONVERT(DATE, AppointmentDate, 23) DESC) AS rn
    FROM   stg.HospitalRaw
    WHERE  NULLIF(LTRIM(RTRIM(PatientID)),'') IS NOT NULL
)
INSERT INTO ods.Patient (PatientID, PatientName, DateOfBirth, Gender, BloodGroup,
                         Phone, Email, AddressLine, City, LoadID)
SELECT PatientID, PatientName, DateOfBirth, Gender, BloodGroup,
       Phone, Email, AddressLine, City, @LoadID
FROM   PatSrc
WHERE  rn = 1;

/* 6. PATIENT ALLERGY — 1NF fix */
INSERT INTO ods.PatientAllergy (PatientID, AllergyName, LoadID)
SELECT DISTINCT LTRIM(RTRIM(s.PatientID)), LTRIM(RTRIM(v.value)), @LoadID
FROM   stg.HospitalRaw s
CROSS  APPLY STRING_SPLIT(s.Allergies, ',') v
WHERE  NULLIF(LTRIM(RTRIM(s.Allergies)),'') IS NOT NULL
AND    LTRIM(RTRIM(s.Allergies)) NOT IN ('None','none','NULL','N/A','-')
AND    NULLIF(LTRIM(RTRIM(v.value)),'') IS NOT NULL
AND    EXISTS (SELECT 1 FROM ods.Patient p WHERE p.PatientID = LTRIM(RTRIM(s.PatientID)));

/* 7. PATIENT POLICY — 3NF fix */
WITH PolSrc AS (
    SELECT LTRIM(RTRIM(s.PatientID)) AS PatientID,
           LTRIM(RTRIM(s.PolicyNumber)) AS PolicyNumber,
           i.InsurerID,
           MAX(TRY_CAST(s.CoverageLimitINR AS DECIMAL(12,2))) AS CoverageLimit
    FROM   stg.HospitalRaw s
    JOIN   ods.Insurer i ON i.InsurerName = LTRIM(RTRIM(s.InsuranceProvider))
    WHERE  NULLIF(LTRIM(RTRIM(s.PolicyNumber)),'') IS NOT NULL
    GROUP  BY LTRIM(RTRIM(s.PatientID)), LTRIM(RTRIM(s.PolicyNumber)), i.InsurerID
)
INSERT INTO ods.PatientPolicy (PatientID, PolicyNumber, InsurerID, CoverageLimit, LoadID)
SELECT p.PatientID, p.PolicyNumber, p.InsurerID, p.CoverageLimit, @LoadID
FROM   PolSrc p
WHERE  EXISTS (SELECT 1 FROM ods.Patient x WHERE x.PatientID = p.PatientID);

/* 8. APPOINTMENT */
WITH ApptSrc AS (
    SELECT LTRIM(RTRIM(AppointmentID)) AS AppointmentID,
           LTRIM(RTRIM(PatientID))     AS PatientID,
           LTRIM(RTRIM(DoctorID))      AS DoctorID,
           TRY_CAST(DepartmentID AS INT) AS DepartmentID,
           LTRIM(RTRIM(BranchCode))    AS BranchCode,
           TRY_CONVERT(DATE, AppointmentDate, 23) AS AppointmentDate,
           TRY_CAST(AppointmentTime AS TIME(0))   AS AppointmentTime,
           LOWER(LTRIM(RTRIM(AppointmentStatus))) AS AppointmentStatus,
           NULLIF(LTRIM(RTRIM(ChiefComplaint)),'') AS ChiefComplaint,
           NULLIF(LTRIM(RTRIM(Diagnosis)),'')      AS Diagnosis,
           ClinicalNotes,
           TRY_CAST(ConsultationFeeINR AS DECIMAL(10,2)) AS ConsultationFee,
           LTRIM(RTRIM(ERPTransactionID)) AS ERPTransactionID,
           LTRIM(RTRIM(ERPModule))        AS ERPModule,
           LTRIM(RTRIM(CreatedBy))        AS CreatedBy,
           ROW_NUMBER() OVER (PARTITION BY LTRIM(RTRIM(AppointmentID))
                              ORDER BY TRY_CAST(RecordID AS INT)) AS rn
    FROM   stg.HospitalRaw
    WHERE  NULLIF(LTRIM(RTRIM(AppointmentID)),'') IS NOT NULL
)
INSERT INTO ods.Appointment (AppointmentID, PatientID, DoctorID, DepartmentID,
        BranchCode, AppointmentDate, AppointmentTime, AppointmentStatus,
        ChiefComplaint, Diagnosis, ClinicalNotes, ConsultationFee,
        ERPTransactionID, ERPModule, CreatedBy, LoadID)
SELECT a.AppointmentID, a.PatientID, a.DoctorID, a.DepartmentID,
       a.BranchCode, a.AppointmentDate, a.AppointmentTime, a.AppointmentStatus,
       a.ChiefComplaint, a.Diagnosis, a.ClinicalNotes, a.ConsultationFee,
       a.ERPTransactionID, a.ERPModule, a.CreatedBy, @LoadID
FROM   ApptSrc a
WHERE  a.rn = 1
AND    a.AppointmentDate IS NOT NULL
AND    EXISTS (SELECT 1 FROM ods.Patient    p WHERE p.PatientID    = a.PatientID)
AND    EXISTS (SELECT 1 FROM ods.Doctor     d WHERE d.DoctorID     = a.DoctorID)
AND    EXISTS (SELECT 1 FROM ods.Department t WHERE t.DepartmentID = a.DepartmentID);

INSERT INTO audit.RejectedRows (LoadID, SourceTable, SourceRecordID,
        RuleCode, RuleDescription, ColumnName, OffendingValue)
SELECT @LoadID, 'stg.HospitalRaw', s.AppointmentID,
       'R001', 'Appointment failed FK or date validation', 'AppointmentDate', s.AppointmentDate
FROM   stg.HospitalRaw s
WHERE  NULLIF(LTRIM(RTRIM(s.AppointmentID)),'') IS NOT NULL
AND    NOT EXISTS (SELECT 1 FROM ods.Appointment a
                   WHERE a.AppointmentID = LTRIM(RTRIM(s.AppointmentID)));

/* 9. LAB RESULT */
INSERT INTO ods.LabResult (AppointmentID, TestName, ResultValue,
                           ReferenceRange, IsAbnormal, LabCharge, LoadID)
SELECT LTRIM(RTRIM(s.AppointmentID)), LTRIM(RTRIM(s.LabTestName)),
       NULLIF(LTRIM(RTRIM(s.LabResult)),''),
       NULLIF(LTRIM(RTRIM(s.ReferenceRange)),''),
       CASE WHEN UPPER(LTRIM(RTRIM(s.IsAbnormal))) IN ('YES','Y','TRUE','1') THEN 1
            WHEN UPPER(LTRIM(RTRIM(s.IsAbnormal))) IN ('NO','N','FALSE','0')  THEN 0
            ELSE NULL END,
       ISNULL(TRY_CAST(s.LabChargeINR AS DECIMAL(10,2)), 0), @LoadID
FROM   stg.HospitalRaw s
JOIN   ods.Appointment a ON a.AppointmentID = LTRIM(RTRIM(s.AppointmentID))
WHERE  NULLIF(LTRIM(RTRIM(s.LabTestName)),'') IS NOT NULL;

/* 10. PRESCRIPTION */
INSERT INTO ods.Prescription (AppointmentID, MedicineName, Dosage,
                              Frequency, DurationDays, MedicineCharge, LoadID)
SELECT LTRIM(RTRIM(s.AppointmentID)), LTRIM(RTRIM(s.MedicineName)),
       NULLIF(LTRIM(RTRIM(s.Dosage)),''), NULLIF(LTRIM(RTRIM(s.Frequency)),''),
       TRY_CAST(s.DurationDays AS SMALLINT),
       ISNULL(TRY_CAST(s.MedicineChargeINR AS DECIMAL(10,2)), 0), @LoadID
FROM   stg.HospitalRaw s
JOIN   ods.Appointment a ON a.AppointmentID = LTRIM(RTRIM(s.AppointmentID))
WHERE  NULLIF(LTRIM(RTRIM(s.MedicineName)),'') IS NOT NULL
AND    TRY_CAST(s.DurationDays AS SMALLINT) BETWEEN 0 AND 365;

/* 11. BILL */
WITH BillSrc AS (
    SELECT LTRIM(RTRIM(s.AppointmentID)) AS AppointmentID,
           ISNULL(TRY_CAST(s.ConsultationFeeINR AS DECIMAL(10,2)),0) AS ConsultationFee,
           ISNULL(TRY_CAST(s.LabChargeINR       AS DECIMAL(10,2)),0) AS LabCharge,
           ISNULL(TRY_CAST(s.MedicineChargeINR  AS DECIMAL(10,2)),0) AS MedicineCharge,
           TRY_CAST(s.SubtotalINR    AS DECIMAL(12,2)) AS Subtotal,
           ISNULL(TRY_CAST(s.DiscountINR AS DECIMAL(12,2)),0) AS Discount,
           ISNULL(TRY_CAST(s.GSTAmountINR AS DECIMAL(12,2)),0) AS GSTAmount,
           TRY_CAST(s.TotalAmountINR AS DECIMAL(12,2)) AS TotalAmount,
           NULLIF(LTRIM(RTRIM(s.PaymentMode)),'')   AS PaymentMode,
           LOWER(NULLIF(LTRIM(RTRIM(s.PaymentStatus)),'')) AS PaymentStatus,
           ROW_NUMBER() OVER (PARTITION BY LTRIM(RTRIM(s.AppointmentID))
                              ORDER BY TRY_CAST(s.RecordID AS INT)) AS rn
    FROM   stg.HospitalRaw s
)
INSERT INTO ods.Bill (AppointmentID, ConsultationFee, LabCharge, MedicineCharge,
        Subtotal, Discount, GSTAmount, TotalAmount, PaymentMode, PaymentStatus, LoadID)
SELECT b.AppointmentID, b.ConsultationFee, b.LabCharge, b.MedicineCharge,
       b.Subtotal, b.Discount, b.GSTAmount, b.TotalAmount,
       b.PaymentMode, b.PaymentStatus, @LoadID
FROM   BillSrc b
JOIN   ods.Appointment a ON a.AppointmentID = b.AppointmentID
WHERE  b.rn = 1
AND    b.Subtotal IS NOT NULL AND b.TotalAmount IS NOT NULL
AND    b.Discount <= b.Subtotal AND b.TotalAmount >= 0;

COMMIT TRANSACTION;

UPDATE audit.LoadControl
SET    CompletedAt  = SYSDATETIME(), LoadStatus = 'SUCCESS',
       RowsRead     = (SELECT COUNT(*) FROM stg.HospitalRaw),
       RowsInserted = (SELECT COUNT(*) FROM ods.Appointment WHERE LoadID = @LoadID),
       RowsRejected = (SELECT COUNT(*) FROM audit.RejectedRows WHERE LoadID = @LoadID)
WHERE  LoadID = @LoadID;

PRINT 'STG -> ODS complete. LoadID = ' + CAST(@LoadID AS VARCHAR(10));

END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
    UPDATE audit.LoadControl
    SET CompletedAt = SYSDATETIME(), LoadStatus = 'FAILED', ErrorMessage = ERROR_MESSAGE()
    WHERE LoadID = @LoadID;
    THROW;
END CATCH
GO

SELECT 'Branch' t, COUNT(*) n FROM ods.Branch
UNION ALL SELECT 'Department',     COUNT(*) FROM ods.Department
UNION ALL SELECT 'Doctor',         COUNT(*) FROM ods.Doctor
UNION ALL SELECT 'Insurer',        COUNT(*) FROM ods.Insurer
UNION ALL SELECT 'Patient',        COUNT(*) FROM ods.Patient
UNION ALL SELECT 'PatientAllergy', COUNT(*) FROM ods.PatientAllergy
UNION ALL SELECT 'PatientPolicy',  COUNT(*) FROM ods.PatientPolicy
UNION ALL SELECT 'Appointment',    COUNT(*) FROM ods.Appointment
UNION ALL SELECT 'LabResult',      COUNT(*) FROM ods.LabResult
UNION ALL SELECT 'Prescription',   COUNT(*) FROM ods.Prescription
UNION ALL SELECT 'Bill',           COUNT(*) FROM ods.Bill;