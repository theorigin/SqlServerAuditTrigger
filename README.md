# SqlServerAuditTrigger
Creates audit tables and audit triggers 

A cheap version of CDC (https://social.technet.microsoft.com/wiki/contents/articles/7726.sql-server-change-data-capture-cdc.aspx)

#### If you're using SQL Server 2016 or later then I would recommend taking a look at Temporal table (https://learn.microsoft.com/en-us/sql/relational-databases/tables/temporal-tables?view=sql-server-ver16) - they are a database feature that brings built-in support for providing information about data stored in the table at any point in time. ####

### Usage 

```sql
EXEC [dbo].[AuditTrigger] @SourceTableName = N'<table name>', @Deletes = 1, @Inserts = 1, @Updates = 1, @ForceDropRecreate = 1
```

This will create an audit table for the table specified called `<table name>_Audit`. It will contain columns that match the existing table along with 3 new columns called `transactionid`, `date` and `operation`. Triggers will be created on `<table name>` for `INSERT`, `DELETE` or `UPDATE` operations.

If you add a new column to a table you can re-run the above statement to re-create the audit table and triggers and include the new column. 

!!! **WARNING** The existing audit table will be deleted if you add `@ForceDropRecreate = 1` !!!



### Parameters

| Parameter          | Description                                                  |
| ------------------ | ------------------------------------------------------------ |
| @SourceTableName   | The table you want to audit                                  |
| @Deletes           | 0 or 1 to indicate if deletes should be audited              |
| @Inserts           | 0 or 1 to indicate if inserts should be audited              |
| @Updates           | 0 or 1 to indicate if updates should be audited              |
| @ForceDropRecreate | 0 or 1. If not specified and audit table or trigger exists you'll get an error |
| @Schema            | If you need to specify schema other than dbo                 |







