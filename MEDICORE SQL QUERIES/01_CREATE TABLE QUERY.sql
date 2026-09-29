

IF SCHEMA_ID('stg')   IS NULL EXEC('CREATE SCHEMA stg');
IF SCHEMA_ID('ods')   IS NULL EXEC('CREATE SCHEMA ods');
IF SCHEMA_ID('dw')    IS NULL EXEC('CREATE SCHEMA dw');
IF SCHEMA_ID('audit') IS NULL EXEC('CREATE SCHEMA audit');
GO

DROP TABLE IF EXISTS stg.HospitalRaw;
GO

CREATE TABLE stg.HospitalRaw (
    RecordID            NVARCHAR(50)   NULL,
    ERPTransactionID    NVARCHAR(100)  NULL,
    ERPModule           NVARCHAR(100)  NULL,
    BranchCode          NVARCHAR(50)   NULL,
    FiscalYear          NVARCHAR(50)   NULL,
    FiscalQuarter       NVARCHAR(50)   NULL,
    CreatedBy           NVARCHAR(100)  NULL,
    PatientID           NVARCHAR(50)   NULL,
    PatientName         NVARCHAR(200)  NULL,
    DateOfBirth         NVARCHAR(50)   NULL,
    Gender              NVARCHAR(50)   NULL,
    BloodGroup          NVARCHAR(20)   NULL,
    Phone               NVARCHAR(50)   NULL,
    Email               NVARCHAR(200)  NULL,
    Allergies           NVARCHAR(500)  NULL,
    [Address]           NVARCHAR(500)  NULL,
    City                NVARCHAR(100)  NULL,
    DoctorID            NVARCHAR(50)   NULL,
    DoctorName          NVARCHAR(200)  NULL,
    Specialization      NVARCHAR(100)  NULL,
    DepartmentID        NVARCHAR(50)   NULL,
    DepartmentName      NVARCHAR(100)  NULL,
    ConsultationFeeINR  NVARCHAR(50)   NULL,
    AppointmentID       NVARCHAR(50)   NULL,
    AppointmentDate     NVARCHAR(50)   NULL,
    AppointmentTime     NVARCHAR(50)   NULL,
    AppointmentStatus   NVARCHAR(50)   NULL,
    ChiefComplaint      NVARCHAR(500)  NULL,
    Diagnosis           NVARCHAR(500)  NULL,
    ClinicalNotes       NVARCHAR(MAX)  NULL,
    LabTestName         NVARCHAR(200)  NULL,
    LabResult           NVARCHAR(200)  NULL,
    ReferenceRange      NVARCHAR(200)  NULL,
    IsAbnormal          NVARCHAR(20)   NULL,
    MedicineName        NVARCHAR(200)  NULL,
    Dosage              NVARCHAR(100)  NULL,
    Frequency           NVARCHAR(100)  NULL,
    DurationDays        NVARCHAR(50)   NULL,
    LabChargeINR        NVARCHAR(50)   NULL,
    MedicineChargeINR   NVARCHAR(50)   NULL,
    SubtotalINR         NVARCHAR(50)   NULL,
    DiscountINR         NVARCHAR(50)   NULL,
    GSTAmountINR        NVARCHAR(50)   NULL,
    TotalAmountINR      NVARCHAR(50)   NULL,
    PaymentMode         NVARCHAR(50)   NULL,
    PaymentStatus       NVARCHAR(50)   NULL,
    InsuranceProvider   NVARCHAR(200)  NULL,
    PolicyNumber        NVARCHAR(100)  NULL,
    CoverageLimitINR    NVARCHAR(50)   NULL,
    LoadID              INT            NULL,
    SourceFileName      NVARCHAR(260)  NULL,
    LoadedAt            DATETIME2(0)   NOT NULL DEFAULT SYSDATETIME()
);
GO

SELECT COUNT(*) AS ColumnCount
FROM sys.columns WHERE object_id = OBJECT_ID('stg.HospitalRaw');



TRUNCATE TABLE stg.HospitalRaw;


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



