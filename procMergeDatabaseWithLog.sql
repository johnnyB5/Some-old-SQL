USE DataValidation
GO



/*
-- ========================================================
-- Proc Name:	[utility].[ProcMergeDatabaseMergeLog]
-- Author:		John Berry
-- Create Date: 2021-11-01
-- Description:	Dynamically merge a database schema into another for the same table names/structure.  
				AKA Fun with string concatenation to build standard code.
				Match on Unique Index first non clustered unique index (surogate load key), otherwise match on clustered unique index (pk).
				Filter by ModifiedDate, passed as a default parameter for filter clause.
-- Func Params:	@inSourceLinkedServer - linked server from which to copy.  Can be blank and will default to null for local database server data replication.
				@inSourceDatabaseName - Source Database to copy data from. ie 'Pft.ClientData' in ods.
				@inSourceSchemaName - Source schema of database to copy.  ie 'dbo', 'tmp', 'utility' etc... Now nullable and will load matching schemas from source to destination.
				@inTargetDatabaseName - Target database (on the same server as this procedure resides) ie 'barn-warehouse'.
				@inTargetSchemaName - Target schema within the target database to refresh. ie 'pft.clientdata' schema within 'barn-warehouse'.  Now nullable and will load matching schemas from source to destination.
				@inTableName  -  Defaults to null.  Pass a value if you would like to run the procedure for a specific table. If wildcard is passed in the string then a like clause on the tables will be used.
				@inIgnoreTableList - defaults to null.  Pass a value of comma separated table names (table name only ie 'sub_affiliates, buyer_contact, affiliate_contact,traffic,source_affiliate_summary,site_offer_summary,ping_post,leads_by_buyer,export_offers,export_campaigns,export_buyer,event_conversion,caps,affiliates' )
				@inLookBackFactor - defaults to .5 decimal parameter of total time to look back in equation. 
								The starting time threshold is set at the end time of the last run of the table minus the total time it took to run multiplied by this factor.  
								EX: Last time this ran it took 30 minutes to process so we'll use the endtime threshold of the last run minus 15 minutes if a factor of .5 is used.  30 minutes if a factor of 1 is used. THe larger the number the larger the scan back occurs.
				@inSyncTimeColumnName - varchar parameter defaulted to "ModifiedDate".  This is the datetime2 column your application will update to the current time on any transaction.
				@inCompareDaysLookBack - total number of days to grab records for when building compare queries.  This will default to 2 days.
				@inCompareEndDate - Datetime variable to use as the endeding threshold of the scan of records. Used for comparing a snapshot in the past.
				@inOnlyGenerate - bit of 0/1 if 1 is passed then the proc will only output the merge statements and not execute. Will default to 1 and not assume the merge statements should be ran.  

Modified to match on unique keys on tables first otherwise match on the primary key.  
This will work well if the tables we need to match on, other than the primary key as records are being deleted and reloaded in source) 
-- most unique keys are not setup because it requires the partitioned column be included in unique key.

-- Through trail and error, tables have to match on the destination table's clustered index to resolve any duplicate key errors.
-- create the rowid ROW_NUMBER() of the temp table by partitioning on the uk columns if they exist otherwise pk column and order by pk columns.

-- Sample Call:	
EXEC [SelfServe].utility.ProcMergeDatabaseMergeLog
@inSourceLinkedServer = 'ProdOds'
, @inSourceDatabaseName = 'Cake'
, @inTargetDatabaseName = 'Cake'
, @inTableName = 'ping_post'
, @inLookBackFactor=.55
, @inOnlyGenerate = 1
, @inSyncTimeColumnName = 'ModifiedDate'
;

affiliates, export_offers, event_conversion

EXEC [SelfServe].utility.ProcMergeDatabaseInsertOnly
@inSourceLinkedServer = 'ProdOds'
, @inSourceDatabaseName = 'CakePoster'
, @inTargetDatabaseName = 'CakePoster'
--, @inTableName = 'clicks'
, @inOnlyGenerate = 1
;

EXEC [SelfServe].utility.ProcMergeDatabaseBackfillWithUpdates
@inSourceLinkedServer = 'ProdOds'
, @inSourceDatabaseName = 'SC.ESP'
, @inTargetDatabaseName = 'SC.ESP'
--, @inTableName = 'clicks'
, @inSyncColumnName = 'CreatedDate'
, @inOnlyGenerate = 1
;


select * from cakeposter.utility.mergelog with(nolock) order by tablename, createdDate desc



-- processing stats.
select sourceLinkedServer, SourceDatabase, SourceSchema, TargetDatabase, TargetSchema,loadId
--, FORMAT(CreatedDate, 'yyyy-MM-dd HH') as createdHour
, min(createdDate) as startDate, max(createdDate) as endDate
, count(*) as totalTables
, sum(rowsmoved) as totalRowsMoved
, sum(case when rowsMoved is not null then 1 else 0 end) as TablesMovedCount
, sum(case when rowsMoved is null then 1 else 0 end) as TablesErroredCount
, string_agg(case when rowsMoved is null then tableName end, CHAR(10)+',') within group(order by MergeLogId) as FailedTableList
,sum(processSeconds) as processSeconds, ROUND(CAST(sum(processSeconds) as FLOAT)/60,2) as ProcessMinutes
from selfserve.utility.mergelog with(nolock)
group by sourceLinkedServer, SourceDatabase, SourceSchema, TargetDatabase, TargetSchema, loadid--, FORMAT(CreatedDate, 'yyyy-MM-dd HH')
order by  endDate desc, loadid desc

select * 
from selfserve.utility.mergelog 
--where targetDatabase = 'barn-warehouse' and targetSchema='PFT.ClientData' and loadid = 4
where targetDatabase = 'LDP' and targetSchema = 'LDP.Ingest' and tablename = 'IngestQueue' --and generatedTSQL like '%SalesAttempt%'
order by mergelogid desc

-- ================================================================================
*/


CREATE      PROCEDURE [utility].[ProcMergeDatabaseMergeLog]
(@inSourceLinkedServer VARCHAR(100) = NULL , @inSourceDatabaseName VARCHAR(100), @inSourceSchemaName VARCHAR(100)=NULL, @inTargetDatabaseName VARCHAR(100), @inTargetSchemaName VARCHAR(100)=NULL, @inTableName VARCHAR(1000)=NULL,@inIgnoreTableList VARCHAR(1000)=NULL
, @inLookBackFactor DECIMAL(9,2) = 1 
, @inSyncTimeColumnName VARCHAR(100) = 'ModifiedDate'
, @inSyncTimeColumnName2 varchar(100) = NULL
, @inCompareDaysLookBack INT = 2
--, @inCompareDate DATETIME
, @inOnlyGenerate BIT = 1 )
AS
BEGIN
	SET NOCOUNT ON;
	-- short cirtuit the proc so it never runs merge statments dynamically against db.
	SET @inOnlyGenerate=1;
	--for compare table query generation use 
	--IF @inCompareDate IS NULL SET @inCompareDate = DATEADD(HOUR, -1, GETUTCDATE());


	DECLARE @MergeCode NVARCHAR(MAX);
	DECLARE @SqlStmt VARCHAR(MAX);
	DECLARE @curTableName VARCHAR(100);

	DECLARE @varErrorMessages VARCHAR(4000);
	DECLARE @varErrorNumber INT;
	DECLARE @varErrorState INT;
	DECLARE @varErrorSeverity INT;
	DECLARE @varStartTime DATETIME2;
	DECLARE @varEndTime DATETIME2;
	DECLARE @varRowCount INT;
	DECLARE @varLoadId INT;

	--format the in table list to be formatted for dynamic sql.
	IF(LEN(@inIgnoreTableList)>1  AND @inIgnoreTableList LIKE '%,%' ) SET @inIgnoreTableList = REPLACE(REPLACE(RIGHT(LEFT(''''+@inIgnoreTableList, LEN(@inIgnoreTableList)+1)+'''',LEN(@inIgnoreTableList)+2),' ', ''), ',', ''',''') ;
	IF(LEN(@inTableName)>1 AND @inTableName LIKE '%,%' ) SET @inTableName = REPLACE(REPLACE(RIGHT(LEFT(''''+@inTableName, LEN(@inTableName)+1)+'''',LEN(@inTableName)+2),' ', ''), ',', ''',''') ;


	IF OBJECT_ID(N'tempdb..#TempMergeCode') IS NOT NULL  DROP TABLE #TempMergeCode ;
	CREATE TABLE #TempMergeCode (SourceLinkedServer VARCHAR(255) NULL, SourceDatabaseName VARCHAR(255) NOT NULL, SourceSchemaName VARCHAR(255) NOT NULL, TargetDatabaseName VARCHAR(255) NOT NULL, TargetSchemaName VARCHAR(255) NOT NULL, TargetTableName VARCHAR(255) NULL, PKConstraint VARCHAR(255), UKConstraint VARCHAR(255), DestinationHasSyncColumn1 BIT, DestinationHasSyncColumn2 BIT, MergeCode NVARCHAR(MAX) NULL , SCANCOMPARETABLES NVARCHAR(max)  );

	--IF(@inDaysLookBack <=0 ) SET @inDaysLookBack = 1;

	IF @inSourceSchemaName IS NULL  SET @inSourceSchemaName='0';
	IF @inTargetSchemaName IS NULL  SET @inTargetSchemaName='0';


	SET @SqlStmt = 
	CAST('USE ['+REPLACE(REPLACE(@inTargetDatabaseName, ']',''), '[', '')+'] ;'+CHAR(10)
	--correctly pull unique indexs and primary keys together from index tables vs constraint tables (pk/uk constraints are unique indexes)
	+' WITH pk_columns as (  
	SELECT '''+REPLACE(REPLACE(@inTargetDatabaseName, ']',''), '[', '')+''' as CONSTRAINT_CATALOG, s.name AS constraint_schema, i.name AS Constraint_name, s.name AS table_schema, t.[name] as table_Name, col.name AS column_name,ic.index_column_id AS Ordinal_position
	, '''+REPLACE(REPLACE(@inTargetDatabaseName, ']',''), '[', '')+''' as TABLE_CATALOG
	, CASE WHEN i.type_desc=''CLUSTERED'' THEN ''PK'' ELSE ''UK'' END AS constraint_type
	, dense_rank() OVER(PARTITION BY  s.name, t.name ORDER BY i.type_desc ) AS MATCH_CONSTRAINT
	--, i.index_id AS MATCH_CONSTRAINT
	from ['+REPLACE(REPLACE(@inTargetDatabaseName, ']',''), '[', '')+'].sys.objects t  JOIN sys.indexes i ON t.object_id = i.object_id
	JOIN ['+REPLACE(REPLACE(@inTargetDatabaseName, ']',''), '[', '')+'].sys.index_columns ic ON ic.object_id = t.object_id AND ic.index_id = i.index_id
	JOIN ['+REPLACE(REPLACE(@inTargetDatabaseName, ']',''), '[', '')+'].sys.columns col on ic.object_id = col.object_id and ic.column_id = col.column_id
	JOIN ['+REPLACE(REPLACE(@inTargetDatabaseName, ']',''), '[', '')+'].sys.schemas s ON s.schema_id=t.schema_id 
	where i.is_unique = 1
	and t.is_ms_shipped <> 1 '
	+' )   
	, pk_joins as( 
	select  pk.TABLE_CATALOG, pk.TABLE_SCHEMA, pk.table_name
	, MAX(CASE WHEN MATCH_CONSTRAINT=1 THEN pk.CONSTRAINT_NAME END) as PK_CONSTRAINT_NAME
	, MAX(CASE WHEN MATCH_CONSTRAINT=2 THEN pk.CONSTRAINT_NAME END) as UK_CONSTRAINT_NAME
	, string_agg(CASE WHEN MATCH_CONSTRAINT=1 THEN ''a.''+''[''+pk.column_name+'']''+'' = b.''+''[''+pk.column_name+'']'' END, '' AND '') within group(order by pk.ordinal_position asc) as PK_JOIN_CLAUSE  
	, string_agg(CASE WHEN MATCH_CONSTRAINT=2 THEN ''a.''+''[''+pk.column_name+'']''+'' = b.''+''[''+pk.column_name+'']'' END, '' AND '') within group(order by pk.ordinal_position asc) as UK_JOIN_CLAUSE
	, string_agg(case when pk.ORDINAL_POSITION = 1 and MATCH_CONSTRAINT=1 then  ''[''+pk.column_name+'']'' END, '' AND '') within group(order by pk.ordinal_position asc) as FIRST_PK_COLUMN 
	, string_agg(CASE WHEN MATCH_CONSTRAINT=1 THEN''[''+pk.column_name+'']'' END, '', '') within group(order by pk.ordinal_position asc) as PK_COLUMN_LIST
	, string_agg(CASE WHEN MATCH_CONSTRAINT=2 THEN''[''+pk.column_name+'']'' END, '', '') within group(order by pk.ordinal_position asc) as UK_COLUMN_LIST
	from pk_columns pk  
	group by  pk.TABLE_CATALOG, pk.TABLE_SCHEMA, pk.table_name  
	)
	, non_pk_columns as ( 	select tcol.TABLE_CATALOG, tcol.TABLE_SCHEMA, tcol.TABLE_NAME  , scol.table_catalog as sTable_Catalog, scol.TABLE_SCHEMA as sTABLE_SCHEMA
	-- ignore created date columns on update.
	--, string_agg(CASE WHEN tcol.column_name+tcol.DATA_TYPE NOT LIKE ''%CREATE%DATE%''  then cast(''a.''+''[''+tcol.column_name+'']''+'' = b.''+''[''+tcol.column_name+'']'' as nvarchar(max)) END , '' , ''+CHAR(10)) within group(order by tcol.ordinal_position asc) as table_update_clause 
	-- ignore created date columns on update.
	-- createddate needs to be updated.
	, string_agg( cast(''a.''+''[''+tcol.column_name+'']''+'' = b.''+''[''+tcol.column_name+'']'' as nvarchar(max))  , '' , ''+CHAR(10)) within group(order by tcol.ordinal_position asc) as table_update_clause 
	, string_agg(cast(''b.''+tcol.column_name as nvarchar(max)), '', ''+CHAR(10)) within group(order by tcol.ordinal_position asc) as non_pk_select_list
	, string_agg(cast(CASE WHEN tcol.data_type not like ''%TEXT%'' THEN ''a.''+''[''+tcol.column_name+'']''+'' <> b.''+''[''+tcol.column_name+'']'' END  as nvarchar(max)), '' OR '') within group(order by tcol.ordinal_position asc) as table_compare_clause
	from ['+REPLACE(REPLACE(@inTargetDatabaseName, ']',''), '[', '')+'].INFORMATION_SCHEMA.COLUMNS tcol 
	JOIN '+ISNULL('['+REPLACE(REPLACE(@inSourceLinkedServer, ']',''), '[', '')+']','') +'.['+REPLACE(REPLACE(@inSourceDatabaseName, ']',''), '[', '')+'].INFORMATION_SCHEMA.COLUMNS sCol ON tCol.Column_Name=sCol.Column_Name and tCol.Table_name=sCol.Table_Name 
	left outer join pk_columns pk on tcol.TABLE_CATALOG=pk.TABLE_CATALOG and tcol.TABLE_SCHEMA=pk.TABLE_SCHEMA and tcol.TABLE_NAME=pk.table_name and tcol.column_name=pk.column_name 
	where pk.column_name is null 
	AND (tcol.table_schema= '''+REPLACE(REPLACE(ISNULL(@inTargetSchemaName,'0'), ']',''), '[', '')+'''  OR '''+ISNULL(@inTargetSchemaName,'0')+'''= ''0'' )
	and tcol.table_catalog = '''+REPLACE(REPLACE(@inTargetDatabaseName, ']',''), '[', '')+'''  
	AND (sCol.Table_Schema = '''+REPLACE(REPLACE(ISNULL(@inSourceSchemaName,'0'), ']',''), '[', '')+''' OR ('''+ISNULL(@inSourceSchemaName,'0')+'''= ''0'' AND  tcol.TABLE_SCHEMA=scol.TABLE_SCHEMA) )
	AND NOT EXISTS (SELECT is_computed from ['+REPLACE(REPLACE(@inTargetDatabaseName, ']',''), '[', '')+'].sys.computed_columns tcom where tcom.name = tcol.column_name and object_id = OBJECT_ID(''[''+tcol.TABLE_CATALOG+''].[''+tcol.TABLE_SCHEMA+''].[''+tcol.TABLE_NAME+'']'') )
	group by tcol.TABLE_CATALOG, tcol.TABLE_SCHEMA, tcol.TABLE_NAME, scol.table_catalog,scol.TABLE_SCHEMA )  
	'as nvarchar(max));
	SET @SqlStmt = @SqlStmt+CAST(', all_cols_agg as (
		select tCol.TABLE_CATALOG, tCol.TABLE_SCHEMA, tCol.TABLE_NAME   , scol.table_catalog as sTable_Catalog, scol.TABLE_SCHEMA as sTABLE_SCHEMA
		, string_agg(cast(''[''+tCol.column_name+'']'' as nvarchar(max)), '', ''+CHAR(10)) within group(order by tCol.ordinal_position asc) as columns 
		, string_agg(cast(''a.''+''[''+tCol.column_name+'']'' as nvarchar(max)), '', ''+CHAR(10)) within group(order by tCol.ordinal_position asc) as columns_a 
		, string_agg(cast(''b.''+''[''+tCol.column_name+'']'' as nvarchar(max)), '', ''+CHAR(10)) within group(order by tCol.ordinal_position asc) as columns_b 
		--, string_agg(cast(''@in''+tCol.column_name+'' ''+tCol.DATA_TYPE as nvarchar(max) ), '', ''+CHAR(10)) within group(order by tCol.ordinal_position asc) as columns_in_defined 
		--, string_agg(cast(''@in''+tCol.column_name+'' as ''+tCol.COLUMN_NAME as nvarchar(max) ), '', ''+CHAR(10)) within group(order by tCol.ordinal_position asc) as columns_in 
		--, string_agg(cast(''isnull(a.''+tCol.column_name+'', b.''+tCol.COLUMN_NAME+'' as ''+tCol.COLUMN_NAME as nvarchar(max) ), '', ''+CHAR(10)) within group(order by tCol.ordinal_position asc) as columns_in_isnull 
		from ['+REPLACE(REPLACE(@inTargetDatabaseName, ']',''), '[', '')+'].INFORMATION_SCHEMA.COLUMNS tCol 
		JOIN '+ISNULL('['+REPLACE(REPLACE(@inSourceLinkedServer, ']',''), '[', '')+']','') +'.['+REPLACE(REPLACE(@inSourceDatabaseName, ']',''), '[', '')+'].INFORMATION_SCHEMA.COLUMNS sCol ON tCol.Column_Name=sCol.Column_Name and tCol.Table_name=sCol.Table_Name 
		WHERE (tCol.TABLE_SCHEMA = '''+REPLACE(REPLACE(ISNULL(@inTargetSchemaName,'0'), ']',''), '[', '')+''' OR '''+ISNULL(@inTargetSchemaName,'0')+'''= ''0'' )
		and tCol.table_catalog = '''+REPLACE(REPLACE(@inTargetDatabaseName, ']',''), '[', '')+''' 
		AND (sCol.Table_Schema = '''+REPLACE(REPLACE(ISNULL(@inSourceSchemaName,'0'), ']',''), '[', '')+''' OR ('''+ISNULL(@inSourceSchemaName,'0')+'''= ''0'' AND  tCol.TABLE_SCHEMA=sCol.TABLE_SCHEMA ))
		AND NOT EXISTS (SELECT is_computed from ['+REPLACE(REPLACE(@inTargetDatabaseName, ']',''), '[', '')+'].sys.computed_columns tcom where tcom.name = tcol.column_name and object_id = OBJECT_ID(''[''+tcol.TABLE_CATALOG+''].[''+tcol.TABLE_SCHEMA+''].[''+tcol.TABLE_NAME+'']'') )
		group by tCol.TABLE_CATALOG, tCol.TABLE_SCHEMA, tCol.TABLE_NAME, scol.table_catalog,scol.TABLE_SCHEMA
		) 
	, table_fk_clause as (
		SELECT rct.TABLE_CATALOG, rct.TABLE_SCHEMA, rct.TABLE_NAME, rc.CONSTRAINT_NAME
		, pk.TABLE_CATALOG as PK_TABLE_CATALOG, pk.TABLE_SCHEMA as PK_TABLE_SCHEMA, pk.TABLE_NAME as PK_table_name, pk.CONSTRAINT_NAME as PK_CONSTRAINT_NAME
		, '' AND EXISTS ( SELECT ''+STRING_AGG(pkc.COLUMN_NAME, '', '') WITHIN GROUP(ORDER BY pkc.ORDINAL_POSITION) +'' FROM [''+pk.TABLE_CATALOG+''].[''+pk.TABLE_SCHEMA+''].[''+pk.TABLE_NAME+''] z where ''+STRING_AGG(''z.''+pkc.COLUMN_NAME+''=b.''+rcc.COLUMN_NAME, '' AND '') WITHIN GROUP(ORDER BY pkc.ORDINAL_POSITION) +'' ) '' as exists_clause
		FROM ['+REPLACE(REPLACE(@inTargetDatabaseName, ']',''), '[', '')+'].INFORMATION_SCHEMA.REFERENTIAL_CONSTRAINTS rc 
		JOIN ['+REPLACE(REPLACE(@inTargetDatabaseName, ']',''), '[', '')+'].INFORMATION_SCHEMA.TABLE_CONSTRAINTS pk ON rc.UNIQUE_CONSTRAINT_CATALOG=pk.CONSTRAINT_CATALOG AND rc.UNIQUE_CONSTRAINT_SCHEMA=pk.CONSTRAINT_SCHEMA AND rc.UNIQUE_CONSTRAINT_NAME=pk.CONSTRAINT_NAME
		JOIN ['+REPLACE(REPLACE(@inTargetDatabaseName, ']',''), '[', '')+'].INFORMATION_SCHEMA.KEY_COLUMN_USAGE rcc ON rcc.CONSTRAINT_CATALOG=rc.CONSTRAINT_CATALOG AND rcc.CONSTRAINT_SCHEMA=rc.CONSTRAINT_SCHEMA AND rcc.CONSTRAINT_NAME=rc.CONSTRAINT_NAME 
		JOIN ['+REPLACE(REPLACE(@inTargetDatabaseName, ']',''), '[', '')+'].INFORMATION_SCHEMA.TABLE_CONSTRAINTS rct ON rc.CONSTRAINT_CATALOG=rct.CONSTRAINT_CATALOG AND rc.CONSTRAINT_SCHEMA = rct.CONSTRAINT_SCHEMA AND rc.CONSTRAINT_NAME=rct.CONSTRAINT_NAME
		JOIN ['+REPLACE(REPLACE(@inTargetDatabaseName, ']',''), '[', '')+'].INFORMATION_SCHEMA.KEY_COLUMN_USAGE pkc ON pkc.CONSTRAINT_CATALOG=pk.CONSTRAINT_CATALOG AND pkc.CONSTRAINT_SCHEMA=pk.CONSTRAINT_SCHEMA AND pkc.CONSTRAINT_NAME=pk.CONSTRAINT_NAME AND rcc.ORDINAL_POSITION=pkc.ORDINAL_POSITION
		WHERE rct.TABLE_CATALOG = '''+REPLACE(REPLACE(@inTargetDatabaseName, ']',''), '[', '')+''' 
		AND (rct.TABLE_SCHEMA = '''+REPLACE(REPLACE(ISNULL(@inTargetSchemaName,'0'), ']',''), '[', '')+''' OR '''+ISNULL(@inTargetSchemaName,'0')+'''= ''0'' ) 
		GROUP BY rct.TABLE_CATALOG, rct.TABLE_SCHEMA, rct.TABLE_NAME, rc.CONSTRAINT_NAME
		, pk.TABLE_CATALOG, pk.TABLE_SCHEMA, pk.TABLE_NAME, pk.CONSTRAINT_NAME

	) ' as nvarchar(max));

	-- must start another assignment as the string grows larger than 8000 characters with the added code.  
	--Even though it is a varchar(max) variable it can only store up to 8000 characters with a single assignment. More than 8000 characters needs to go into a separate set statement.


	SET @SqlStmt=@SqlStmt
	+'SELECT '''+ISNULL(@inSourceLinkedServer, '')+''' as SourceLinkedServer, '''+@inSourceDatabaseName+''' as SourceDatabaseName, col.stable_schema as SourceSchemaName, '''+@inTargetDatabaseName+''' as TargetDatabaseName, col.table_schema as TargetSchemaName , pk_joins.Table_name
	, pk_joins.PK_CONSTRAINT_NAME as PKConstraint, pk_joins.UK_CONSTRAINT_NAME as UKConstraint
	, (CASE WHEN EXISTS (SELECT COLUMN_NAME FROM ['+REPLACE(REPLACE(@inTargetDatabaseName, ']',''), '[', '')+'].INFORMATION_SCHEMA.COLUMNS sc with(nolock) WHERE sc.Table_Schema = col.TABLE_SCHEMA '
	+' AND sc.table_name = col.table_name and sc.column_name='''+@inSyncTimeColumnName+''' and sc.data_type like ''%dateTime%'' ) THEN 1 ELSE 0 END ) as DestinationHasSyncColumn1
	, (CASE WHEN EXISTS (SELECT COLUMN_NAME FROM ['+REPLACE(REPLACE(@inTargetDatabaseName, ']',''), '[', '')+'].INFORMATION_SCHEMA.COLUMNS sc with(nolock) WHERE sc.Table_Schema = col.TABLE_SCHEMA '
	+' AND sc.table_name = col.table_name and sc.column_name='''+isnull(@inSyncTimeColumnName2, ' ' )+''' and sc.data_type like ''%dateTime%'' ) THEN 1 ELSE 0 END ) as DestinationHasSyncColumn2
	, '' BEGIN ''+CHAR(10)+'' SET NOCOUNT ON;''+CHAR(10) 
	/* +'' use [''+pk_joins.TABLE_CATALOG+'']; ''+CHAR(10) */
	+'' DECLARE @varLoadId BIGINT = 0; ''+CHAR(10)
	+'' --EndTime is 5 minutes in the past of the current time the loader starts. ''+CHAR(10)
	+'' DECLARE @VarStartTime DATETIME2, @VarEndTime DATETIME2 ,@VarStartRunTime DATETIME2 = GETUTCDATE(), @varEndRunTime DATETIME2, @VarSecondLookBack DECIMAL(20,5), @LookBackFactor DECIMAL(20,5) ; ''+CHAR(10)
	+''SET @VarEndTime=GETUTCDATE(); ''+CHAR(10)
	+''SET @LookBackFactor='+CAST(@inLookBackFactor AS VARCHAR(50))+';''+CHAR(10)
	+'' DELETE FROM utility.mergelog WHERE CreatedDate < dateadd(DAY, -15, GETDATE()) and TargetDatabase='''''+@inTargetDatabaseName+''''' and TargetSchema=''''''+col.table_schema+'''''' and TableName =''''''+pk_joins.Table_name+'''''' ;''+CHAR(10)  

	+''--look back from the previous enddate half the total time it took to process. ''+CHAR(10)
	+'' WITH lastLoad_CTE AS ( SELECT m.*, ROW_NUMBER() OVER( PARTITION BY  [SourceLinkedServer], [SourceDatabase], [SourceSchema], [TargetDatabase], [TargetSchema], [TableName] ORDER BY LoadId DESC, StartTime DESC, EndTime DESC) AS rowId  FROM utility.mergelog m WITH(NOLOCK) ) ''+CHAR(10)
	+'' , mergeLogLastLoad_CTE as (SELECT * FROM lastLoad_CTE WHERE rowid=1 )''+CHAR(10)
	+'' SELECT @VarStartTime = dateadd(MINUTE,-(ProcessSeconds/60.0*@LookBackFactor),EndTime) 
		, @VarSecondLookBack=(ProcessSeconds*@LookBackFactor)  
		, @varLoadId = ISNULL(LoadId,0) + 1 
		from  mergeLogLastLoad_CTE 
		where SourceLinkedServer = '''''+ISNULL(@inSourceLinkedServer, '''')+'''''
		and SourceDatabase='''''+@inSourceDatabaseName+''''' and SourceSchema=''''''+col.stable_schema+'''''' 
		and TargetDatabase='''''+@inTargetDatabaseName+''''' and TargetSchema=''''''+col.table_schema+'''''' and TableName =''''''+pk_joins.Table_name+'''''' ;''+CHAR(10)
	+''--Allow a maximum of 12 hour scan back if the table is not in the merge log. ''+CHAR(10)
	+'' IF @VarStartTime is null  SET @VarStartTime=DATEADD(HOUR,-12, GETUTCDATE()); ''+CHAR(10)
	+'' IF @VarSecondLookBack is null SET @VarSecondLookBack=0; ''+CHAR(10)
	+''-- Scan at least 15 minutes of data to merge for potential inflight records during the last run. Load should run at most once an hour. ''+CHAR(10)
	+'' IF DATEDIFF(MINUTE,@VarStartTime, @VarEndTime) < 15   SET @VarStartTime=DATEADD(MINUTE,-15, @VarEndTime); ''+CHAR(10)

	+'' PRINT '''' STARTTIME:''''+CAST(@VarStartTime as VARCHAR(50))+'''' ENDTIME: ''''+CAST(@VarEndTime as VARCHAR(50));''+CHAR(10)  
	+'' DROP TABLE IF EXISTS #Prod''+pk_joins.TABLE_Name+'';''+CHAR(10) 
	+''SELECT ''+col.columns+''''+CHAR(10)
	+''--Row_Number() Logic is used to remove dirty reads from source. First column indexed on the table and matched on rowid=1 for best performance. ''+CHAR(10)
	+'' , ROW_NUMBER() OVER (PARTITION BY ''+isnull(pk_joins.UK_COLUMN_LIST,pk_joins.PK_COLUMN_LIST)+'' ORDER BY ''+pk_joins.PK_COLUMN_LIST+'' ) as RowId ''+CHAR(10)
	+ CASE WHEN  EXISTS (SELECT COLUMN_NAME FROM '+ISNULL('['+REPLACE(REPLACE(@inSourceLinkedServer, ']',''), '[', '')+']', '')+'.['+REPLACE(REPLACE(@inSourceDatabaseName, ']',''), '[', '')+'].INFORMATION_SCHEMA.COLUMNS sc with(nolock) WHERE sc.Table_Schema = col.sTABLE_SCHEMA  AND sc.table_name = col.table_name and sc.column_name='''+@inSyncTimeColumnName+'''  ) 
		AND NOT EXISTS ( select column_name from ['+REPLACE(REPLACE(@inTargetDatabaseName, ']',''), '[', '')+'].INFORMATION_SCHEMA.COLUMNS sc with(nolock) WHERE sc.Table_Schema = col.TABLE_SCHEMA  AND sc.table_name = col.table_name and sc.column_name='''+@inSyncTimeColumnName+'''  )
		THEN  
	'' , b.'+@inSyncTimeColumnName+' '' ELSE '' '' END +CHAR(10)

	+'' INTO #Prod''+pk_joins.TABLE_Name+CHAR(10)+'' FROM '+ISNULL('['+REPLACE(REPLACE(@inSourceLinkedServer, ']',''), '[', '')+'].', '')+'['+REPLACE(REPLACE(@inSourceDatabaseName, ']',''), '[', '')+'].[''+col.sTABLE_SCHEMA+''].[''+pk_joins.TABLE_NAME+''] b WITH(NOLOCK) ''+CHAR(10)+'''
	+''
	-------------------------------------------------------------------------
	---Add in lookup code for single synchronization datetime column. whichever comes first.
	---these are our system sync datetime columns that we have scanned on in the past - ModifiedDate, ProcessAfter, CreatedDate, Created_date.  If the first column in this 
	-------------------------------------------------------------------------
	+ ' WHERE '''
	+CHAR(10)+'+ CASE '
	+'WHEN  EXISTS (SELECT COLUMN_NAME FROM '+ISNULL('['+REPLACE(REPLACE(@inSourceLinkedServer, ']',''), '[', '')+']', '')+'.['+REPLACE(REPLACE(@inSourceDatabaseName, ']',''), '[', '')+'].INFORMATION_SCHEMA.COLUMNS sc with(nolock) WHERE sc.Table_Schema = col.sTABLE_SCHEMA '
	+' AND sc.table_name = col.table_name and sc.column_name='''+@inSyncTimeColumnName+''' and sc.data_type like ''%dateTime%'' ) THEN  '
	+''' ( b.'+@inSyncTimeColumnName+' BETWEEN @VarStartTime AND @VarEndTime  '''+CHAR(10)
	+'WHEN  EXISTS (SELECT COLUMN_NAME FROM '+ISNULL('['+REPLACE(REPLACE(@inSourceLinkedServer, ']',''), '[', '')+']', '')+'.['+REPLACE(REPLACE(@inSourceDatabaseName, ']',''), '[', '')+'].INFORMATION_SCHEMA.COLUMNS sc with(nolock) WHERE sc.Table_Schema = col.sTABLE_SCHEMA '
	+' AND sc.table_name = col.table_name and sc.column_name=''ModifiedDate'' and sc.data_type like ''%dateTime%'' ) THEN  '
	+''' ( b.ModifiedDate BETWEEN @VarStartTime AND @VarEndTime  '''+CHAR(10)
	+'WHEN  EXISTS (SELECT COLUMN_NAME FROM '+ISNULL('['+REPLACE(REPLACE(@inSourceLinkedServer, ']',''), '[', '')+']', '')+'.['+REPLACE(REPLACE(@inSourceDatabaseName, ']',''), '[', '')+'].INFORMATION_SCHEMA.COLUMNS sc with(nolock) WHERE sc.Table_Schema = col.sTABLE_SCHEMA '
	+' AND sc.table_name = col.table_name and sc.column_name=''ProcessAfter'' and sc.data_type like ''%date%'' ) THEN  '
	+''' ( b.ProcessAfter BETWEEN @VarStartTime AND @VarEndTime   '''+CHAR(10)
	+ ' WHEN   EXISTS (SELECT COLUMN_NAME FROM '+ISNULL('['+REPLACE(REPLACE(@inSourceLinkedServer, ']',''), '[', '')+']', '')+'.['+REPLACE(REPLACE(@inSourceDatabaseName, ']',''), '[', '')+'].INFORMATION_SCHEMA.COLUMNS sc with(nolock) WHERE sc.Table_Schema = col.sTABLE_SCHEMA '
	+' AND sc.table_name = col.table_name and sc.column_name=''CreatedDate'' and sc.data_type like ''%date%'' ) THEN '+CHAR(10)
	+''' ( b.CreatedDate  BETWEEN @VarStartTime AND @VarEndTime  '' '
	+ ' WHEN  EXISTS (SELECT COLUMN_NAME FROM '+ISNULL('['+REPLACE(REPLACE(@inSourceLinkedServer, ']',''), '[', '')+']', '')+'.['+REPLACE(REPLACE(@inSourceDatabaseName, ']',''), '[', '')+'].INFORMATION_SCHEMA.COLUMNS sc with(nolock) WHERE sc.Table_Schema = col.sTABLE_SCHEMA '
	+' AND sc.table_name = col.table_name and sc.column_name=''Created_Date'' and sc.data_type like ''%date%'' ) THEN '+CHAR(10)
	+''' ( b.Created_Date BETWEEN @VarStartTime AND @VarEndTime  '' '
	+' ELSE ''( 1=1'' END '+CHAR(10)

	--------------------------------------------------------------------------
	-- Logic for Or second sync column name. 
	--------------------------------------------------------------------------
		+CHAR(10)+'+ CASE '
	+'WHEN  EXISTS (SELECT COLUMN_NAME FROM '+ISNULL('['+REPLACE(REPLACE(@inSourceLinkedServer, ']',''), '[', '')+']', '')+'.['+REPLACE(REPLACE(@inSourceDatabaseName, ']',''), '[', '')+'].INFORMATION_SCHEMA.COLUMNS sc with(nolock) WHERE sc.Table_Schema = col.sTABLE_SCHEMA '
	+' AND sc.table_name = col.table_name and sc.column_name='''+isnull(@inSyncTimeColumnName2, ' ')+''' and sc.data_type like ''%dateTime%'' ) THEN  '
	+''' OR b.'+isnull(@inSyncTimeColumnName2, ' ')+' BETWEEN @VarStartTime AND @VarEndTime  ) '''+CHAR(10)
	+' ELSE ''  )'' END '+CHAR(10)

	-------------------------------------------------------------------------
	-------------------------------------------------------------------------
	----add in logic for completed records. Look for a bit/int column named completed or iscompleted exactly.
	+CHAR(10)+'+ CASE WHEN EXISTS (SELECT COLUMN_NAME FROM '+ISNULL('['+REPLACE(REPLACE(@inSourceLinkedServer, ']',''), '[', '')+']', '')+'.['+REPLACE(REPLACE(@inSourceDatabaseName, ']',''), '[', '')+'].INFORMATION_SCHEMA.COLUMNS sc WHERE sc.Table_Schema = col.sTABLE_SCHEMA '
	+' AND sc.table_name = col.table_name and sc.column_name=''Completed'' and sc.data_type in(''BIT'',''INT'') ) THEN  '' AND Completed=1 '' '
	+' WHEN EXISTS (SELECT COLUMN_NAME FROM '+ISNULL('['+REPLACE(REPLACE(@inSourceLinkedServer, ']',''), '[', '')+']', '')+'.['+REPLACE(REPLACE(@inSourceDatabaseName, ']',''), '[', '')+'].INFORMATION_SCHEMA.COLUMNS sc WHERE sc.Table_Schema = col.sTABLE_SCHEMA '
	+' AND sc.table_name = col.table_name and sc.column_name=''isComplete'' and sc.data_type in(''BIT'',''INT'') ) THEN  '' AND isComplete=1 '' '
	+' ELSE '' '' END'+CHAR(10)
	-------------------------------------------------------------------------
	-------------------------------------------------------------------------
	+'+ CASE WHEN table_fk_clause.exists_clause is not null THEN  '
	+' table_fk_clause.exists_clause ELSE '' '' END'+CHAR(10)
	-------------------------------------------------------------------------
	--line terminator for the select into temp table clause.
	+'+'' ;'' +CHAR(10)  '

	--turn identity_insert on.  This could be dangerous depending on how the ids are generated.  
	--Ideally the ID columns should match 1:1 from the source, but if its setup in barn then the original merge proc probably is not matching on it and letting new ids be generated in the destination.
	+' +case when OBJECTPROPERTY(OBJECT_ID(col.table_name), ''TableHasIdentity'')  =1 THEN '' SET IDENTITY_INSERT  [''+pk_joins.TABLE_CATALOG+''].[''+pk_joins.TABLE_SCHEMA+''].[''+pk_joins.TABLE_NAME+''] ON ; '' ELSE '' '' END +CHAR(10) '
    -------------------------------------------------------------------------
	
	--+'+CASE WHEN pk_joins.UK_CONSTRAINT_NAME is not null then ''CREATE INDEX #UKX_''+pk_joins.TABLE_Name+''Loader ON #Prod''+pk_joins.TABLE_Name+'' (rowid, ''+pk_joins.UK_COLUMN_LIST+'') ; '' ELSE '' '' END+CHAR(10) '

	+'+CASE '
	-- include inSyncTimeColumnName in include clause of index.
	/*
	+' WHEN pk_joins.PK_CONSTRAINT_NAME is not null AND EXISTS (SELECT COLUMN_NAME FROM '+ISNULL('['+REPLACE(REPLACE(@inSourceLinkedServer, ']',''), '[', '')+']', '')+'.['+REPLACE(REPLACE(@inSourceDatabaseName, ']',''), '[', '')+'].INFORMATION_SCHEMA.COLUMNS sc with(nolock) WHERE sc.Table_Schema = col.sTABLE_SCHEMA '
	+' AND sc.table_name = col.table_name and sc.column_name='''+@inSyncTimeColumnName+''' and sc.data_type like ''%dateTime%'' )  THEN 
	''CREATE INDEX #PKX_''+pk_joins.TABLE_Name+''Loader ON #Prod''+pk_joins.TABLE_Name+'' (rowid, ''+pk_joins.PK_COLUMN_LIST+'') INCLUDE('+@inSyncTimeColumnName+'); '' '
	*/
	+' WHEN pk_joins.UK_CONSTRAINT_NAME is not null THEN 
	''CREATE INDEX #UKX_''+pk_joins.TABLE_Name+''Loader ON #Prod''+pk_joins.TABLE_Name+'' (rowid, ''+pk_joins.UK_COLUMN_LIST+'') ; '' 
	 WHEN pk_joins.PK_CONSTRAINT_NAME is not null THEN 
	''CREATE INDEX #PKX_''+pk_joins.TABLE_Name+''Loader ON #Prod''+pk_joins.TABLE_Name+'' (rowid, ''+pk_joins.PK_COLUMN_LIST+'') ; '' 
	ELSE '' '' END+CHAR(10) '

	--begin a transaction and commit it.
	+'+CHAR(10)+''BEGIN TRANSACTION; ''+CHAR(10) '

	+'+CAST (''MERGE INTO [''+pk_joins.TABLE_CATALOG+''].[''+pk_joins.TABLE_SCHEMA+''].[''+pk_joins.TABLE_NAME+''] A USING ''
	 +''( SELECT *  FROM  #Prod''+pk_joins.TABLE_Name+''  ) '' 
	+'' b ''+CHAR(10)
	+'' ON b.rowid=1 AND ''+ isnull(pk_joins.UK_JOIN_CLAUSE, pk_joins.PK_JOIN_CLAUSE) +CHAR(10) '
	
	
	--Add in update clause logic to not update rows that have not changed sync by modifiedDate
	+'+ CASE WHEN NOT EXISTS (SELECT COLUMN_NAME FROM '+ISNULL('['+REPLACE(REPLACE(@inSourceLinkedServer, ']',''), '[', '')+']', '')+'.['+REPLACE(REPLACE(@inSourceDatabaseName, ']',''), '[', '')+'].INFORMATION_SCHEMA.COLUMNS sc WHERE sc.Table_Schema = col.sTABLE_SCHEMA '
	+' AND sc.table_name = col.table_name and sc.column_name in (''Completed'', ''isComplete'') and sc.data_type in(''BIT'',''INT'') ) THEN   '
	--------------update statement of merge. only update if completed/iscomplete does not exist in the table.
	+' '' WHEN MATCHED '' '

	/* -- update only where modifieddate is greater in source than destination.
	+'+ CASE WHEN EXISTS (SELECT COLUMN_NAME FROM '+ISNULL('['+REPLACE(REPLACE(@inSourceLinkedServer, ']',''), '[', '')+']', '')+'.['+REPLACE(REPLACE(@inSourceDatabaseName, ']',''), '[', '')+'].INFORMATION_SCHEMA.COLUMNS sc '
	+' WHERE sc.Table_Schema = col.stable_schema AND sc.table_name = col.table_name and sc.column_name='''+@inSyncTimeColumnName+''' and sc.data_type like ''%date%'' ) '
	+' THEN '+CHAR(10)
	--+' '' AND (a.['+@inSyncTimeColumnName+'] < b.['+@inSyncTimeColumnName+'] OR (a.'+@inSyncTimeColumnName+' IS NULL AND b.'+@inSyncTimeColumnName+' IS NOT NULL))  '' ELSE '''' END +'' '+CHAR(10)
	+' '' AND (a.['+@inSyncTimeColumnName+'] < b.['+@inSyncTimeColumnName+'] )  '' ELSE '''' END  '+CHAR(10)
	*/

	+'+'' THEN UPDATE SET ''+non_pk_columns.table_update_clause '
	+' ELSE CHAR(10)+''---- Do not update tables where isComplete is filtered. ''+CHAR(10)+'' /* WHEN MATCHED THEN UPDATE SET ''+non_pk_columns.table_update_clause +'' */ '' '
	+' END as nvarchar(max)) '

	+' +CAST('' WHEN NOT MATCHED  THEN INSERT (''+col.columns+'') VALUES (''+col.columns_b+'') ''  
	+'';''+CHAR(10) 
	+'' DECLARE @MergedRowCount INT = @@ROWCOUNT; ''+CHAR(10)
	+'' PRINT ''''''+pk_joins.TABLE_Name+'' ROWS MERGED ''''+CAST(@MergedRowCount as varchar(50));''+CHAR(10)  

	+''IF (@MergedRowCount > 0 )  ''+CHAR(10)+''BEGIN''+CHAR(10)'
	-------------------------------------------------------------------------
	--Manual look up of the max date loaded into the temp table for accurate end time scan.
	--with if statement to not insert into merge log if 0 rows are moved then this isnt needed.
	-------------------------------------------------------------------------
	+' +''DECLARE @varEndTime1 DATETIME2, @VarEndTime2 DATETIME2; ''+CHAR(10) '
	+CHAR(10)+'+ CASE '
	+'WHEN  EXISTS (SELECT COLUMN_NAME FROM '+ISNULL('['+REPLACE(REPLACE(@inSourceLinkedServer, ']',''), '[', '')+']', '')+'.['+REPLACE(REPLACE(@inSourceDatabaseName, ']',''), '[', '')+'].INFORMATION_SCHEMA.COLUMNS sc WHERE sc.Table_Schema = col.sTABLE_SCHEMA '
	+' AND sc.table_name = col.table_name and sc.column_name='''+@inSyncTimeColumnName+''' and sc.data_type like ''%dateTime%'' ) THEN  '
	+''' SELECT  @varEndTime1 = MAX('+@inSyncTimeColumnName+')  FROM #Prod''+pk_joins.TABLE_Name+''; ''+CHAR(10)'+CHAR(10)
	+'WHEN  EXISTS (SELECT COLUMN_NAME FROM '+ISNULL('['+REPLACE(REPLACE(@inSourceLinkedServer, ']',''), '[', '')+']', '')+'.['+REPLACE(REPLACE(@inSourceDatabaseName, ']',''), '[', '')+'].INFORMATION_SCHEMA.COLUMNS sc WHERE sc.Table_Schema = col.sTABLE_SCHEMA '
	+' AND sc.table_name = col.table_name and sc.column_name=''ModifiedDate'' and sc.data_type like ''%dateTime%'' ) THEN  '
	+''' SELECT  @varEndTime1 = MAX(ModifiedDate)  FROM #Prod''+pk_joins.TABLE_Name+''; ''+CHAR(10)'+CHAR(10)
	+'WHEN  EXISTS (SELECT COLUMN_NAME FROM '+ISNULL('['+REPLACE(REPLACE(@inSourceLinkedServer, ']',''), '[', '')+']', '')+'.['+REPLACE(REPLACE(@inSourceDatabaseName, ']',''), '[', '')+'].INFORMATION_SCHEMA.COLUMNS sc WHERE sc.Table_Schema = col.sTABLE_SCHEMA '
	+' AND sc.table_name = col.table_name and sc.column_name=''ProcessAfter'' and sc.data_type like ''%date%'' ) THEN  '
	+''' SELECT  @varEndTime1 = MAX(ProcessAfter)  FROM #Prod''+pk_joins.TABLE_Name+''; ''+CHAR(10)'+CHAR(10)
	+ ' WHEN   EXISTS (SELECT COLUMN_NAME FROM '+ISNULL('['+REPLACE(REPLACE(@inSourceLinkedServer, ']',''), '[', '')+']', '')+'.['+REPLACE(REPLACE(@inSourceDatabaseName, ']',''), '[', '')+'].INFORMATION_SCHEMA.COLUMNS sc WHERE sc.Table_Schema = col.sTABLE_SCHEMA '
	+' AND sc.table_name = col.table_name and sc.column_name=''CreatedDate'' and sc.data_type like ''%date%'' ) THEN '+CHAR(10)
	+''' SELECT  @varEndTime1 = MAX(CreatedDate)  FROM #Prod''+pk_joins.TABLE_Name+''; ''+CHAR(10)'+CHAR(10)
	+ ' WHEN  EXISTS (SELECT COLUMN_NAME FROM '+ISNULL('['+REPLACE(REPLACE(@inSourceLinkedServer, ']',''), '[', '')+']', '')+'.['+REPLACE(REPLACE(@inSourceDatabaseName, ']',''), '[', '')+'].INFORMATION_SCHEMA.COLUMNS sc WHERE sc.Table_Schema = col.sTABLE_SCHEMA '
	+' AND sc.table_name = col.table_name and sc.column_name=''Created_Date'' and sc.data_type like ''%date%'' ) THEN '+CHAR(10)
	+''' SELECT  @varEndTime1 = MAX(Created_Date)  FROM #Prod''+pk_joins.TABLE_Name+''; ''+CHAR(10) '+CHAR(10)
	+' END '+CHAR(10)
	
		+CHAR(10)+'+ CASE '
	+'WHEN  EXISTS (SELECT COLUMN_NAME FROM '+ISNULL('['+REPLACE(REPLACE(@inSourceLinkedServer, ']',''), '[', '')+']', '')+'.['+REPLACE(REPLACE(@inSourceDatabaseName, ']',''), '[', '')+'].INFORMATION_SCHEMA.COLUMNS sc WHERE sc.Table_Schema = col.sTABLE_SCHEMA '
	+' AND sc.table_name = col.table_name and sc.column_name='''+isnull(@inSyncTimeColumnName2, '#')+''' and sc.data_type like ''%dateTime%'' ) THEN  '
	+''' SELECT  @varEndTime2 = MAX('+isnull(@inSyncTimeColumnName2, '1')+')  FROM #Prod''+pk_joins.TABLE_Name+''; ''+CHAR(10)'+CHAR(10)
	+ ' ELSE '' '' '+CHAR(10)
	+' END '+CHAR(10)
	+' +'' SELECT @varEndTime = MAX(ISNULL(q.EndTime, DATEADD(MINUTE, -15, @varStartRunTime))) FROM (select @varEndTime1 as EndTime union all select @varEndTime2 as EndTime) as q ; '' '

	---INSERT INTO MergeLog to track.
	+'+CHAR(10)+'' INSERT INTO [utility].[MergeLog]([LoadId],[SourceLinkedServer],[SourceDatabase],[SourceSchema],[TargetDatabase],[TargetSchema],[TableName],[StartRunTime], [EndRunTime],[StartTime], [EndTime],[dayScan],[RowsMoved],[generatedTSQL])''+CHAR(10)
	+'' VALUES (@varLoadId,'''''+ISNULL(@inSourceLinkedServer, '''')+''''', '''''+@inSourceDatabaseName+''''', ''''''+col.stable_schema+'''''', '''''+@inTargetDatabaseName+''''', ''''''+col.table_schema+'''''', ''''''+pk_joins.Table_name+'''''',@varStartRunTime, GETUTCDATE(), @varStartTime , @varEndTime , (cast(DATEDIFF(MINUTE, @varStartTime,@varEndTime) as decimal(20,5))/60.0/24.0),CAST(@MergedRowCount as varchar(50)) , ''''Execute ['+@inTargetDatabaseName+'].''''+OBJECT_SCHEMA_NAME(@@PROCID) +''''.''''+OBJECT_NAME(@@PROCID)''+'');''+CHAR(10)
	+''END; ''+CHAR(10) '
	
	--commit transaction from begin transaction
	+'+''COMMIT;''+CHAR(10) '
	
	+'+'' DROP TABLE IF EXISTS #Prod''+pk_joins.TABLE_Name+'';''+CHAR(10)  '
	 --set identity insert off if exsits on destination table.
	 +'+ case when OBJECTPROPERTY(OBJECT_ID(col.table_name), ''TableHasIdentity'')  =1 THEN '' SET IDENTITY_INSERT  [''+pk_joins.TABLE_CATALOG+''].[''+pk_joins.TABLE_SCHEMA+''].[''+pk_joins.TABLE_NAME+''] OFF ; '' ELSE '' '' END +CHAR(10) '

	+'+''END; ''+CHAR(10) '+CHAR(10)
	+' as nvarchar(max)) as MergeCode '
	-- Generate Compare Query
	+', ''DECLARE @StartInterval datetime = DATEADD(DAY, - '+CAST(@inCompareDaysLookBack AS VARCHAR(10))+', GETUTCDATE()), @EndInterval datetime = CAST(GETUTCDATE() as DATE) ; '

	/*
		+'''+CHAR(10)+''SELECT ''''''+pk_joins.Table_name+'''''' as TABLE_NAME 
		, sum(case when a.''+FIRST_PK_COLUMN+'' is not null and b.''+FIRST_PK_COLUMN+'' is not null  then 1 else 0 end) as matchingCNT
		, sum(case when a.''+FIRST_PK_COLUMN+'' is not null and b.''+FIRST_PK_COLUMN+'' is  null  then 1 else 0 end) as SourceOnlyCnt
		, sum(case when a.''+FIRST_PK_COLUMN+'' is  null and b.''+FIRST_PK_COLUMN+'' is NOT null  then 1 else 0 end) as DestinationOnlyCnt
		---- , sum(case when a.''+FIRST_PK_COLUMN+'' is not null and b.''+FIRST_PK_COLUMN+'' is not null and (''+non_pk_columns.table_compare_clause+'') THEN 1 else 0 end) as NonPksDontMatchCNT 
		FROM ( SELECT ''+pk_joins.PK_COLUMN_LIST+'' FROM '+ISNULL('['+REPLACE(REPLACE(@inSourceLinkedServer, ']',''), '[', '')+']', '')+'.['+REPLACE(REPLACE(@inSourceDatabaseName, ']',''), '[', '')+'].[''+col.sTABLE_SCHEMA+''].[''+pk_joins.TABLE_NAME+''] a WITH(NOLOCK) '
		+''''
     */
	 	+'''+CHAR(10)+''SELECT ''''''+pk_joins.Table_name+'''''' as TABLE_NAME 
		, sum(case when  b.''+FIRST_PK_COLUMN+'' is not null  then 1 else 0 end) as matchingCNT
		, sum(case when  b.''+FIRST_PK_COLUMN+'' is  null  then 1 else 0 end) as SourceOnlyCnt
		FROM ( SELECT ''+pk_joins.PK_COLUMN_LIST+'' FROM '+ISNULL('['+REPLACE(REPLACE(@inSourceLinkedServer, ']',''), '[', '')+']', '')+'.['+REPLACE(REPLACE(@inSourceDatabaseName, ']',''), '[', '')+'].[''+col.sTABLE_SCHEMA+''].[''+pk_joins.TABLE_NAME+''] a WITH(NOLOCK) '
		+''''
		-------------------------------------------------------------------------
		---Add in lookup code for single synchronization datetime column. whichever comes first.
		---these are our system sync datetime columns that we have scanned on in the past - ModifiedDate, ProcessAfter, CreatedDate, Created_date.  If the first column in this 
		-------------------------------------------------------------------------
		+CHAR(10)+'+ CASE '
		+'WHEN  EXISTS (SELECT COLUMN_NAME FROM '+ISNULL('['+REPLACE(REPLACE(@inSourceLinkedServer, ']',''), '[', '')+']', '')+'.['+REPLACE(REPLACE(@inSourceDatabaseName, ']',''), '[', '')+'].INFORMATION_SCHEMA.COLUMNS sc WHERE sc.Table_Schema = col.sTABLE_SCHEMA '
		+' AND sc.table_name = col.table_name and sc.column_name='''+@inSyncTimeColumnName+''' and sc.data_type like ''%dateTime%'' ) THEN  '
		+''' WHERE '+@inSyncTimeColumnName+' BETWEEN @VarStartTime AND @VarEndTime  '''+CHAR(10)
		+'WHEN  EXISTS (SELECT COLUMN_NAME FROM '+ISNULL('['+REPLACE(REPLACE(@inSourceLinkedServer, ']',''), '[', '')+']', '')+'.['+REPLACE(REPLACE(@inSourceDatabaseName, ']',''), '[', '')+'].INFORMATION_SCHEMA.COLUMNS sc WHERE sc.Table_Schema = col.sTABLE_SCHEMA '
		+' AND sc.table_name = col.table_name and sc.column_name=''ModifiedDate'' and sc.data_type like ''%dateTime%'' ) THEN  '
		+''' WHERE ModifiedDate BETWEEN @VarStartTime AND @VarEndTime  '''+CHAR(10)
		+'WHEN  EXISTS (SELECT COLUMN_NAME FROM '+ISNULL('['+REPLACE(REPLACE(@inSourceLinkedServer, ']',''), '[', '')+']', '')+'.['+REPLACE(REPLACE(@inSourceDatabaseName, ']',''), '[', '')+'].INFORMATION_SCHEMA.COLUMNS sc WHERE sc.Table_Schema = col.sTABLE_SCHEMA '
		+' AND sc.table_name = col.table_name and sc.column_name=''ProcessAfter'' and sc.data_type like ''%date%'' ) THEN  '
		+''' WHERE ProcessAfter BETWEEN @VarStartTime AND @VarEndTime   '''+CHAR(10)
		+ ' WHEN   EXISTS (SELECT COLUMN_NAME FROM '+ISNULL('['+REPLACE(REPLACE(@inSourceLinkedServer, ']',''), '[', '')+']', '')+'.['+REPLACE(REPLACE(@inSourceDatabaseName, ']',''), '[', '')+'].INFORMATION_SCHEMA.COLUMNS sc WHERE sc.Table_Schema = col.sTABLE_SCHEMA '
		+' AND sc.table_name = col.table_name and sc.column_name=''CreatedDate'' and sc.data_type like ''%date%'' ) THEN '+CHAR(10)
		+''' WHERE CreatedDate  BETWEEN @VarStartTime AND @VarEndTime  '' '
		+ ' WHEN  EXISTS (SELECT COLUMN_NAME FROM '+ISNULL('['+REPLACE(REPLACE(@inSourceLinkedServer, ']',''), '[', '')+']', '')+'.['+REPLACE(REPLACE(@inSourceDatabaseName, ']',''), '[', '')+'].INFORMATION_SCHEMA.COLUMNS sc WHERE sc.Table_Schema = col.sTABLE_SCHEMA '
		+' AND sc.table_name = col.table_name and sc.column_name=''Created_Date'' and sc.data_type like ''%date%'' ) THEN '+CHAR(10)
		+''' WHERE Created_Date BETWEEN @VarStartTime AND @VarEndTime  '' '
		+' ELSE ''WHERE 1=1'' END '+CHAR(10)
		-------------------------------------------------------------------------
		-------------------------------------------------------------------------
		----add in logic for completed records. Look for a bit/int column named completed or iscompleted exactly.
		+CHAR(10)+'+ CASE WHEN EXISTS (SELECT COLUMN_NAME FROM '+ISNULL('['+REPLACE(REPLACE(@inSourceLinkedServer, ']',''), '[', '')+']', '')+'.['+REPLACE(REPLACE(@inSourceDatabaseName, ']',''), '[', '')+'].INFORMATION_SCHEMA.COLUMNS sc WHERE sc.Table_Schema = col.sTABLE_SCHEMA '
		+' AND sc.table_name = col.table_name and sc.column_name=''Completed'' and sc.data_type in(''BIT'',''INT'') ) THEN  '' AND Completed=1 '' '
		+' WHEN EXISTS (SELECT COLUMN_NAME FROM '+ISNULL('['+REPLACE(REPLACE(@inSourceLinkedServer, ']',''), '[', '')+']', '')+'.['+REPLACE(REPLACE(@inSourceDatabaseName, ']',''), '[', '')+'].INFORMATION_SCHEMA.COLUMNS sc WHERE sc.Table_Schema = col.sTABLE_SCHEMA '
		+' AND sc.table_name = col.table_name and sc.column_name=''isComplete'' and sc.data_type in(''BIT'',''INT'') ) THEN  '' AND isComplete=1 '' '
		+' ELSE '' '' END'+CHAR(10)
		-------------------------------------------------------------------------
		-------------------------------------------------------------------------
	+'+'')  a  LEFT OUTER JOIN  ( SELECT ''+pk_joins.PK_COLUMN_LIST+'' '
		+' FROM [''+pk_joins.TABLE_CATALOG+''].[''+pk_joins.TABLE_SCHEMA+''].[''+pk_joins.TABLE_NAME+'']  b WITH(NOLOCK) '
				+''''
		+CHAR(10)+'+ CASE '
		+'WHEN  EXISTS (SELECT COLUMN_NAME FROM '+ISNULL('['+REPLACE(REPLACE(@inSourceLinkedServer, ']',''), '[', '')+']', '')+'.['+REPLACE(REPLACE(@inSourceDatabaseName, ']',''), '[', '')+'].INFORMATION_SCHEMA.COLUMNS sc WHERE sc.Table_Schema = col.sTABLE_SCHEMA '
		+' AND sc.table_name = col.table_name and sc.column_name='''+@inSyncTimeColumnName+''' and sc.data_type like ''%dateTime%'' ) THEN  '
		+''' WHERE '+@inSyncTimeColumnName+' BETWEEN @VarStartTime AND @VarEndTime  '''+CHAR(10)
		+'WHEN  EXISTS (SELECT COLUMN_NAME FROM '+ISNULL('['+REPLACE(REPLACE(@inSourceLinkedServer, ']',''), '[', '')+']', '')+'.['+REPLACE(REPLACE(@inSourceDatabaseName, ']',''), '[', '')+'].INFORMATION_SCHEMA.COLUMNS sc WHERE sc.Table_Schema = col.sTABLE_SCHEMA '
		+' AND sc.table_name = col.table_name and sc.column_name=''ModifiedDate'' and sc.data_type like ''%dateTime%'' ) THEN  '
		+''' WHERE ModifiedDate BETWEEN @VarStartTime AND @VarEndTime  '''+CHAR(10)
		+'WHEN  EXISTS (SELECT COLUMN_NAME FROM '+ISNULL('['+REPLACE(REPLACE(@inSourceLinkedServer, ']',''), '[', '')+']', '')+'.['+REPLACE(REPLACE(@inSourceDatabaseName, ']',''), '[', '')+'].INFORMATION_SCHEMA.COLUMNS sc WHERE sc.Table_Schema = col.sTABLE_SCHEMA '
		+' AND sc.table_name = col.table_name and sc.column_name=''ProcessAfter'' and sc.data_type like ''%date%'' ) THEN  '
		+''' WHERE ProcessAfter BETWEEN @VarStartTime AND @VarEndTime   '''+CHAR(10)
		+ ' WHEN   EXISTS (SELECT COLUMN_NAME FROM '+ISNULL('['+REPLACE(REPLACE(@inSourceLinkedServer, ']',''), '[', '')+']', '')+'.['+REPLACE(REPLACE(@inSourceDatabaseName, ']',''), '[', '')+'].INFORMATION_SCHEMA.COLUMNS sc WHERE sc.Table_Schema = col.sTABLE_SCHEMA '
		+' AND sc.table_name = col.table_name and sc.column_name=''CreatedDate'' and sc.data_type like ''%date%'' ) THEN '+CHAR(10)
		+''' WHERE CreatedDate  BETWEEN @VarStartTime AND @VarEndTime  '' '
		+ ' WHEN  EXISTS (SELECT COLUMN_NAME FROM '+ISNULL('['+REPLACE(REPLACE(@inSourceLinkedServer, ']',''), '[', '')+']', '')+'.['+REPLACE(REPLACE(@inSourceDatabaseName, ']',''), '[', '')+'].INFORMATION_SCHEMA.COLUMNS sc WHERE sc.Table_Schema = col.sTABLE_SCHEMA '
		+' AND sc.table_name = col.table_name and sc.column_name=''Created_Date'' and sc.data_type like ''%date%'' ) THEN '+CHAR(10)
		+''' WHERE Created_Date BETWEEN @VarStartTime AND @VarEndTime  '' '
		+' ELSE ''WHERE 1=1'' END '+CHAR(10)
		-------------------------------------------------------------------------
		-------------------------------------------------------------------------
		----add in logic for completed records. Look for a bit/int column named completed or iscompleted exactly.
		+CHAR(10)+'+ CASE WHEN EXISTS (SELECT COLUMN_NAME FROM '+ISNULL('['+REPLACE(REPLACE(@inSourceLinkedServer, ']',''), '[', '')+']', '')+'.['+REPLACE(REPLACE(@inSourceDatabaseName, ']',''), '[', '')+'].INFORMATION_SCHEMA.COLUMNS sc WHERE sc.Table_Schema = col.sTABLE_SCHEMA '
		+' AND sc.table_name = col.table_name and sc.column_name=''Completed'' and sc.data_type in(''BIT'',''INT'') ) THEN  '' AND Completed=1 '' '
		+' WHEN EXISTS (SELECT COLUMN_NAME FROM '+ISNULL('['+REPLACE(REPLACE(@inSourceLinkedServer, ']',''), '[', '')+']', '')+'.['+REPLACE(REPLACE(@inSourceDatabaseName, ']',''), '[', '')+'].INFORMATION_SCHEMA.COLUMNS sc WHERE sc.Table_Schema = col.sTABLE_SCHEMA '
		+' AND sc.table_name = col.table_name and sc.column_name=''isComplete'' and sc.data_type in(''BIT'',''INT'') ) THEN  '' AND isComplete=1 '' '
		+' ELSE '' '' END'+CHAR(10)
		-------------------------------------------------------------------------
		-------------------------------------------------------------------------
		
		+'+'')  b  ON ''+pk_joins.PK_JOIN_CLAUSE+'' UNION ALL  '' AS SCANCOMPARETABLES
	from all_cols_agg col
	join pk_joins  on pk_joins.TABLE_CATALOG=col.TABLE_CATALOG and pk_joins.TABLE_SCHEMA=col.TABLE_SCHEMA and pk_joins.TABLE_Name=col.TABLE_NAME 
	join non_pk_columns on pk_joins.TABLE_CATALOG=non_pk_columns.TABLE_CATALOG and pk_joins.TABLE_SCHEMA=non_pk_columns.TABLE_SCHEMA and pk_joins.TABLE_Name=non_pk_columns.TABLE_NAME and non_pk_columns.sTABLE_CATALOG=col.sTABLE_CATALOG and non_pk_columns.sTable_schema=col.sTable_schema  ';



	SET @SqlStmt=@SqlStmt+' LEFT OUTER JOIN table_fk_clause on table_fk_clause.TABLE_CATALOG=col.TABLE_CATALOG and table_fk_clause.TABLE_SCHEMA=col.TABLE_SCHEMA and table_fk_clause.TABLE_Name=col.TABLE_NAME ';

	SET @SqlStmt=@SqlStmt+ ' WHERE 1=1 ';
	IF LEN(@inTableName) >1 AND @inTableName LIKE '%[%]%' AND @inTableName is not null SET @SqlStmt=@SqlStmt+' AND col.table_name like '''+@inTableName+''' ';
	ELSE IF LEN(@inTableName) >1 AND @inTableName NOT LIKE '%[%]%' AND @inTableName is not null  SET @SqlStmt=@SqlStmt+' AND col.table_name = '''+REPLACE(REPLACE(@inTableName, ']',''), '[','')+''' ';
	ELSE IF LEN(@inTableName) >1 AND @inTableName NOT LIKE '%[%]%' and @inTableName like '%,%' AND @inTableName is not null  SET @SqlStmt=@SqlStmt+' AND col.table_name in ('+REPLACE(REPLACE(@inTableName, ']',''), '[','')+') ';

	
	
	IF LEN(@inIgnoreTableList)>1 and (LEN(@inTableName) <= 1 or @inTableName is null) SET  @SqlStmt=@SqlStmt+' AND col.table_name NOT in ('+REPLACE(REPLACE(@inIgnoreTableList, ']',''), '[','')+') ';
	ELSE IF LEN(@inIgnoreTableList)>1 and LEN(@inTableName) > 1 SET  @SqlStmt=@SqlStmt+' AND col.table_name NOT in ('+REPLACE(REPLACE(@inIgnoreTableList, ']',''), '[','')+') ';

	---TODO:::Also try to order the tables in foreign key referencing order. This will be non foreign key tables first.
	SET @SqlStmt=@SqlStmt+' ORDER BY case when table_fk_clause.table_name is null then 1 else 2 end, col.table_name '
	;


	IF(@inOnlyGenerate = 1 ) 
	BEGIN
		PRINT '--GENERATE MERGE STATEMENTS QUERY::: '+CHAR(10)+@SqlStmt+CHAR(10);
		PRINT 'IGNORED TABLE LIST : '+@inIgnoreTableList+CHAR(10);
		--SELECT @SqlStmt AS generateMergeSQL;
	END;

	INSERT INTO #TempMergeCode EXEC( @SqlStmt);

	--DECLARE CursorDynamicMerge CURSOR LOCAL FAST_FORWARD FOR  SELECT MergeCode, '['+REPLACE(REPLACE(TargetDatabaseName, ']',''), '[','')+'].['+REPLACE(REPLACE(TargetSchemaName, ']',''), '[','')+'].['+TargetTableName+']' AS FullTableName FROM #TempMergeCode;
	DECLARE CursorDynamicMerge CURSOR LOCAL FAST_FORWARD FOR  SELECT MergeCode, SourceSchemaName, TargetSchemaName, TargetTableName FROM #TempMergeCode;


	IF(@inOnlyGenerate = 1 ) 
	BEGIN
		DECLARE @varProcPostFix VARCHAR(100) = '';--'_INCREMENTAL';
		IF  (SELECT COUNT(*) FROM #TempMergeCode) > 0   
		BEGIN
			SELECT @SqlStmt AS GenerateMergeQuery, LEN(@SqlStmt) AS length_GenerateMergeQuery, mc.*, LEN(mc.MergeCode) AS Length_MergeCode 
			, 'USE ['+mc.TargetDatabaseName+']; 
GO 
/* ======================================================== 
-- Proc Name:	utility.[ProcMerge'+replace(mc.TargetTableName, '_', '')+@varProcPostFix+']
-- Author:		John Berry Generated Merge Proc. Pull by ModifiedDate (and iscomplete=1 if exists).  
-- Merge into the table On the unique index setup, otherwise primary key.
-- Create Date: '+FORMAT(GETUTCDATE(),'yyyy-MM-dd') +'
-- Proc Params:	
-- Description:	Standard Merge Proc to load table from data origination source database. 
-- Inserting tracking progress into mergelog table for incremental running.
-- Sample Call:	EXECUTE utility.[ProcMerge'+replace(mc.TargetTableName, '_', '') +@varProcPostFix+']; */ '
			+CHAR(10)+CHAR(13)
			+'CREATE OR ALTER PROCEDURE utility.[ProcMerge'+replace(mc.TargetTableName, '_', '')+@varProcPostFix+'] @inLookBackFactor DECIMAL(20,5) = '+CAST(@inLookBackFactor AS VARCHAR(50))+' as '+CHAR(10)
			+REPLACE(
			-- filter by createddate and modifieddate until the modifieddate can be defaulted.  Thus far using both in conjunction with an index on both only in the barn runs quickly.
			--REPLACE(mc.MergeCode,'WHERE ModifiedDate BETWEEN @VarStartTime AND @VarEndTime', 'WHERE (ModifiedDate BETWEEN @VarStartTime AND @VarEndTime OR CreatedDate Between @VarStartTime AND @VarEndTime)')
			--remember to comment me out if you use the line above.
			mc.MergeCode
			--use passed in lookbackfacter instead of harcoded lookbackfactor.
			,'SET @LookBackFactor='+CAST(@inLookBackFactor AS VARCHAR(50))+';', 'SET @LookBackFactor = @inLookBackFactor;')
			+CHAR(10)+'GO'+CHAR(10) AS CreateProcMergeTable
			, 'EXECUTE utility.[ProcMerge'+mc.TargetTableName+@varProcPostFix+'];' AS ExecTableMergeProc
			,'USE ['+mc.TargetDatabaseName+']; \
			GO \
			CREATE TABLE [utility].[MergeLog]( \
				[MergeLogId] [BIGINT] IDENTITY(1,1) NOT NULL,
				[LoadId] [INT] CONSTRAINT [DF_MergeLog_LoadId]  DEFAULT 1 NOT NULL,
				[SourceLinkedServer] [VARCHAR](100) NULL,
				[SourceDatabase] [VARCHAR](100) NOT NULL,
				[SourceSchema] [VARCHAR](100) NOT NULL,
				[TargetDatabase] [VARCHAR](100) NOT NULL,
				[TargetSchema] [VARCHAR](100) NOT NULL,
				[TableName] [VARCHAR](100) NOT NULL,
				[CreatedDate] [DATETIME2](7) CONSTRAINT [DF_MergeLog_CreatedDate]  DEFAULT GETDATE() NOT NULL ,
				[StartTime] [DATETIME2](7) NOT NULL,
				[EndTime] [DATETIME2](7) NOT NULL,
				[dayScan] [DECIMAL](20, 2) NULL,
				[RowsMoved] [INT] NULL,
				[StartRunTime] DATETIME2 ,
				[EndRunTime] DATETIME2 CONSTRAINT [DF_MergeLog_EndRunTime]  DEFAULT GETDATE() , 
				[loadMessage] [VARCHAR](8000) NULL,
				[generatedTSQL] [VARCHAR](8000) NULL,
				[ProcessSeconds]  AS (DATEDIFF(SECOND,StartRunTime,EndRunTime)),
				[ProcessTimeFormat]  AS (TRY_CONVERT([VARCHAR],DATEADD(SECOND,DATEDIFF_BIG(SECOND,StartRunTime,EndRunTime),(0)),(114))),
			 CONSTRAINT [PK_MergeLog] PRIMARY KEY CLUSTERED 
			([MergeLogId] ASC) WITH ( ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = OFF) ON [PRIMARY]
			);

			CREATE NONCLUSTERED INDEX [IX_MergeLog_CreatedDate] on [utility].[MergeLog] (CreatedDate) WITH ( SORT_IN_TEMPDB = ON,  ONLINE = ON, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = OFF);

			CREATE NONCLUSTERED INDEX [IX_MergeLog] ON [utility].[MergeLog]
			(
				[SourceLinkedServer] ASC,
				[SourceDatabase] ASC,
				[SourceSchema] ASC,
				[TargetDatabase] ASC,
				[TargetSchema] ASC,
				[LoadId] ASC
			) INCLUDE ([EndTime], [StartTime])
			WITH ( SORT_IN_TEMPDB = ON,  ONLINE = ON, ALLOW_ROW_LOCKS = ON, ALLOW_PAGE_LOCKS = OFF) 
			GO' as MergeLogCreateTableDDL
			FROM #TempMergeCode mc 
			ORDER BY mc.TargetSchemaName, mc.TargetTableName
		END
		ELSE 
		BEGIN
			SELECT  @SqlStmt AS GenerateMergeQuery, LEN(@SqlStmt) AS length_query_text
		END
		 
	END
	ELSE
	BEGIN
		------------------------------------------------------------------------------------------------------
		----------------------------------START DYNAMIC CODE EXECUTION ----------------------------------
		------------------------------------------------------------------------------------------------------
		DELETE FROM [utility].[MergeLog] WHERE CreatedDate < GETUTCDATE() - 30;


		OPEN CursorDynamicMerge FETCH NEXT FROM CursorDynamicMerge INTO @MergeCode, @inSourceSchemaName, @inTargetSchemaName, @curTableName;
		WHILE @@FETCH_STATUS =0 AND @inOnlyGenerate=0
		BEGIN
			--WAITFOR DELAY '00:00:01'
			SET @varRowCount =0;
			BEGIN TRY
				IF @varLoadId IS NULL OR @varLoadId =0
				BEGIN
					SELECT @varLoadId = ISNULL(MAX(LoadId),0) + 1 
					from  [utility].[MergeLog] WITH(NOLOCK)
					where isnull(SourceLinkedServer,'') = isnull(@inSourceLinkedServer, '') 
					and SourceDatabase=@inSourceDatabaseName and (SourceSchema=@inSourceSchemaName )
					and TargetDatabase=@inTargetDatabaseName and (TargetSchema=@inTargetSchemaName )
					;
				END;
				SET @varStartTime = GETUTCDATE();
				EXEC sp_executesql @MergeCode;
				SET @varRowCount = @@ROWCOUNT;
				PRINT @curTableName+' ROWS MERGED:'+CAST(@varRowCount AS VARCHAR(50)) ;
				SET @varEndTime = GETUTCDATE();
				/*
				--moved this insert into the generated code.
				INSERT INTO [utility].[MergeLog]([LoadId],[SourceLinkedServer],[SourceDatabase],[SourceSchema],[TargetDatabase],[TargetSchema],[TableName],[StartTime], [EndTime],[dayScan],[RowsMoved],[generatedTSQL])
				VALUES (@varLoadId,@inSourceLinkedServer, @inSourceDatabaseName, @inSourceSchemaName, @inTargetDatabaseName, @inTargetSchemaName, @curTableName,@varStartTime, @varEndTime, @inDaysLookBack,@varRowCount, @MergeCode);
				*/
			END TRY
			BEGIN CATCH
				SET @varErrorMessages = @curTableName+' 1st Error::' +ERROR_MESSAGE()+CHAR(10);
				BEGIN TRY
					EXEC sp_executesql @MergeCode;
					SET @varRowCount = @@ROWCOUNT;
					PRINT ' 2nd Retry of '+@curTableName+' ROWS MERGED:'+CAST(@@ROWCOUNT AS VARCHAR(50)) ;
					SET @varEndTime = GETUTCDATE();
					/*
					--moved this insert into the generated code.
					INSERT INTO [utility].[MergeLog]([LoadId],[SourceLinkedServer],[SourceDatabase],[SourceSchema],[TargetDatabase],[TargetSchema],[TableName],[StartTime], [EndTime],[dayScan],[RowsMoved],[generatedTSQL])
					VALUES (@varLoadId,@inSourceLinkedServer, @inSourceDatabaseName, @inSourceSchemaName, @inTargetDatabaseName, @inTargetSchemaName, @curTableName,@varStartTime, @varEndTime, @inDaysLookBack,@varRowCount, @MergeCode);
					*/
				END TRY
				BEGIN CATCH
					SET @varErrorMessages = @varErrorMessages+@curTableName+' 2nd Error::' +ERROR_MESSAGE()+CHAR(10);
					BEGIN TRY -- do not need a 3rd try as the 3rd execution is the last try.
						EXEC sp_executesql @MergeCode;
						SET @varRowCount = @@ROWCOUNT;
						PRINT ' 3rd Retry of '+@curTableName+' ROWS MERGED:'+CAST(@@ROWCOUNT AS VARCHAR(50)) ;
						SET @varEndTime = GETUTCDATE();
						/*
						--moved this insert into the generated code.
						INSERT INTO [utility].[MergeLog]([LoadId],[SourceLinkedServer],[SourceDatabase],[SourceSchema],[TargetDatabase],[TargetSchema],[TableName],[StartTime], [EndTime],[dayScan],[RowsMoved],[generatedTSQL])
						VALUES (@varLoadId,@inSourceLinkedServer, @inSourceDatabaseName, @inSourceSchemaName, @inTargetDatabaseName, @inTargetSchemaName, @curTableName,@varStartTime, @varEndTime, @inDaysLookBack,@varRowCount, @MergeCode);
						*/
					END TRY
					BEGIN CATCH
						SET @varErrorMessages = @varErrorMessages+@curTableName+' 3rd Error::' +ERROR_MESSAGE()+CHAR(10);
						SET @varErrorNumber = @@ERROR;
						SET @varErrorState = ERROR_STATE();
						SET @varErrorSeverity = ERROR_SEVERITY();

						PRINT '3rd Retry of '+@curTableName+' FAILED!!! '+CHAR(10)+ @varErrorMessages+'Merge Code::'+CHAR(10)+@MergeCode+CHAR(10);
						SET @varEndTime = GETUTCDATE();
						/*
						--moved this insert into the generated code.
						INSERT INTO [utility].[MergeLog]([LoadId],[SourceLinkedServer],[SourceDatabase],[SourceSchema],[TargetDatabase],[TargetSchema],[TableName],[StartTime], [EndTime],[dayScan],[RowsMoved],[generatedTSQL])
						VALUES (@varLoadId,@inSourceLinkedServer, @inSourceDatabaseName, @inSourceSchemaName, @inTargetDatabaseName, @inTargetSchemaName, @curTableName,@varStartTime, @varEndTime, @inDaysLookBack,@varRowCount, @MergeCode);
						*/
					END CATCH
				END CATCH
			END CATCH
			FETCH NEXT FROM CursorDynamicMerge INTO @MergeCode, @inSourceSchemaName, @inTargetSchemaName, @curTableName;
		END
		-- if any tables fail after 3 retries make the procedure fail at the end after trying to load all tables.
		IF(LEN(@varErrorMessages)>2 AND @varErrorNumber IS NOT NULL AND @varErrorSeverity IS NOT NULL ) 
		BEGIN
			--THROW @varErrorNumber, @varErrorMessages, @varErrorState;
			--RAISERROR (@varErrorNumber, @varErrorSeverity, @varErrorState, @varErrorMessages);
			RAISERROR (50001, @varErrorSeverity, @varErrorState, @varErrorMessages);
		END
		------------------------------------------------------------------------------------------------------
		----------------------------------END DYNAMIC CODE EXECUTION ----------------------------------
		------------------------------------------------------------------------------------------------------
	END
END;

GO
