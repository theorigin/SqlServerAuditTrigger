CREATE PROC [dbo].[AuditTrigger] 
  @SourceTableName varchar(255),
  @Deletes bit,
  @Inserts bit,
  @Updates bit,  
  @ForceDropRecreate bit = 1,
  @BackupAuditTable bit = 1
AS
BEGIN
    SET NOCOUNT ON
    
    DECLARE @sql NVARCHAR(4000),
            @tableName NVARCHAR(255) = @SourceTableName,
            @auditTableName NVARCHAR(255) = @SourceTableName + '_Audit',
            @auditTriggerName NVARCHAR(255) = 'Audit_' + @SourceTableName,
            @auditTriggerFor NVARCHAR(255) = '',
            @auditTableExists bit,
            @auditTriggerNameExists bit,
            @columnNames NVARCHAR(4000),
            @name nvarchar(4000),
            @originalColumns nvarchar(4000) = '',
            @timestampColumn nvarchar(255),
            @uniqueIdentityColumn nvarchar(255)
    
    DECLARE @columns TABLE(name nvarchar(255))
    
    SET @auditTableExists = (SELECT COUNT(*) FROM information_schema.tables WHERE table_name = @auditTableName)
    SET @auditTriggerNameExists = (SELECT COUNT(*) FROM sys.triggers WHERE name IN (@auditTriggerName))
    
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
        SET @sql = 'IF EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(''' + @auditTableName + ''') AND type = ''U'') BEGIN DROP TABLE ' + @auditTableName + ' END'
        EXEC sp_executesql @sql
        
        -- and any triggers
        SET @sql = 'IF EXISTS (SELECT * FROM sys.objects WHERE object_id = OBJECT_ID(''' + @auditTriggerName + ''') AND type = ''TR'') BEGIN DROP TRIGGER ' + @auditTriggerName + ' END'
        EXEC sp_executesql @sql
    END	
    
    -- create the new table as a select * from the original
    SET @sql = 'SELECT REPLICATE('' '',500) AS transactionid, getdate() AS date, REPLICATE('' '',20) AS operation, * INTO ' + @auditTableName + ' FROM ' + @tableName + ' WHERE 1=2'
    --print @sql
    EXEC sp_executesql @sql
    
    -- if it has a timestamp column remove it and add it back in as a binary(8)    
    SELECT @timestampColumn = column_name FROM information_schema.COLUMNS WHERE table_name = @tableName and data_type = 'timestamp'

    IF(@timestampColumn IS NOT NULL)
    BEGIN	
        SET @sql = 'ALTER TABLE ' + @auditTableName + ' DROP COLUMN ' + @timestampColumn
        EXEC sp_executesql @sql
        
        SET @sql = 'ALTER TABLE ' + @auditTableName + ' ADD ' + @timestampColumn + ' binary(8)'
        EXEC sp_executesql @sql
    END	
        
  -- Turn off uniqueidentity columns		
  SELECT @uniqueIdentityColumn = column_name FROM information_schema.COLUMNS WHERE table_name = @tableName and COLUMNPROPERTY(object_id(TABLE_NAME), COLUMN_NAME, 'IsIdentity') = 1
  IF(@uniqueIdentityColumn IS NOT NULL)
    BEGIN	
        SET @sql = 'ALTER TABLE ' + @auditTableName + ' DROP COLUMN ' + @uniqueIdentityColumn
        EXEC sp_executesql @sql
        
        SET @sql = 'ALTER TABLE ' + @auditTableName + ' ADD ' + @uniqueIdentityColumn + ' int'
        EXEC sp_executesql @sql
    END	
    
    INSERT INTO @columns (name)
        SELECT column_name FROM information_schema.COLUMNS WHERE table_name = @tableName ORDER BY ordinal_position

    WHILE EXISTS (SELECT * FROM @columns)
    BEGIN
        SELECT TOP 1 @name = name FROM @columns
        
        SET @originalColumns = @originalColumns + ', ' + @name 		

        DELETE @columns WHERE name = @name
    END	
    
    SET @columnNames = replace(replace(@originalColumns,' ',''),',',' ,i.')
        
    IF(@Inserts = 1) SET @auditTriggerFor = @auditTriggerFor + ' INSERT'

    IF(@Updates = 1) SET @auditTriggerFor = @auditTriggerFor + ', UPDATE'
        
    IF(@Deletes = 1) SET @auditTriggerFor = @auditTriggerFor + ', DELETE'
    
    --print @auditTriggerFor
    
    SET @sql =        'CREATE TRIGGER [dbo].[' + @auditTriggerName + '] on [dbo].[' + @tableName + '] FOR ' + @auditTriggerFor + ' AS ' + char(13) + char(10)
    SET @sql = @sql + 'BEGIN ' + char(13) + char(10)
    
    SET @sql = @sql + 'IF (@@ROWCOUNT  = 0)  RETURN ' + char(13) + char(10)
    
    SET @sql = @sql + 'DECLARE @tranId NVARCHAR(20), ' + char(13) + char(10)
    SET @sql = @sql + '		   @operation NVARCHAR(20), ' + char(13) + char(10)
    SET @sql = @sql + '		   @subOperation NVARCHAR(20), ' + char(13) + char(10)
    SET @sql = @sql + '        @name nvarchar(4000) ' + char(13) + char(10)
    SET @sql = @sql + 'DECLARE @sqlStatements TABLE(name nvarchar(4000)) ' + char(13) + char(10)
    
    SET @sql = @sql + 'SELECT @tranId = transaction_id FROM sys.dm_tran_current_transaction ' + char(13) + char(10)
    
    SET @sql = @sql + 'SELECT * INTO #ins FROM inserted ' + char(13) + char(10)
    SET @sql = @sql + 'SELECT * INTO #del FROM deleted ' + char(13) + char(10)

    SET @sql = @sql + 'IF EXISTS (SELECT * FROM inserted) ' + char(13) + char(10)
    SET @sql = @sql + 'BEGIN ' + char(13) + char(10)
    SET @sql = @sql + '	IF EXISTS (SELECT * FROM deleted) ' + char(13) + char(10)
    SET @sql = @sql + '	BEGIN ' + char(13) + char(10)
    SET @sql = @sql + '		SELECT @operation = ''BEFOREUPDATE'' ' + char(13) + char(10)
    SET @sql = @sql + '		SELECT @subOperation = ''AFTERUPDATE'' ' + char(13) + char(10)
    SET @sql = @sql + '	END ' + char(13) + char(10)
    SET @sql = @sql + '	ELSE ' + char(13) + char(10)
    SET @sql = @sql + '	BEGIN ' + char(13) + char(10)
    SET @sql = @sql + '		SELECT @operation = ''INSERT'' ' + char(13) + char(10)
    SET @sql = @sql + '	END ' + char(13) + char(10)
    SET @sql = @sql + 'END ' + char(13) + char(10)
    SET @sql = @sql + 'ELSE IF EXISTS (SELECT * FROM deleted) ' + char(13) + char(10)
    SET @sql = @sql + 'BEGIN ' + char(13) + char(10)
    SET @sql = @sql + '	SELECT @operation = ''DELETE'' ' + char(13) + char(10)
    SET @sql = @sql + 'END ' + char(13) + char(10)
        
    SET @sql = @sql + 'IF(@operation = ''INSERT'' OR @operation = ''BEFOREUPDATE'') INSERT INTO @sqlStatements (name) SELECT ''INSERT INTO ' + @auditTableName + ' (transactionid, date, operation' + @originalColumns + ') SELECT '' + @tranid + '', getdate(), '''''' + IsNull(@suboperation, @operation) + '''''' ' + @columnNames + ' FROM #ins i '' ' + char(13) + char(10)  
    SET @sql = @sql + 'IF(@operation = ''DELETE'' OR @operation = ''BEFOREUPDATE'') INSERT INTO @sqlStatements (name) SELECT ''INSERT INTO ' + @auditTableName + ' (transactionid, date, operation' + @originalColumns + ') SELECT '' + @tranid + '', getdate(), '''''' + @operation + '''''' ' + @columnNames + ' FROM #del i '' ' + char(13) + char(10)
        
    SET @sql = @sql + 'WHILE EXISTS (SELECT * FROM @sqlStatements) ' + char(13) + char(10)
    SET @sql = @sql + 'BEGIN ' + char(13) + char(10)
    SET @sql = @sql + '	SELECT TOP 1 @name = name FROM @sqlStatements ' + char(13) + char(10)
    SET @sql = @sql + '	EXEC sp_executesql @name ' + char(13) + char(10)
    SET @sql = @sql + '	DELETE @sqlStatements WHERE name = @name ' + char(13) + char(10)
    SET @sql = @sql + 'END	 ' + char(13) + char(10)
    SET @sql = @sql + 'END	 ' + char(13) + char(10)
    
--	print @sql
    
    EXEC sp_executesql @sql
END

