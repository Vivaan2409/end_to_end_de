USE MediCoreDW;
GO

IF OBJECT_ID('audit.LoadControl') IS NULL
CREATE TABLE audit.LoadControl (
    LoadID          INT IDENTITY(1,1) PRIMARY KEY,
    LoadName        VARCHAR(100)   NOT NULL,
    SourceSystem    VARCHAR(50)    NOT NULL,
    StartedAt       DATETIME2(0)   NOT NULL DEFAULT SYSDATETIME(),
    CompletedAt     DATETIME2(0)   NULL,
    RowsRead        INT            NULL,
    RowsInserted    INT            NULL,
    RowsRejected    INT            NULL,
    LoadStatus      VARCHAR(20)    NOT NULL DEFAULT 'RUNNING',
    ErrorMessage    NVARCHAR(4000) NULL,
    CONSTRAINT CK_LoadControl_Status
        CHECK (LoadStatus IN ('RUNNING','SUCCESS','FAILED','ROLLED_BACK'))
);
GO

IF OBJECT_ID('audit.RejectedRows') IS NULL
CREATE TABLE audit.RejectedRows (
    RejectID        INT IDENTITY(1,1) PRIMARY KEY,
    LoadID          INT           NOT NULL,
    SourceTable     VARCHAR(100)  NOT NULL,
    SourceRecordID  VARCHAR(50)   NULL,
    RuleCode        VARCHAR(30)   NOT NULL,
    RuleDescription VARCHAR(300)  NOT NULL,
    ColumnName      VARCHAR(100)  NULL,
    OffendingValue  NVARCHAR(500) NULL,
    RejectedAt      DATETIME2(0)  NOT NULL DEFAULT SYSDATETIME(),
    CONSTRAINT FK_RejectedRows_Load FOREIGN KEY (LoadID)
        REFERENCES audit.LoadControl(LoadID)
);
GO

IF OBJECT_ID('audit.DQResults') IS NULL
CREATE TABLE audit.DQResults (
    DQResultID      INT IDENTITY(1,1) PRIMARY KEY,
    LoadID          INT           NULL,
    TestCode        VARCHAR(40)   NOT NULL,
    TestName        VARCHAR(200)  NOT NULL,
    Layer           VARCHAR(10)   NOT NULL,
    ExpectedValue   VARCHAR(100)  NULL,
    ActualValue     VARCHAR(100)  NULL,
    RowsFailed      INT           NULL,
    TestResult      VARCHAR(10)   NOT NULL,
    RunAt           DATETIME2(0)  NOT NULL DEFAULT SYSDATETIME(),
    CONSTRAINT CK_DQResults_Result CHECK (TestResult IN ('PASS','FAIL','WARN'))
);
GO


USE MediCoreDW;
GO

INSERT INTO audit.LoadControl (LoadName, SourceSystem, RowsRead, RowsInserted, LoadStatus, CompletedAt)
VALUES ('CSV_TO_STG', 'Oracle ERP', 5000,
        (SELECT COUNT(*) FROM stg.HospitalRaw), 'SUCCESS', SYSDATETIME());

UPDATE stg.HospitalRaw
SET LoadID = (SELECT MAX(LoadID) FROM audit.LoadControl),
    SourceFileName = 'hospital_raw.csv';

SELECT * FROM audit.LoadControl;