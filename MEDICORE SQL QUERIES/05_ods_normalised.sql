USE MediCoreDW;
GO

-- Drop in FK-safe order (children before parents)
DROP TABLE IF EXISTS ods.Bill;
DROP TABLE IF EXISTS ods.Prescription;
DROP TABLE IF EXISTS ods.LabResult;
DROP TABLE IF EXISTS ods.Appointment;
DROP TABLE IF EXISTS ods.PatientPolicy;
DROP TABLE IF EXISTS ods.PatientAllergy;
DROP TABLE IF EXISTS ods.Patient;
DROP TABLE IF EXISTS ods.Doctor;
DROP TABLE IF EXISTS ods.Department;
DROP TABLE IF EXISTS ods.Insurer;
DROP TABLE IF EXISTS ods.Branch;
GO

/* ---------- MASTER / REFERENCE ---------- */
CREATE TABLE ods.Branch (
    BranchCode      VARCHAR(10)   NOT NULL,
    BranchName      VARCHAR(100)  NULL,
    City            VARCHAR(100)  NULL,
    LoadID          INT           NULL,
    CONSTRAINT PK_Branch PRIMARY KEY (BranchCode) 

--CONSTRAINT PK_Branch          -- give the constraint this name
--PRIMARY KEY                   -- of type: primary key
--(BranchCode)                  -- on this column
);
GO

CREATE TABLE ods.Department (
    DepartmentID    INT           NOT NULL,
    DepartmentName  VARCHAR(100)  NOT NULL,
    LoadID          INT           NULL,
    CONSTRAINT PK_Department PRIMARY KEY (DepartmentID),
    CONSTRAINT UQ_Department_Name UNIQUE (DepartmentName)   -- ALTERNATE KEY
);
GO

CREATE TABLE ods.Doctor (
    DoctorID            VARCHAR(10)   NOT NULL,
    DoctorName          VARCHAR(200)  NOT NULL,
    Specialization      VARCHAR(100)  NULL,
    DepartmentID        INT           NULL,
    StandardConsultFee  DECIMAL(10,2) NULL,
    LoadID              INT           NULL,
    CONSTRAINT PK_Doctor PRIMARY KEY (DoctorID),
    CONSTRAINT FK_Doctor_Department FOREIGN KEY (DepartmentID)
        REFERENCES ods.Department(DepartmentID)
);
GO

CREATE TABLE ods.Insurer (
    InsurerID       INT IDENTITY(1,1) NOT NULL,
    InsurerName     VARCHAR(200)  NOT NULL,
    LoadID          INT           NULL,
    CONSTRAINT PK_Insurer PRIMARY KEY (InsurerID),
    CONSTRAINT UQ_Insurer_Name UNIQUE (InsurerName)
);
GO

/* ---------- PATIENT ---------- */
CREATE TABLE ods.Patient (
    PatientID       VARCHAR(20)   NOT NULL,
    PatientName     VARCHAR(200)  NOT NULL,
    DateOfBirth     DATE          NULL,
    Gender          VARCHAR(10)   NULL,
    BloodGroup      VARCHAR(5)    NULL,
    Phone           VARCHAR(20)   NULL,
    Email           VARCHAR(200)  NULL,
    AddressLine     VARCHAR(500)  NULL,
    City            VARCHAR(100)  NULL,
    LoadID          INT           NULL,
    EffectiveFrom   DATETIME2(0)  NOT NULL DEFAULT SYSDATETIME(),
    CONSTRAINT PK_Patient PRIMARY KEY (PatientID),
    CONSTRAINT CK_Patient_Gender
        CHECK (Gender IN ('Male','Female','Other') OR Gender IS NULL),
    CONSTRAINT CK_Patient_BloodGroup
        CHECK (BloodGroup IN ('A+','A-','B+','B-','AB+','AB-','O+','O-')
               OR BloodGroup IS NULL),
    CONSTRAINT CK_Patient_DOB
        CHECK (DateOfBirth IS NULL OR DateOfBirth <= CAST(SYSDATETIME() AS DATE))

		-- this contraints checks if the date > Today - Future dates it does not take
		-- insertion failes
);
GO

-- 1NF FIX: one row per allergy instead of a multi-value cell
CREATE TABLE ods.PatientAllergy (
    PatientID       VARCHAR(20)   NOT NULL,
    AllergyName     VARCHAR(100)  NOT NULL,
    LoadID          INT           NULL,
    CONSTRAINT PK_PatientAllergy PRIMARY KEY (PatientID, AllergyName),  -- COMPOSITE PK
    CONSTRAINT FK_PatientAllergy_Patient FOREIGN KEY (PatientID)
        REFERENCES ods.Patient(PatientID)
);
GO

-- 3NF FIX: coverage limit belongs to the policy, not the insurer
CREATE TABLE ods.PatientPolicy (
    PatientID       VARCHAR(20)   NOT NULL,
    PolicyNumber    VARCHAR(50)   NOT NULL,
    InsurerID       INT           NOT NULL,
    CoverageLimit   DECIMAL(12,2) NULL,
    LoadID          INT           NULL,
    CONSTRAINT PK_PatientPolicy PRIMARY KEY (PatientID, PolicyNumber),  -- COMPOSITE PK
    CONSTRAINT FK_PatientPolicy_Patient FOREIGN KEY (PatientID)
        REFERENCES ods.Patient(PatientID),
    CONSTRAINT FK_PatientPolicy_Insurer FOREIGN KEY (InsurerID)
        REFERENCES ods.Insurer(InsurerID),
    CONSTRAINT CK_PatientPolicy_Limit
        CHECK (CoverageLimit IS NULL OR CoverageLimit >= 0)
);
GO

/* ---------- TRANSACTION ---------- */
CREATE TABLE ods.Appointment (
    AppointmentID       VARCHAR(20)   NOT NULL,
    PatientID           VARCHAR(20)   NOT NULL,
    DoctorID            VARCHAR(10)   NOT NULL,
    DepartmentID        INT           NOT NULL,
    BranchCode          VARCHAR(10)   NULL,
    AppointmentDate     DATE          NOT NULL,
    AppointmentTime     TIME(0)       NULL,
    AppointmentStatus   VARCHAR(20)   NOT NULL,
    ChiefComplaint      VARCHAR(500)  NULL,
    Diagnosis           VARCHAR(500)  NULL,
    ClinicalNotes       NVARCHAR(MAX) NULL,
    ConsultationFee     DECIMAL(10,2) NULL,
    ERPTransactionID    VARCHAR(50)   NULL,
    ERPModule           VARCHAR(50)   NULL,
    CreatedBy           VARCHAR(50)   NULL,
    LoadID              INT           NULL,
    CONSTRAINT PK_Appointment PRIMARY KEY (AppointmentID),
    CONSTRAINT FK_Appointment_Patient FOREIGN KEY (PatientID)
        REFERENCES ods.Patient(PatientID),
    CONSTRAINT FK_Appointment_Doctor FOREIGN KEY (DoctorID)
        REFERENCES ods.Doctor(DoctorID),
    CONSTRAINT FK_Appointment_Department FOREIGN KEY (DepartmentID)
        REFERENCES ods.Department(DepartmentID),
    CONSTRAINT FK_Appointment_Branch FOREIGN KEY (BranchCode)
        REFERENCES ods.Branch(BranchCode),
    CONSTRAINT CK_Appointment_Status
        CHECK (AppointmentStatus IN ('scheduled','completed','cancelled','no_show')),
    CONSTRAINT CK_Appointment_Fee
        CHECK (ConsultationFee IS NULL OR ConsultationFee >= 0)
);
GO

CREATE NONCLUSTERED INDEX IX_Appointment_Date    ON ods.Appointment (AppointmentDate);
CREATE NONCLUSTERED INDEX IX_Appointment_Patient ON ods.Appointment (PatientID);
CREATE NONCLUSTERED INDEX IX_Appointment_Doctor  ON ods.Appointment (DoctorID);
GO

CREATE TABLE ods.LabResult (
    LabResultID     INT IDENTITY(1,1) NOT NULL,
    AppointmentID   VARCHAR(20)   NOT NULL,
    TestName        VARCHAR(200)  NOT NULL,
    ResultValue     VARCHAR(200)  NULL,
    ReferenceRange  VARCHAR(200)  NULL,
    IsAbnormal      BIT           NULL,
    LabCharge       DECIMAL(10,2) NULL,
    LoadID          INT           NULL,
    CONSTRAINT PK_LabResult PRIMARY KEY (LabResultID),
    CONSTRAINT FK_LabResult_Appointment FOREIGN KEY (AppointmentID)
        REFERENCES ods.Appointment(AppointmentID),
    CONSTRAINT CK_LabResult_Charge CHECK (LabCharge IS NULL OR LabCharge >= 0)
);
GO

CREATE TABLE ods.Prescription (
    PrescriptionID  INT IDENTITY(1,1) NOT NULL,
    AppointmentID   VARCHAR(20)   NOT NULL,
    MedicineName    VARCHAR(200)  NOT NULL,
    Dosage          VARCHAR(100)  NULL,
    Frequency       VARCHAR(100)  NULL,
    DurationDays    SMALLINT      NULL,
    MedicineCharge  DECIMAL(10,2) NULL,
    LoadID          INT           NULL,
    CONSTRAINT PK_Prescription PRIMARY KEY (PrescriptionID),
    CONSTRAINT FK_Prescription_Appointment FOREIGN KEY (AppointmentID)
        REFERENCES ods.Appointment(AppointmentID),
    CONSTRAINT CK_Prescription_Duration
        CHECK (DurationDays IS NULL OR DurationDays BETWEEN 0 AND 365),
    CONSTRAINT CK_Prescription_Charge
        CHECK (MedicineCharge IS NULL OR MedicineCharge >= 0)
);
GO

CREATE TABLE ods.Bill (
    BillID          INT IDENTITY(1,1) NOT NULL,
    AppointmentID   VARCHAR(20)   NOT NULL,
    ConsultationFee DECIMAL(10,2) NOT NULL DEFAULT 0,
    LabCharge       DECIMAL(10,2) NOT NULL DEFAULT 0,
    MedicineCharge  DECIMAL(10,2) NOT NULL DEFAULT 0,
    Subtotal        DECIMAL(12,2) NOT NULL,
    Discount        DECIMAL(12,2) NOT NULL DEFAULT 0,
    GSTAmount       DECIMAL(12,2) NOT NULL DEFAULT 0,
    TotalAmount     DECIMAL(12,2) NOT NULL,
    PaymentMode     VARCHAR(30)   NULL,
    PaymentStatus   VARCHAR(20)   NULL,
    -- assertion as a computed column, NOT a constraint: the defect must load
    ExpectedTotal AS (Subtotal - Discount + GSTAmount) PERSISTED,
    BillIsValid   AS (CASE WHEN ABS(TotalAmount - (Subtotal - Discount + GSTAmount)) <= 1.00
                           THEN CAST(1 AS BIT) ELSE CAST(0 AS BIT) END) PERSISTED,
    LoadID          INT           NULL,
    CONSTRAINT PK_Bill PRIMARY KEY (BillID),
    CONSTRAINT UQ_Bill_Appointment UNIQUE (AppointmentID),
    CONSTRAINT FK_Bill_Appointment FOREIGN KEY (AppointmentID)
        REFERENCES ods.Appointment(AppointmentID),
    CONSTRAINT CK_Bill_Discount    CHECK (Discount >= 0),
    CONSTRAINT CK_Bill_DiscountCap CHECK (Discount <= Subtotal),
    CONSTRAINT CK_Bill_Total       CHECK (TotalAmount >= 0),
    CONSTRAINT CK_Bill_PaymentStatus
        CHECK (PaymentStatus IN ('paid','partial','pending') OR PaymentStatus IS NULL),
    CONSTRAINT CK_Bill_PaymentMode
        CHECK (PaymentMode IN ('Cash','Credit Card','Debit Card',
                               'Net Banking','UPI','Insurance') OR PaymentMode IS NULL)
);
GO

CREATE NONCLUSTERED INDEX IX_Bill_Valid ON ods.Bill (BillIsValid) INCLUDE (TotalAmount);
GO

-- verify
SELECT s.name AS SchemaName, t.name AS TableName
FROM sys.tables t JOIN sys.schemas s ON s.schema_id = t.schema_id
WHERE s.name = 'ods' ORDER BY t.name;