import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {randomUUID} from 'node:crypto';
import test from 'node:test';
import {PGlite} from '@electric-sql/pglite';
import {availableGrainStores,isStoreArchived} from '../lib/cometa-grain.ts';
const read=path=>readFile(new URL('../'+path,import.meta.url),'utf8');
function fn(source,name){const start=source.indexOf('create or replace function '+name+'(');return source.slice(start,source.indexOf('$$;',source.indexOf('as $$',start))+3)}

test('used empty bags archive automatically, block new harvests and transfers, and reactivate only when stock is restored by undo',async()=>{
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
  const field=(await q("select save_cometa_field($1,'Lote',25) as id",[org]))[0].id;
  const createBag=async()=>(await q("select save_cometa_grain_store($1,'bag','Bolsa 1','Casa',null,null,$2) as data",[org,randomUUID()]))[0].data;
  const used=await createBag(),fresh=await createBag(),partial=await createBag(),reversed=await createBag();
  const fixed=(await q('select id from cometa_grain_stores where organization_id=$1 and kind=$2 limit 1',[org,'silo']))[0].id;
  const harvest=async(store,tonnes=5,id=randomUUID())=>(await q('select register_cometa_harvest_with_season($1,$2,$3,$4,$5,$6,$7,$8,$9) as id',[org,id,'2026-11-01',field,'2026/27','Maíz',tonnes,JSON.stringify([{kind:'deposit',store_id:store,tonnes}]),'gruesa']))[0].id;
  const h1=await harvest(used.id),h2=await harvest(partial.id),rev=await harvest(reversed.id);
  const batch=async(from,to,harvestId,tonnes,id=randomUUID())=>(await q('select register_cometa_grain_batch($1,$2,$3,$4,$5,$6,$7,$8) as id',[org,id,'2026-11-02',to?'transfer':'sale',JSON.stringify([{source_id:from,harvest_id:harvestId,tonnes}]),to,'Salida prueba','']))[0].id;
  const exhausted=await batch(used.id,fixed,h1,5);
  await batch(partial.id,null,h2,4.999);
  await q('select void_cometa_grain_operation($1,$2)',[org,rev]);
  const archiveMigration=await read('supabase/migrations/085_cometa_archive_empty_bags.sql');await db.exec(archiveMigration);await db.exec(archiveMigration);
  const report=async()=>(await q('select get_cometa_grain($1) as data',[org]))[0].data;
  let data=await report();const byId=id=>data.stores.find(s=>s.id===id);
  assert.equal(byId(used.id).archived,true);assert.equal(byId(fresh.id).archived,false);assert.equal(byId(partial.id).archived,false);assert.equal(byId(reversed.id).archived,false);assert.equal(byId(fixed).archived,false);
  assert.ok(!availableGrainStores(data).some(s=>s.id===used.id));assert.ok(availableGrainStores(data).some(s=>s.id===fresh.id));
  const before=(await q('select count(*)::int as n from cometa_harvests'))[0].n;
  assert.equal(await harvest(used.id,5,h1),h1);
  await assert.rejects(harvest(used.id),/archivada/);
  assert.equal((await q('select count(*)::int as n from cometa_harvests'))[0].n,before);
  await assert.rejects(batch(fixed,used.id,h1,1),/archivada/);
  await assert.rejects(q("select register_cometa_grain_exit($1,$2,$3,'2026-11-02','transfer',$4,$5,1)",[org,randomUUID(),h1,fixed,used.id]),/archivada/);
  // An operation failing on its second destination must roll back its earlier deposit too.
  const failedId=randomUUID();await assert.rejects(q("select register_cometa_harvest_with_season($1,$2,'2026-11-03',$3,'2026/27','Maíz',2,$4,'gruesa')",[org,failedId,field,JSON.stringify([{kind:'deposit',store_id:fresh.id,tonnes:1},{kind:'deposit',store_id:used.id,tonnes:1}])]),/archivada/);
  assert.equal((await q('select count(*)::int as n from cometa_grain_events where operation_id=$1',[failedId]))[0].n,0);
  const h3=await harvest(fresh.id,2);await harvest(partial.id,1);await harvest(reversed.id,1);
  data=await report();assert.equal(byId(fresh.id).archived,false);
  // Retrying the operation that emptied a bag is still idempotent.
  await batch(used.id,fixed,h1,5,exhausted);assert.equal((await report()).stores.find(s=>s.id===used.id).archived,true);
  await q('select void_cometa_grain_operation($1,$2)',[org,exhausted]);
  data=await report();assert.equal(byId(used.id).archived,false);assert.equal(Number(data.balances.find(b=>b.store_id===used.id).tonnes),5);
  await harvest(used.id,1);data=await report();
  const entries=data.balances.filter(b=>b.store_id===used.id).map(b=>({harvest_id:b.harvest_id,tonnes:Number(b.tonnes)}));
  const clearId=randomUUID();await q("select clear_cometa_grain_store($1,$2,$3,'2026-11-04',$4,'Remanente')",[org,clearId,used.id,JSON.stringify(entries)]);
  data=await report();assert.equal(byId(used.id).archived,true);assert.ok(data.events.some(e=>e.destination_id===used.id));assert.equal(byId(used.id).bag_number,used.bag_number);
  await assert.rejects(harvest(used.id),/archivada/);
  await q('select void_cometa_grain_operation($1,$2)',[org,clearId]);data=await report();assert.equal(byId(used.id).archived,false);
  assert.ok(data.harvests.some(h=>h.id===h3));assert.equal((await q('select count(*)::int as n from cometa_movements'))[0].n,0);
  await db.exec('set role authenticated');
  await assert.rejects(q('select cometa_bag_is_archived($1)',[used.id]),/permission denied/);
  assert.ok((await report()).stores.some(s=>s.id===used.id));
 }finally{await db.close()}
});

test('UI fallback keeps unused and partially full bags active, excluding only used zero bags',()=>{
 const stores=[{id:'unused',kind:'bag'},{id:'used',kind:'bag'},{id:'partial',kind:'bag'},{id:'cancelled',kind:'bag'},{id:'fixed',kind:'silo'}];
 const data={stores,harvests:[],fields:[],balances:[{store_id:'partial',tonnes:0.001}],events:[{destination_id:'used',voided_at:null},{destination_id:'partial',voided_at:null},{destination_id:'cancelled',voided_at:'2026-11-01'}]};
 assert.deepEqual(availableGrainStores(data).map(s=>s.id),['unused','partial','cancelled','fixed']);
 assert.equal(isStoreArchived({...stores[1],archived:true},data),true);
 assert.equal(isStoreArchived({...stores[0],archived:false},data),false);
});

