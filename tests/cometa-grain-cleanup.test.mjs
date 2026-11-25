import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {randomUUID} from 'node:crypto';
import test from 'node:test';
import {PGlite} from '@electric-sql/pglite';
import {harvestCropTotals} from '../lib/cometa-grain.ts';
const read=path=>readFile(new URL('../'+path,import.meta.url),'utf8');
function fn(source,name){const start=source.indexOf('create or replace function '+name+'(');return source.slice(start,source.indexOf('$$;',source.indexOf('as $$',start))+3)}

test('one-off grain cleanup removes only voided records, preserves stock and cash, backs up history and blocks replay',async()=>{
 const db=new PGlite(),org=randomUUID(),other=randomUUID(),actor=randomUUID();
 const q=async(sql,args=[])=>(await db.query(sql,args)).rows;
 try{
  const schema=await read('supabase/migrations/001_initial_rentals_schema.sql');
  await db.exec("create role anon;create role authenticated;create schema auth;create table auth.users(id uuid primary key);create function auth.uid() returns uuid language sql stable as $$select nullif(current_setting('test.actor',true),'')::uuid;$$;grant usage on schema auth to authenticated;create schema storage;create table storage.objects(bucket_id text,name text);");
  await db.exec(schema.match(/create type \w+ as enum \([\s\S]*?\);/g).join('\n'));
  await db.exec(schema.match(/create table \w+ \([\s\S]*?\r?\n\);/g).join('\n'));
  for(const name of ['is_org_member','has_org_role'])await db.exec(fn(schema,name));
  await q("select set_config('test.actor',$1,false)",[actor]);
  await q('insert into auth.users values($1)',[actor]);await q("insert into profiles(id,email) values($1,'test@local')",[actor]);
  await q("insert into organizations(id,name,slug) values($1,'Campo','campo'),($2,'Otro','otro')",[org,other]);
  await q("insert into organization_members(organization_id,user_id,role,status) values($1,$2,'owner','active')",[org,actor]);
  await db.exec(await read('supabase/migrations/074_cometa_agricultural_movements.sql'));




  for(const path of ['078_cometa_harvest_and_grain.sql','079_cometa_harvest_seasons_and_fields.sql','080_cometa_field_hectares_and_yield.sql'])await db.exec(await read('supabase/migrations/'+path));
  const migration=await read('supabase/migrations/081_cometa_multi_source_extractions.sql');await db.exec(migration);await db.exec(migration);
  const clearMigration=await read('supabase/migrations/083_cometa_clear_stock.sql');await db.exec(clearMigration);await db.exec(clearMigration);
  await db.exec(await read('supabase/migrations/084_cometa_bag_numbers.sql'));
  await db.exec(await read('supabase/migrations/085_cometa_archive_empty_bags.sql'));
  await db.exec(await read('supabase/migrations/086_cometa_delete_empty_bags.sql'));
  const field=(await q("select save_cometa_field($1,'Lote real',25) as id",[org]))[0].id;
  const fixed=(await q("select id from cometa_grain_stores where organization_id=$1 and kind='silo' limit 1",[org]))[0].id;
  const bag=(await q("select save_cometa_grain_store($1,'bag','Bolsa real','Casa',null,null,$2) as data",[org,randomUUID()]))[0].data.id;
  const harvest=async(store,tonnes,id=randomUUID())=>(await q("select register_cometa_harvest_with_season($1,$2,'2026-11-01',$3,'2026/27','Maíz',$4,$5,'gruesa')",[org,id,field,tonnes,JSON.stringify([{kind:'deposit',store_id:store,tonnes}])]))[0];
  const validId=randomUUID(),cancelledId=randomUUID();await harvest(fixed,100,validId);await harvest(fixed,5,cancelledId);await q('select void_cometa_grain_operation($1,$2)',[org,cancelledId]);
  const batch=async({id=randomUUID(),from=fixed,to=null,tonnes=10}={})=>{await q("select register_cometa_grain_batch($1,$2,'2026-11-02',$3,$4,$5,'Detalle','')",[org,id,to?'transfer':'sale',JSON.stringify([{source_id:from,harvest_id:validId,tonnes}]),to]);return id};
  const cancelledExit=await batch({tonnes:20});await q('select void_cometa_grain_operation($1,$2)',[org,cancelledExit]);
  await batch({tonnes:10});const transfer=await batch({to:bag,tonnes:40});
  const cancelledTransfer=await batch({from:bag,to:fixed,tonnes:5});await q('select void_cometa_grain_operation($1,$2)',[org,cancelledTransfer]);
  const category=(await q("select id from cometa_categories where organization_id=$1 and name='Insumos'",[org]))[0].id;
  const cash=(await q("select * from register_cometa_movement($1,'expense','2026-11-05',$2,37.5,'ARS','Prueba caja',null,null,null,null,null,$3)",[org,category,randomUUID()]))[0];
  await q('select void_cometa_movement($1,$2)',[org,cash.id]);
  const report=async()=>(await q('select get_cometa_grain($1) as data',[org]))[0].data;
  const balances=data=>data.balances.slice().sort((a,b)=>(a.harvest_id+a.store_id).localeCompare(b.harvest_id+b.store_id));
  const before=await report(),beforeCash=await q('select * from cometa_movements order by id'),beforeStores=await q('select * from cometa_grain_stores order by id');
  const activeBefore=before.events.filter(e=>!e.voided_at);
  const cleanupScript=await read('supabase/maintenance/cleanup_voided_cometa_grain.sql');await db.exec(cleanupScript);
  const after=await report();assert.deepEqual(balances(after),balances(before));assert.deepEqual(harvestCropTotals(after),harvestCropTotals(before));
  assert.deepEqual(after.events,activeBefore);assert.equal(after.harvests.length,1);assert.equal(after.harvests[0].id,validId);
  assert.deepEqual(await q('select * from cometa_movements order by id'),beforeCash);assert.deepEqual(await q('select * from cometa_grain_stores order by id'),beforeStores);
  const backup=await q('select * from cometa_grain_cleanup_archive');assert.equal(backup.length,4);assert.equal(backup.filter(r=>r.entity_type==='event').length,3);assert.equal(backup.find(r=>r.entity_type==='harvest').entity_id,cancelledId);
  assert.ok(backup.filter(r=>r.entity_type==='event').every(r=>r.original_row.voided_at));
  await db.exec(cleanupScript);assert.equal((await q('select count(*)::int as n from cometa_grain_cleanup_archive'))[0].n,4);
  await assert.rejects(harvest(fixed,5,cancelledId),/anulada y limpiada/);await assert.rejects(batch({id:cancelledExit,tonnes:20}),/anulada y limpiada/);
  assert.deepEqual(balances(await report()),balances(after));
  await q('select void_cometa_grain_operation($1,$2)',[org,transfer]);assert.equal(Number((await report()).balances.find(b=>b.store_id===fixed).tonnes),90);
  // More than one agricultural organization requires an explicit selection and changes nothing.
  const otherField=randomUUID();await q("insert into cometa_fields(id,organization_id,name) values($1,$2,'Otro lote')",[otherField,other]);
  await q("insert into cometa_harvests(id,organization_id,field_id,harvest_date,campaign,crop,tonnes,request) values($1,$2,$3,'2026-11-01','2026/27','Soja',1,'{}')",[randomUUID(),other,otherField]);
  const eventsBefore=await q('select * from cometa_grain_events order by sequence');
  await assert.rejects(db.exec(cleanupScript),/elegir una organizacion/);await db.exec('rollback');
  assert.deepEqual(await q('select * from cometa_grain_events order by sequence'),eventsBefore);
  await db.exec('set role authenticated');await assert.rejects(q('select * from cometa_grain_cleanup_archive'),/permission denied/);
 }finally{await db.close()}
});

