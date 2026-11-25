import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {randomUUID} from 'node:crypto';
import test from 'node:test';
import {PGlite} from '@electric-sql/pglite';
import {availableGrainStores,isStoreArchived} from '../lib/cometa-grain.ts';
const read=path=>readFile(new URL('../'+path,import.meta.url),'utf8');
function fn(source,name){const start=source.indexOf('create or replace function '+name+'(');return source.slice(start,source.indexOf('$$;',source.indexOf('as $$',start))+3)}

test('empty bags can be removed safely without stock or identity loss; stale destinations are blocked and undo restores visibility',async()=>{
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
  const archiveMigration=await read('supabase/migrations/085_cometa_archive_empty_bags.sql');await db.exec(archiveMigration);
  const field=(await q("select save_cometa_field($1,'Lote',25) as id",[org]))[0].id;
  const createBag=async()=>(await q("select save_cometa_grain_store($1,'bag','Bolsa 1','Casa',null,null,$2) as data",[org,randomUUID()]))[0].data;
  const fresh=await createBag(),stocked=await createBag(),used=await createBag();
  const fixed=(await q('select id from cometa_grain_stores where organization_id=$1 and kind=$2 limit 1',[org,'silo']))[0].id;
  const harvest=async(store,tonnes=5,id=randomUUID())=>(await q('select register_cometa_harvest_with_season($1,$2,$3,$4,$5,$6,$7,$8,$9) as id',[org,id,'2026-11-01',field,'2026/27','Maíz',tonnes,JSON.stringify([{kind:'deposit',store_id:store,tonnes}]),'gruesa']))[0].id;
  const h1=await harvest(stocked.id,0.001),h2=await harvest(used.id,5);
  const clearId=randomUUID();await q("select clear_cometa_grain_store($1,$2,$3,'2026-11-02',$4,'Remanente')",[org,clearId,used.id,JSON.stringify([{harvest_id:h2,tonnes:5}])]);
  const migrationDelete=await read('supabase/migrations/086_cometa_delete_empty_bags.sql');await db.exec(migrationDelete);await db.exec(migrationDelete);
  const report=async()=>(await q('select get_cometa_grain($1) as data',[org]))[0].data;
  const remove=async(store,organization=org)=>q('select delete_cometa_empty_bag($1,$2)',[organization,store]);
  await remove(fresh.id);let data=await report();const deletedAt=data.stores.find(s=>s.id===fresh.id).deleted_at;
  assert.ok(deletedAt);assert.equal(availableGrainStores(data).some(s=>s.id===fresh.id),false);
  await remove(fresh.id);assert.equal((await report()).stores.find(s=>s.id===fresh.id).deleted_at,deletedAt);
  await assert.rejects(remove(stocked.id),/tiene stock/);await assert.rejects(remove(fixed),/no pertenece/);await assert.rejects(remove(randomUUID()),/no pertenece/);
  await assert.rejects(harvest(fresh.id),/eliminada/);
  await assert.rejects(q("select register_cometa_grain_batch($1,$2,'2026-11-03','transfer',$3,$4,'Traslado','')",[org,randomUUID(),JSON.stringify([{source_id:stocked.id,harvest_id:h1,tonnes:0.001}]),fresh.id]),/eliminada/);
  await assert.rejects(q("select register_cometa_grain_exit($1,$2,$3,'2026-11-03','transfer',$4,$5,0.001)",[org,randomUUID(),h1,stocked.id,fresh.id]),/eliminada/);
  await remove(used.id);data=await report();
  assert.ok(data.stores.find(s=>s.id===used.id).deleted_at);assert.ok(data.events.some(e=>e.destination_id===used.id));assert.equal(data.stores.find(s=>s.id===used.id).bag_number,used.bag_number);
  assert.equal(await harvest(used.id,5,h2),h2);assert.ok((await report()).stores.find(s=>s.id===used.id).deleted_at);
  // Correcting the liquidation must not leave restored stock hidden.
  await q('select void_cometa_grain_operation($1,$2)',[org,clearId]);data=await report();
  assert.equal(data.stores.find(s=>s.id===used.id).deleted_at,null);assert.equal(data.stores.find(s=>s.id===used.id).archived,false);
  assert.equal(availableGrainStores(data).some(s=>s.id===used.id),true);assert.equal(Number(data.balances.find(b=>b.store_id===used.id).tonnes),5);
  await assert.rejects(remove(used.id),/tiene stock/);
  const next=await createBag();assert.ok(next.bag_number>used.bag_number);
  const foreign=(await q("insert into cometa_grain_stores(organization_id,location,name,kind) values($1,'Casa','Ajena','bag') returning id",[other]))[0].id;
  await assert.rejects(remove(foreign),/no pertenece/);await assert.rejects(remove(fresh.id,other),/permisos/);
  assert.equal((await q('select count(*)::int as n from cometa_movements'))[0].n,0);
  assert.equal((await q('select count(*)::int as n from cometa_harvests'))[0].n,2);
  await q("update organization_members set role='viewer' where organization_id=$1",[org]);await assert.rejects(remove(next.id),/permisos/);
  await db.exec('set role authenticated');await assert.rejects(q('delete from cometa_grain_stores where id=$1',[fresh.id]),/permission denied/);
 }finally{await db.close()}
});

test('removed bags are excluded from destinations even when they have never held grain',()=>{
 const data={fields:[],harvests:[],events:[],balances:[],stores:[{id:'removed',kind:'bag',deleted_at:'2026-11-25'},{id:'new',kind:'bag'},{id:'fixed',kind:'silo'}]};
 assert.deepEqual(availableGrainStores(data).map(s=>s.id),['new','fixed']);
});

