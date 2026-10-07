-- Run connecting to CCS-oak-scn.har.ca.kp.org:1521/NCLNCDQR - KPATHS_CD_ADMIN
--REfresh QA with data in DVE - ccs-ivdc-scn.ivdc.kp.org:1521/NCLNCDDR - CD_ETLSB7.

--REfresh QA with data in DVE - ccs-ivdc-scn.ivdc.kp.org:1521/NCLNCDDR - CD_ETLSB7.
--to refresh entire schema across dblink takes roughly 2 hours or so.


--define source_dblink = '@ NCLNDP1R_KPATHS_CD_AGENT';
define source_dblink = '@NCLNCDDR_CD_SANDBOX7';
--define source_dblink = '';
define source_schema = 'CD_SANDBOX8';
--define source_schema = 'CD_SANDBOX9';
define dest_schema = user;
--      select * from all_db_links

--both selects unioned do not run across dblink for some reason, get error ORA-00997: illegal use of LONG datatype.  Must run each query separately with dblink for deletes.

--select a.table_name, listagg(a.column_name,', ') within group (order by a.column_id) ,C.CONSTRAINT_NAME, c.pk_clause, listagg('a.'||a.column_name||' = b.'||a.column_name,' , ') within group (order by a.column_id) as update_clause


select 
 'MERGE INTO '||a.owner||'.'||a.table_name|| ' a USING  ( SELECT *  FROM '||b.owner||'.'||b.table_name||' &&source_dblink ) b '||
 'ON ('||c.pk_clause||') '
||' WHEN MATCHED THEN UPDATE SET '||c2.update_clause||' '
||' WHEN NOT MATCHED THEN INSERT ( '|| listagg('a.'||a.column_name,', ') within group (order by a.column_id) ||') VALUES ('||listagg( (case when a.column_name= 'CREATE_USER_ID' then 'nvl(b.'||a.column_name||', ''KPATHS'')' when a.column_name like '%!_TS' escape '!' then 'nvl(b.'||a.column_name||', systimestamp)'  else 'b.'||a.column_name end) ,', ') within group (order by a.column_id) ||') '
||';' as stmt
,'DELETE FROM '||a.owner||'.'||a.table_name||' a WHERE NOT EXISTS (select 1 from '||b.owner||'.'||b.table_name||' &&source_dblink b where '||c.pk_clause||'); ' as stmt 
,'-- 1' as fk_comment, d.fk_count, d.max_fk_level, d.max_iscycle, 0 as d_fk_count, 0 as d_max_fk_level, 0 as d_max_iscycle, count(a.column_name) as column_count
 from all_tab_columns a 
 join all_tab_columns &&source_dblink b on a.table_name = b.table_name and a.column_name = b.column_name
 join (      select a1.table_name, a1.owner, a1.constraint_name, listagg('a.'||b1.column_name||' = b.'||b1.column_name,' AND ') within group (order by b1.column_name)  as pk_clause
 from all_constraints a1 join all_cons_columns b1 on b1.constraint_name = a1.constraint_name and a1.table_name = b1.table_name and a1.owner=b1.owner 
 join all_tab_columns &&source_dblink c1 on c1.owner = '&&source_schema' and c1.table_name = b1.table_name and c1.column_name = b1.column_name
 where a1.constraint_type='P'
 group by a1.table_name, a1.owner, a1.constraint_name
 ) c on c.table_name = a.table_name and c.owner=a.owner
 -- select the update clause which does not include the primary key columns 
join (  select b1.table_name, b1.owner, listagg('a.'||b1.column_name||' = '||(case when b1.column_name= 'CREATE_USER_ID' then 'nvl(b.'||b1.column_name||', ''KPATHS'')' when b1.column_name like '%!_TS' escape '!' then 'nvl(b.'||b1.column_name||', systimestamp)'  else 'b.'||b1.column_name end),', ') within group (order by b1.column_name)  as update_clause
 from all_tab_columns b1 
where  b1.column_name not in (select distinct b2.column_name from all_cons_columns b2 join all_constraints b3 on b2.owner=b3.owner and b2.constraint_name = b3.constraint_name and b2.table_name = b3.table_name where  b2.table_name = b1.table_name and b2.owner = b1.owner and b3.constraint_type = 'P')
and  exists (select  b2.column_name from all_tab_columns &&source_dblink b2 where b2.owner = '&&source_schema' and b2.table_name = b1.table_name and b2.column_name = b1.column_name )
 group by b1.table_name, b1.owner
 ) c2 on c2.table_name = a.table_name and c2.owner=a.owner
 left outer join   --used to find the number of times the table is referenced by other tables using a foreign key so the merge can be ran in this order.
 (
SELECT TABLE_NAME, owner, count(distinct fkey_constraint) as fk_count, max(fk_Level) as max_fk_level,max(fk_ISCYCLE) as max_iscycle
from ( SELECT TABLE_NAME, owner,  pkey_constraint,  fkey_constraint,  r_constraint_name,  Level as fk_level,  CONNECT_BY_ISCYCLE as fk_iscycle FROM
  (SELECT a.table_name,a.owner,a.constraint_name pkey_constraint,b.constraint_name fkey_constraint,b.r_constraint_name
  FROM all_constraints a join all_constraints b on a.table_name    = b.table_name and a.owner=b.owner
  AND a.constraint_type = 'P'
  and B.CONSTRAINT_TYPE = 'R'
  and a.owner = '&&dest_schema'
  UNION ALL
  SELECT table_name,owner,constraint_name,NULL,NULL
  FROM all_CONSTRAINTS
  where CONSTRAINT_TYPE = 'P'
  and owner = '&&dest_schema')
  START WITH R_CONSTRAINT_NAME IS NULL CONNECT BY nocycle prior pkey_constraint = r_constraint_name
) group by table_name, owner  
)  d on d.table_name = a.table_name and a.owner= d.owner
 where a.owner = '&&dest_schema'  and b.owner = '&&source_schema' 
 and a.table_name not like '%$%'  --ignore the system error tables. 
 --never load data into these environment specific tables. 
 and a.table_name not in (
     'BG_CONTENT_CONFIGURATION',
    'COMPONENT',
    'NCD_APPLICATION',
    'NCD_APPLICATION_STATUS_REF',
    'NCD_COMPONENT',
    'NCD_COMPONENT_DATA',
    'NCD_COMPONENT_DATA_TYPE',
    'NCD_APPLICATION_STATUS_CDNCD_COMPONENT_DATA',
    'NCD_OBJECT_MAPPER',
    'NCD_REGIONAL_JRULES',
    'MSG_DATABASE_CONNECTIONS', 
    'MSG_CLOSED_ENC_ROUTING',
    'MSG_CONTENT_CONFIGURATION', 
    'CTI_SERVER_CONFIGURATION'
) 
-- ignore tables that reference environment specific tables. If environment specific tables are not loaded then tables referencing them will get foreign key constraint errors
-- So far the only tables not included in the original list of environment specific tables that are references are: REGION, USR_CONTACT_CENTER, NCD_APPLICATION_STATUS_CD, CTI_OUTCOME, SUBCOMPONENT, COMPONENT_EVENT, USR_ROLE_COMPONENT_DISPLAY, KPATHS_APP_USER_LOG 
 and a.table_name not in ( 
     select distinct a1.table_name 
     from all_constraints a1  join all_constraints b1 on b1.owner=a1.owner and A1.R_CONSTRAINT_NAME=b1.constraint_name 
     where a1.owner = a.owner and A1.CONSTRAINT_TYPE='R' and B1.CONSTRAINT_TYPE='P' 
     and b1.table_name in (
        'BG_CONTENT_CONFIGURATION',
        'COMPONENT',
        'NCD_APPLICATION',
        'NCD_APPLICATION_STATUS_REF',
        'NCD_COMPONENT',
        'NCD_COMPONENT_DATA',
        'NCD_COMPONENT_DATA_TYPE',
        'NCD_APPLICATION_STATUS_CDNCD_COMPONENT_DATA',
        'NCD_OBJECT_MAPPER',
        'NCD_REGIONAL_JRULES',
        'MSG_DATABASE_CONNECTIONS', 
        'MSG_CLOSED_ENC_ROUTING',
        'MSG_CONTENT_CONFIGURATION', 
        'CTI_SERVER_CONFIGURATION'
       )
 )
 --if doing a subset of tables you must also transfer all tables that the subset of tables reference....  
group by a.owner, b.owner, a.table_name ,b.table_name, c.constraint_name, c.pk_clause, c2.update_clause,d.fk_count, d.max_fk_level, d.max_iscycle
having count(a.column_name) < 70  --so far the one table CTI_KVP_HSTRY has the most columns(75) making the merge statement too large to build via query, you will get the error "ORA-01489: result of string concatenation is too long"

--order by fk_comment, max_fk_level nulls first, fk_count nulls first, d_max_fk_level desc, d_fk_count desc 

  union all

--deletes can not happen in merge for values not matched in source but exist in destination so a separate delete statement must be generated. 
--deletes can only occur in the matched clause using specific where condidtions.of the data. 
--SQL Server has matched by source and matched by target clause to do a proper delete, but oracle does not.

select
'DELETE FROM '||a.owner||'.'||a.table_name||' a WHERE NOT EXISTS (select 1 from '||b.owner||'.'||b.table_name||' &&source_dblink b where '||c.pk_clause||'); ' as stmt 
,'-- 2' as fk_comment ,0 fk_count, 0 max_fk_level, 0 max_iscycle, d.fk_count as d_fk_count, d.max_fk_level as d_max_fk_level, d.max_iscycle as d_max_iscycle,  count(a.column_name) as column_count
 from all_tab_columns a 
 join all_tab_columns &&source_dblink b on a.table_name = b.table_name and a.column_name = b.column_name
 join (      select a1.table_name, a1.owner, a1.constraint_name, listagg('a.'||b1.column_name||' = b.'||b1.column_name,' AND ') within group (order by b1.column_name)  as pk_clause
 from all_constraints a1 join all_cons_columns b1 on b1.constraint_name = a1.constraint_name and a1.table_name = b1.table_name and a1.owner=b1.owner 
 where a1.constraint_type='P'
 and exists (select  b2.column_name from all_tab_columns &&source_dblink b2 where b2.owner = '&&source_schema' and b2.table_name = b1.table_name and b2.column_name = b1.column_name )
 group by a1.table_name, a1.owner, a1.constraint_name
 ) c on c.table_name = a.table_name and c.owner=a.owner
 -- select the update clause which does not include the primary key columns 
 left outer join   --used to find the number of times the table is referenced by other tables using a foreign key so the merge can be ran in this order.
 (
SELECT TABLE_NAME, owner, count(distinct fkey_constraint) as fk_count, max(fk_Level) as max_fk_level,max(fk_ISCYCLE) as max_iscycle
from ( SELECT TABLE_NAME, owner,  pkey_constraint,  fkey_constraint,  r_constraint_name,  Level as fk_level,  CONNECT_BY_ISCYCLE as fk_iscycle FROM
  (SELECT a.table_name,a.owner,a.constraint_name pkey_constraint,b.constraint_name fkey_constraint,b.r_constraint_name
  FROM all_constraints a join all_constraints b on a.table_name    = b.table_name and a.owner=b.owner
  AND a.constraint_type = 'P'
  and B.CONSTRAINT_TYPE = 'R'
  and a.owner = '&&dest_schema'
  UNION ALL
  SELECT table_name,owner,constraint_name,NULL,NULL
  FROM all_CONSTRAINTS
  where CONSTRAINT_TYPE = 'P'
  and owner = '&&dest_schema')
  START WITH R_CONSTRAINT_NAME IS NULL CONNECT BY nocycle prior pkey_constraint = r_constraint_name
) group by table_name, owner  
)  d on d.table_name = a.table_name and a.owner= d.owner
 where a.owner = '&&dest_schema'  and b.owner = '&&source_schema' 
 and a.table_name not like '%$%'  --ignore the system error tables. 
 --never load data into these environment specific tables. 
 and a.table_name not in (
    'BG_CONTENT_CONFIGURATION',
    'COMPONENT',
    'NCD_APPLICATION',
    'NCD_APPLICATION_STATUS_REF',
    'NCD_COMPONENT',
    'NCD_COMPONENT_DATA',
    'NCD_COMPONENT_DATA_TYPE',
    'NCD_APPLICATION_STATUS_CDNCD_COMPONENT_DATA',
    'NCD_OBJECT_MAPPER',
    'NCD_REGIONAL_JRULES',
    'MSG_DATABASE_CONNECTIONS', 
    'MSG_CLOSED_ENC_ROUTING',
    'MSG_CONTENT_CONFIGURATION', 
    'CTI_SERVER_CONFIGURATION'
) 
-- ignore tables that reference environment specific tables. If environment specific tables are not loaded then tables referencing them will get foreign key constraint errors
-- So far the only tables not included in the original list of environment specific tables that are references are: REGION, USR_CONTACT_CENTER, NCD_APPLICATION_STATUS_CD, CTI_OUTCOME, SUBCOMPONENT, COMPONENT_EVENT, USR_ROLE_COMPONENT_DISPLAY, KPATHS_APP_USER_LOG 
 and a.table_name not in ( select distinct a1.table_name from all_constraints a1  join all_constraints b1 on b1.owner=a1.owner and A1.R_CONSTRAINT_NAME=b1.constraint_name 
 where a1.owner = a.owner and A1.CONSTRAINT_TYPE='R' and B1.CONSTRAINT_TYPE='P' and b1.table_name in (
    'BG_CONTENT_CONFIGURATION',
    'COMPONENT',
    'NCD_APPLICATION',
    'NCD_APPLICATION_STATUS_REF',
    'NCD_COMPONENT',
    'NCD_COMPONENT_DATA',
    'NCD_COMPONENT_DATA_TYPE',
    'NCD_APPLICATION_STATUS_CDNCD_COMPONENT_DATA',
    'NCD_OBJECT_MAPPER',
    'NCD_REGIONAL_JRULES',
    'MSG_DATABASE_CONNECTIONS', 
    'MSG_CLOSED_ENC_ROUTING',
    'MSG_CONTENT_CONFIGURATION', 
    'CTI_SERVER_CONFIGURATION'
   )
 )
  --if doing a subset of tables you must also transfer all tables that the subset of tables reference....  
group by a.owner, b.owner, a.table_name ,b.table_name, c.pk_clause, d.fk_count, d.max_fk_level, d.max_iscycle
having count(a.column_name) < 70  --so far the one table CTI_KVP_HSTRY has the most columns(75) making the merge statement too large to build via query, you will get the error "ORA-01489: result of string concatenation is too long"

/***/
union all select 'commit;', '--3', 0,0,0,0,0,0,0 from dual -- add commit to the very bottom.

order by fk_comment, max_fk_level nulls first, fk_count nulls first, d_max_fk_level desc, d_fk_count desc 



/*


select 'alter table '||c.owner||'.'||c.table_name||' DISABLE CONSTRAINT '||c.constraint_name||';'
from all_constraints c join all_constraints c2 on c2.owner = c.r_owner and c2.constraint_name = c.r_constraint_name
where c.owner = 'KPATHS_CD'
and (c.table_name in (select table_name from all_tables where owner = 'KPATHS_CD' and table_name like 'CL!_%' escape '!')
or c2.table_name in (select table_name from all_tables where owner = 'KPATHS_CD' and table_name like 'CL!_%' escape '!')
)
order by c.constraint_type desc, c.r_constraint_name nulls first


select * from all_constraints


--testing queries.
select a.table_name, count(*)
from all_constraints a join all_constraints b on a.owner=b.R_owner and A.CONSTRAINT_NAME =b.r_constraint_name
where a.owner = 'KPATHS_CD'
group by a.table_name
order by count(*) 


    select a1.owner, a1.table_name, a1.constraint_name, 
        (select  listagg( b1.column_name,', ') within group (order by b1.column_name) from all_cons_columns b1 where b1.constraint_name = a1.constraint_name and a1.table_name = b1.table_name and a1.owner=b1.owner) as constraint_columns,
    a1.constraint_type, a1.validated,a1.status, a1.r_constraint_name, a2.table_name as referenced_table
 from all_constraints a1 join all_constraints a2 on a1.owner=a2.owner and a1.r_constraint_name = a2.constraint_name
    where a1.owner ='CD_SANDBOX9' and a1.constraint_type = 'R'  and a1.status <>'ENABLED'



 
    select 
    listagg('a.'||b1.column_name||' = b.'||b1.column_name,' AND ') within group (order by b1.column_name) as pk_clause
 from all_constraints a1 join all_cons_columns b1 on b1.constraint_name = a1.constraint_name and a1.table_name = b1.table_name
    where a1.owner ='KPATHS_CD' and a1.constraint_type = 'P'
  group by a1.owner, a1.table_name, a1.constraint_name
    
   select a1.table_name, a1.owner, a1.constraint_name, listagg('a.'||b1.column_name||' = b.'||b1.column_name,' AND ') within group (order by b1.column_name)  as pk_clause
 from all_constraints a1 join all_cons_columns b1 on b1.constraint_name = a1.constraint_name and a1.table_name = b1.table_name and a1.owner=b1.owner
 where a1.constraint_type='P'
 group by a1.table_name, a1.owner, a1.constraint_name

select * from all_tables @NCLNCDDR_CD_SANDBOX6 where owner = 'CD_ETLSB7'


select  owner, table_name, listagg(column_name,', ') within group (order by column_id)
from all_tab_columns
group by owner,table_name;


*/
