IF OBJECT_ID('dbo.AuditTrigger') IS NULL
  EXEC ('CREATE PROCEDURE dbo.AuditTrigger AS RETURN 0;');
GO

ALTER PROC dbo.AuditTrigger
  @SourceTableName VARCHAR(255),
  @Deletes BIT,
  @Inserts BIT,
  @Updates BIT,  
  @ForceDropRecreate BIT = 1,
  @Schema NVARCHAR(50) = 'dbo'
AS
BEGIN
    SET NOCOUNT ON
    
    DECLARE @sql NVARCHAR(4000),
            @tableName NVARCHAR(255) = '[' + @Schema + '].[' + @SourceTableName + ']',
            @auditTableName NVARCHAR(255) = '[' + @Schema + '].[' + @SourceTableName + '_Audit]',
            @auditTriggerName NVARCHAR(255) = '[' + @Schema + '].[Audit_' + @SourceTableName + ']', 
            @auditTriggerFor NVARCHAR(255) = '',
            @auditTableExists bit,
            @auditTriggerNameExists bit,
            @columnNames NVARCHAR(4000),
            @name nvarchar(4000),
            @originalColumns nvarchar(4000) = '',
            @timestampColumn nvarchar(255),
            @uniqueIdentityColumn nvarchar(255),
            @crlf nvarchar(4) = char(13) + char(10)
    
    DECLARE @columns TABLE(name nvarchar(255))
    
    -- No trigger FOR specified
    IF(@Inserts | @Updates | @Deletes = 0)
    BEGIN
        RAISERROR
        (N'One of @Inserts, @Updates or @Deletes must be specified',
        10, -- Severity.
        1 -- State.
        );
        RETURN
    END		

    SET @auditTableExists = (SELECT COUNT(*) FROM sys.objects WHERE OBJECT_ID = OBJECT_ID(@auditTableName) AND type = 'U')
    SET @auditTriggerNameExists = (SELECT COUNT(*) FROM sys.objects WHERE OBJECT_ID = OBJECT_ID(@auditTriggerName) AND type = 'TR')

    IF(@auditTableExists = 1 OR @auditTriggerNameExists = 1)
    BEGIN
    
        IF(@ForceDropRecreate = 0)
        BEGIN
            RAISERROR
            (N'Audit table AND/OR triggers already exist. Set @ForceDropRecreate = 1 to drop and receate.',
            10, -- Severity.
            1 -- State.
            );
            RETURN
        END		
        
        -- drop the audit table 		
        SET @sql = 'IF EXISTS (SELECT ''x'' FROM sys.objects WHERE OBJECT_ID = OBJECT_ID(''' + @auditTableName + ''') AND type = ''U'') BEGIN DROP TABLE ' + @auditTableName + ' END'		
        EXEC sp_executesql @sql
        
        -- and any triggers
        SET @sql = 'IF EXISTS (SELECT ''x'' FROM sys.objects WHERE OBJECT_ID = OBJECT_ID(''' + @auditTriggerName + ''') AND type = ''TR'') BEGIN DROP TRIGGER ' + @auditTriggerName + ' END'
        EXEC sp_executesql @sql
    END	
    
    -- Work out the triggers required
    IF(@Inserts = 1) SET @auditTriggerFor = @auditTriggerFor + ', INSERT'
    IF(@Updates = 1) SET @auditTriggerFor = @auditTriggerFor + ', UPDATE'
    IF(@Deletes = 1) SET @auditTriggerFor = @auditTriggerFor + ', DELETE'

    SELECT @auditTriggerFor = SUBSTRING(@auditTriggerFor,3,LEN(@auditTriggerFor))

    -- create the new audit table as a select * from the original
    SET @sql = 'SELECT REPLICATE('' '',500) AS transactionid, getdate() AS date, REPLICATE('' '',20) AS operation, * INTO ' + @auditTableName + ' FROM ' + @tableName + ' WHERE 1=2'
    EXEC sp_executesql @sql
    
    -- if it has a timestamp column remove it and add it back in as a binary(8)    
    SELECT @timestampColumn = column_name 
    FROM INFORMATION_SCHEMA.COLUMNS 
    WHERE TABLE_NAME = @SourceTableName 
    AND DATA_TYPE = 'timestamp' 
    AND TABLE_SCHEMA = @Schema

    IF(@timestampColumn IS NOT NULL)
    BEGIN	
        SET @sql = 'ALTER TABLE ' + @auditTableName + ' DROP COLUMN ' + @timestampColumn
        EXEC sp_executesql @sql
        
        SET @sql = 'ALTER TABLE ' + @auditTableName + ' ADD ' + @timestampColumn + ' binary(8)'
        EXEC sp_executesql @sql
    END	
        
    -- Turn off uniqueidentity columns		
    SELECT @uniqueIdentityColumn = column_name 
    FROM INFORMATION_SCHEMA.COLUMNS 
    WHERE TABLE_NAME = @SourceTableName 
    AND COLUMNPROPERTY(OBJECT_ID(TABLE_NAME), COLUMN_NAME, 'IsIdentity') = 1 
    AND TABLE_SCHEMA = @Schema

    IF(@uniqueIdentityColumn IS NOT NULL)
    BEGIN	
        SET @sql = 'ALTER TABLE ' + @auditTableName + ' DROP COLUMN ' + @uniqueIdentityColumn
        EXEC sp_executesql @sql
        
        SET @sql = 'ALTER TABLE ' + @auditTableName + ' ADD ' + @uniqueIdentityColumn + ' int'
        EXEC sp_executesql @sql
    END	
    
    -- Get a list of all the columns comma delimited
    SELECT @originalColumns = ',' + STUFF((SELECT  ', [' + column_name + ']'
    FROM INFORMATION_SCHEMA.COLUMNS 
    WHERE TABLE_NAME = @SourceTableName 
    AND TABLE_SCHEMA = @schema 
    ORDER BY ORDINAL_POSITION
    FOR XML PATH('')), 1, 1, '')

    -- we also need the original columns prefixed with i. to do a select on the changed data
    SET @columnNames = REPLACE(@originalColumns,', ',',i.')	   
    
    -- generate the SQL for the trigger
    SET @sql =        'CREATE TRIGGER ' + @auditTriggerName + ' ON ' + @tableName + ' FOR ' + @auditTriggerFor + ' AS ' + @crlf
    SET @sql = @sql + 'BEGIN ' + @crlf    
    SET @sql = @sql + ' SET NOCOUNT ON' + @crlf    
    SET @sql = @sql + ' DECLARE @tranId NVARCHAR(20), ' + @crlf
    SET @sql = @sql + '         @operation NVARCHAR(20), ' + @crlf
    SET @sql = @sql + '         @subOperation NVARCHAR(20), ' + @crlf
    SET @sql = @sql + '         @name nvarchar(4000) ' + @crlf        
    SET @sql = @sql + ' SELECT @tranId = transaction_id FROM sys.dm_tran_current_transaction ' + @crlf    
    SET @sql = @sql + ' SELECT * INTO #ins FROM inserted ' + @crlf
    SET @sql = @sql + ' SELECT * INTO #del FROM deleted ' + @crlf
    SET @sql = @sql + ' IF EXISTS (SELECT ''x'' FROM #ins) ' + @crlf
    SET @sql = @sql + ' BEGIN ' + @crlf
    SET @sql = @sql + '  IF EXISTS (SELECT ''x'' FROM #del) ' + @crlf
    SET @sql = @sql + '  BEGIN ' + @crlf
    SET @sql = @sql + '   SELECT @operation = ''BEFOREUPDATE'' ' + @crlf
    SET @sql = @sql + '   SELECT @subOperation = ''AFTERUPDATE'' ' + @crlf
    SET @sql = @sql + '  END ' + @crlf
    SET @sql = @sql + '  ELSE ' + @crlf
    SET @sql = @sql + '	 BEGIN ' + @crlf
    SET @sql = @sql + '   SELECT @operation = ''INSERT'' ' + @crlf
    SET @sql = @sql + '  END ' + @crlf
    SET @sql = @sql + ' END ' + @crlf
    SET @sql = @sql + ' ELSE IF EXISTS (SELECT * FROM deleted) ' + @crlf
    SET @sql = @sql + ' BEGIN ' + @crlf
    SET @sql = @sql + '  SELECT @operation = ''DELETE'' ' + @crlf
    SET @sql = @sql + ' END ' + @crlf    
    SET @sql = @sql + ' IF(@operation = ''DELETE'' OR @operation = ''BEFOREUPDATE'') ' + @crlf
    SET @sql = @sql + ' BEGIN ' + @crlf
    SET @sql = @sql + '  INSERT INTO ' + @auditTableName + ' (transactionid, date, operation' + @originalColumns + ') SELECT @tranid, SYSUTCDATETIME(), @operation' + @columnNames + ' FROM #del i' + @crlf
    SET @sql = @sql + ' END ' + @crlf
    SET @sql = @sql + ' IF(@operation = ''INSERT'' OR @operation = ''BEFOREUPDATE'')' + @crlf
    SET @sql = @sql + ' BEGIN ' + @crlf
    SET @sql = @sql + '  INSERT INTO ' + @auditTableName + ' (transactionid, date, operation' + @originalColumns + ') SELECT @tranid, SYSUTCDATETIME(), IsNull(@suboperation, @operation)' + @columnNames + ' FROM #ins i' + @crlf  
    SET @sql = @sql + ' END ' + @crlf		
    SET @sql = @sql + 'END	 ' + @crlf
   
    --print @sql

    EXEC sp_executesql @sql
END
