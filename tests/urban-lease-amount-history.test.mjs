import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {randomUUID} from 'node:crypto';
import test from 'node:test';
import {PGlite} from '@electric-sql/pglite';
const read=path=>readFile(new URL('../'+path,import.meta.url),'utf8');
function fn(source,name){const start=source.indexOf('create or replace function '+name+'(');return source.slice(start,source.indexOf('$$;',source.indexOf('as $$',start))+3)}
test('amount history recovers the starting rent and each recorded adjustment for the selected department only',async()=>{
 const db=new PGlite(),org=randomUUID(),other=randomUUID(),actor=randomUUID(),building=randomUUID(),unit=randomUUID(),tenant=randomUUID(),lease=randomUUID(),oldLease=randomUUID();
 const q=async(sql,args=[])=>(await db.query(sql,args)).rows;
 try{
  const schema=await read('supabase/migrations/001_initial_rentals_schema.sql');
  await db.exec("create role anon;create role authenticated;create schema auth;create table auth.users(id uuid primary key);create function auth.uid() returns uuid language sql stable as $$select nullif(current_setting('test.actor',true),'')::uuid;$$;");
  await db.exec(schema.match(/create type \w+ as enum \([\s\S]*?\);/g).join('\n'));await db.exec(schema.match(/create table \w+ \([\s\S]*?\r?\n\);/g).join('\n'));
  for(const name of ['is_org_member','has_org_role'])await db.exec(fn(schema,name));
  await q("select set_config('test.actor',$1,false)",[actor]);await q('insert into auth.users values($1)',[actor]);await q("insert into profiles(id,email) values($1,'test@local')",[actor]);
  await q("insert into organizations(id,name,slug) values($1,'Org','org'),($2,'Otra','otra')",[org,other]);
  await q("insert into organization_members(organization_id,user_id,role,status) values($1,$2,'owner','active')",[org,actor]);
  await q("insert into urban_buildings(id,organization_id,name) values($1,$2,'PELLEGRINI')",[building,org]);
  await q("insert into urban_units(id,organization_id,building_id,name,surface_m2,status) values($1,$2,$3,'DPTO 4',13.33,'rented')",[unit,org,building]);
  await q("insert into contacts(id,organization_id,first_name,last_name) values($1,$2,'MAURO','MOLINERO')",[tenant,org]);
  await q("insert into urban_leases(id,organization_id,unit_id,primary_tenant_contact_id,start_date,end_date,current_amount,currency,monthly_due_day,status,next_adjustment_date,adjustment_frequency_months) values($1,$2,$3,$4,'2026-01-01','2028-12-31',700,'USD',10,'active','2026-12-01',4),($5,$2,$3,$4,'2024-01-01','2025-12-31',200,'ARS',10,'finalized',null,4)",[lease,org,unit,tenant,oldLease]);
  await q("insert into audit_logs(organization_id,action,entity_type,entity_id,new_values) values($1,'urban_lease_started','urban_lease',$2,$3)",[org,lease,JSON.stringify({lease:{current_amount:500,currency:'ARS'}})]);
  for(const [date,before,after,currency,previousCurrency] of [['2026-05-01',500,600,'ARS','ARS'],['2026-09-01',600,700,'USD','ARS']]){
   await q("insert into urban_lease_adjustments(organization_id,lease_id,effective_date,previous_amount,new_amount,currency,created_at) values($1,$2,$3,$4,$5,$6,$3::date::timestamptz)",[org,lease,date,before,after,currency]);
   await q("insert into audit_logs(organization_id,action,entity_type,entity_id,old_values,new_values,occurred_at) values($1,'urban_lease_updated','urban_lease',$2,$3,$4,$5::date::timestamptz)",[org,lease,JSON.stringify({current_amount:before,currency:previousCurrency}),JSON.stringify({current_amount:after,currency}),date]);
  }
  const migration=await read('supabase/migrations/076_urban_lease_amount_history.sql');await db.exec(migration);await db.exec(migration);
  const history=async(organization=org,target=unit)=>(await q('select get_urban_lease_amount_history($1,$2) as result',[organization,target]))[0].result;
  const before=await q('select * from urban_leases order by id');
  let data=await history(),current=data.find(row=>row.id===lease);
  assert.equal(data.length,2);assert.equal(current.initialSource,'creation_record');
  assert.deepEqual(current.entries.map(row=>Number(row.amount)),[500,600,700]);
  assert.deepEqual(current.entries.map(row=>row.currency),['ARS','ARS','USD']);
  assert.equal(current.entries[2].previousCurrency,'ARS');assert.equal(current.entries[0].date,'2026-01-01');
  assert.equal(data.find(row=>row.id===oldLease).entries.length,1);
  assert.deepEqual(await history(other),[]);assert.deepEqual(await history(org,randomUUID()),[]);
  assert.deepEqual(await q('select * from urban_leases order by id'),before);
  await db.exec(fn(await read('supabase/migrations/008_urban_lease_lifecycle_rpcs.sql'),'update_active_urban_lease'));
  await q("select update_active_urban_lease($1,$2,lease_next_adjustment_date=>'2027-04-01')",[org,unit]);
  assert.equal((await history()).find(row=>row.id===lease).entries.length,3);
  await q("select update_active_urban_lease($1,$2,lease_amount=>800,lease_currency=>'USD')",[org,unit]);
  current=(await history()).find(row=>row.id===lease);
  assert.equal(current.entries.length,4);assert.equal(Number(current.entries[3].amount),800);assert.equal(current.entries[3].previousCurrency,'USD');
  // Legacy initial rent can also be recovered from the previous value of the first logged change.
  await q("delete from audit_logs where entity_id=$1 and action='urban_lease_started'",[lease]);
  current=(await history()).find(row=>row.id===lease);
  assert.equal(current.initialSource,'first_adjustment');assert.equal(Number(current.entries[0].amount),500);assert.equal(current.entries[0].currency,'ARS');
  await q("update organization_members set role='viewer' where organization_id=$1",[org]);
  assert.equal((await history()).length,2);
  await q("select set_config('test.actor','',false)");
  assert.deepEqual(await history(),[]);
 }finally{await db.close()}
});
