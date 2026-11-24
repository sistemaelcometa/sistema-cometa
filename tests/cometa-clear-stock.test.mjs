import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {randomUUID} from 'node:crypto';
import test from 'node:test';
import {PGlite} from '@electric-sql/pglite';
import {bagReferenceTonnes,grainEventName,groupGrainEvents} from '../lib/cometa-grain.ts';
const read=path=>readFile(new URL('../'+path,import.meta.url),'utf8');
function fn(source,name){const start=source.indexOf('create or replace function '+name+'(');return source.slice(start,source.indexOf('$$;',source.indexOf('as $$',start))+3)}

test('stock liquidation empties all store origins atomically, protects concurrent changes and retries, supports undo and never writes cash',async()=>{
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
  const fixed=(await q('select id from cometa_grain_stores where organization_id=$1 order by name limit 1',[org]))[0].id;
  const otherStore=(await q('select id from cometa_grain_stores where organization_id=$1 and id<>$2 limit 1',[org,fixed]))[0].id;
  const bag=(await q("select configure_cometa_grain($1,'bag','Bolsa prueba','Casa') as id",[org]))[0].id;
  const foreign=(await q('select id from cometa_grain_stores where organization_id=$1 limit 1',[other]))[0].id;
  const field=(await q("select save_cometa_field($1,'Lote',25) as id",[org]))[0].id;
  const harvest=async(amount,allocations)=>(await q('select register_cometa_harvest_with_season($1,$2,$3,$4,$5,$6,$7,$8,$9) as id',[org,randomUUID(),'2026-11-01',field,'2026/27','Soja',amount,JSON.stringify(allocations),'gruesa']))[0].id;
  const h1=await harvest(3.125,[{kind:'deposit',store_id:bag,tonnes:3.125}]);
  const h2=await harvest(9.875,[{kind:'deposit',store_id:bag,tonnes:1.875},{kind:'deposit',store_id:otherStore,tonnes:8}]);
  const report=async()=>(await q('select get_cometa_grain($1) as data',[org]))[0].data;
  const expected=async(store)=>(await report()).balances.filter(row=>row.store_id===store&&Number(row.tonnes)>0).map(row=>({harvest_id:row.harvest_id,tonnes:Number(row.tonnes)}));
  const amount=async(store)=>(await expected(store)).reduce((sum,row)=>sum+Math.round(row.tonnes*1000),0)/1000;
  const count=async()=>(await q('select count(*)::int as n from cometa_grain_events'))[0].n;
  const batch=async(parts,kind='sale',to=null,date='2026-11-02')=>(await q('select register_cometa_grain_batch($1,$2,$3,$4,$5,$6,$7,$8) as id',[org,randomUUID(),date,kind,JSON.stringify(parts),to,'Traslado prueba','']))[0].id;
  const clear=async({id=randomUUID(),store=fixed,date='2026-11-03',parts,organization=org,detail='Remanente a tolva',reference=''}={})=>(await q('select clear_cometa_grain_store($1,$2,$3,$4,$5,$6,$7) as id',[organization,id,store,date,JSON.stringify(parts===undefined?await expected(store):parts),detail,reference]))[0].id;
  const transfer=await batch((await expected(bag)).map(row=>({...row,source_id:bag})),'transfer',fixed);
  assert.equal(await amount(bag),0);assert.equal(await amount(fixed),5);assert.equal(await amount(otherStore),8);
  const snapshot=await expected(fixed),op=randomUUID();assert.equal(await clear({id:op,parts:snapshot}),op);
  assert.equal(await amount(fixed),0);assert.equal(await amount(otherStore),8);
  const events=(await report()).events.filter(row=>row.operation_id===op);
  assert.equal(events.length,2);assert.ok(events.every(row=>row.request.stock_clear&&row.request.batch_exit));
  assert.equal(groupGrainEvents(events).length,1);assert.equal(grainEventName(events[0]),'Liquidación de stock');
  const after=await count();await clear({id:op,parts:snapshot.slice().reverse()});assert.equal(await count(),after);
  await assert.rejects(clear({id:op,parts:snapshot,detail:'Otro motivo'}),/operacion/);
  await assert.rejects(clear(),/sin stock/);
  const later=await batch([{source_id:otherStore,harvest_id:h2,tonnes:1}],'sale',null,'2026-11-04');
  await assert.rejects(q('select void_cometa_grain_operation($1,$2)',[org,op]),/posteriores/);assert.equal(await amount(fixed),0);
  await q('select void_cometa_grain_operation($1,$2)',[org,later]);await q('select void_cometa_grain_operation($1,$2)',[org,op]);assert.equal(await amount(fixed),5);assert.equal(await amount(otherStore),8);
  await clear({id:op,parts:snapshot});assert.equal(await amount(fixed),5); // retry cannot resurrect a voided clearing
  const changed=await batch([{source_id:fixed,harvest_id:h1,tonnes:0.001}],'sale',null,'2026-11-05');
  const before=await count();await assert.rejects(clear({parts:snapshot,date:'2026-11-06'}),/stock cambio/);assert.equal(await count(),before);assert.equal(await amount(fixed),4.999);
  await q('select void_cometa_grain_operation($1,$2)',[org,changed]);
  for(const parts of [[],snapshot.slice(0,1),snapshot.map(row=>({...row,tonnes:row.tonnes+0.001})),[...snapshot,snapshot[0]]])await assert.rejects(clear({parts}),/stock cambio/);
  await assert.rejects(clear({parts:null}),/partidas/);await assert.rejects(clear({date:'2026-10-01'}),/fecha/);await assert.rejects(clear({detail:''}),/motivo/);
  await assert.rejects(clear({store:foreign}),/organizacion/);await assert.rejects(clear({organization:other}),/permisos/);
  await q('select void_cometa_grain_operation($1,$2)',[org,transfer]);assert.equal(await amount(bag),5);
  const bagOp=await clear({store:bag,date:'2026-11-06'});assert.equal(await amount(bag),0);assert.equal(await amount(otherStore),8);
  assert.equal(bagReferenceTonnes(bag,(await report()).events),5);
  await q('select void_cometa_grain_operation($1,$2)',[org,bagOp]);assert.equal(await amount(bag),5);
  assert.equal((await q('select count(*)::int as n from cometa_movements'))[0].n,0);
  assert.equal((await report()).harvests.reduce((sum,row)=>sum+Number(row.tonnes),0),13);
  await q("update organization_members set role='viewer' where organization_id=$1",[org]);await assert.rejects(clear({store:bag}),/permisos/);
  await db.exec('set role authenticated');await assert.rejects(clear({store:bag}),/permisos/);await assert.rejects(q('delete from cometa_grain_events'),/permission denied/);
 }finally{await db.close()}
});

