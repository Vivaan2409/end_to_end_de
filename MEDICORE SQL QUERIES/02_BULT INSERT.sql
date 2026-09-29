USE MediCoreDW;
GO

CREATE OR ALTER VIEW stg.vw_HospitalRaw_Load AS
SELECT RecordID, ERPTransactionID, ERPModule, BranchCode, FiscalYear,
       FiscalQuarter, CreatedBy, PatientID, PatientName, DateOfBirth,
       Gender, BloodGroup, Phone, Email, Allergies, [Address], City,
       DoctorID, DoctorName, Specialization, DepartmentID, DepartmentName,
       ConsultationFeeINR, AppointmentID, AppointmentDate, AppointmentTime,
       AppointmentStatus, ChiefComplaint, Diagnosis, ClinicalNotes,
       LabTestName, LabResult, ReferenceRange, IsAbnormal, MedicineName,
       Dosage, Frequency, DurationDays, LabChargeINR, MedicineChargeINR,
       SubtotalINR, DiscountINR, GSTAmountINR, TotalAmountINR,
       PaymentMode, PaymentStatus, InsuranceProvider, PolicyNumber,
       CoverageLimitINR
FROM stg.HospitalRaw;
GO

TRUNCATE TABLE stg.HospitalRaw;
GO

BULK INSERT stg.vw_HospitalRaw_Load
FROM 'C:\MediCore\hospital_raw.csv'
WITH (
    FORMAT          = 'CSV',
    FIRSTROW        = 2,
    FIELDTERMINATOR = ',',
    ROWTERMINATOR   = '0x0d0a',
    CODEPAGE        = '65001',
    TABLOCK,
    MAXERRORS       = 0
);

SELECT COUNT(*) AS RowsLoaded FROM stg.HospitalRaw;
SELECT TOP 5 * FROM stg.HospitalRaw;