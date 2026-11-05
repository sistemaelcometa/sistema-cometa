import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {randomUUID} from 'node:crypto';
import test from 'node:test';
import {PGlite} from '@electric-sql/pglite';
const read=path=>readFile(new URL('../'+path,import.meta.url),'utf8');
function fn(source,name){const start=source.indexOf('create or replace function '+name+'(');return source.slice(start,source.indexOf('$$;',source.indexOf('as $$',start))+3)}

test('grain ledger balances split harvests, transfers and sales, preserving origins, permissions and corrections',async()=>{
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

  const migration=await read('supabase/migrations/078_cometa_harvest_and_grain.sql');await db.exec(migration);await db.exec(migration);
  let report=async(organization=org)=>(await q('select get_cometa_grain($1) as data',[organization]))[0].data;
  let data=await report();assert.equal(data.stores.length,7);assert.ok(data.stores.every(row=>row.capacity===null));assert.equal(data.harvests.length,0);
  const configure=async(kind,name,location='',capacity=null,id=null,organization=org)=>(await q('select configure_cometa_grain($1,$2,$3,$4,$5,$6) as id',[organization,kind,name,location,capacity,id]))[0].id;
  const field=await configure('field','Lote 1'),field2=await configure('field','Lote 2'),bag=await configure('bag','Bolsa 01','Casa'),silo=data.stores[0].id,foreign=(await q('select id from cometa_grain_stores where organization_id=$1 limit 1',[other]))[0].id;
  await configure('silo','Silo principal','Casa',200,silo);
  await db.exec(migration);assert.equal((await report()).stores.length,8); // renamed stores are not reseeded
  await assert.rejects(configure('silo','Ajeno','Casa',null,foreign),/organizacion/);
  for(const amount of [-1,0,'NaN',0.0001])await assert.rejects(configure('bag','Mala','Casa',amount),/capacidad/);
  const harvest=async({id=randomUUID(),lot=field,amount=100,parts=[{kind:'deposit',store_id:bag,tonnes:60},{kind:'deposit',store_id:silo,tonnes:25},{kind:'direct_sale',tonnes:15,recipient:'Comprador',reference:'Camion 1'}],organization=org}={})=>(await q('select register_cometa_harvest($1,$2,$3,$4,$5,$6,$7,$8) as id',[organization,id,'2026-11-01',lot,'2026/27','Soja',amount,JSON.stringify(parts)]))[0].id;
  const op=randomUUID(),origin=await harvest({id:op});assert.equal(await harvest({id:op}),origin);
  await assert.rejects(harvest({id:op,amount:101}),/operacion/);
  data=await report();assert.equal(data.harvests.length,1);assert.equal(data.events.length,3);assert.equal(data.balances.reduce((sum,row)=>sum+Number(row.tonnes),0),85);
  await assert.rejects(harvest({parts:[{kind:'deposit',store_id:bag,tonnes:99}]}),/reparto/);
  assert.equal((await report()).harvests.length,1); // rollback includes all attempted allocations
  for(const parts of [[{kind:'deposit',store_id:foreign,tonnes:100}],[{kind:'deposit',store_id:bag,tonnes:-100}],[{kind:'deposit',store_id:bag,tonnes:100.0001}]])await assert.rejects(harvest({parts}),/Destino|toneladas/);
  await assert.rejects(harvest({lot:randomUUID()}),/lote/);
  for(const amount of ['NaN',0,-2,0.0001])await assert.rejects(harvest({amount}),/toneladas/);
  const exit=async({id=randomUUID(),from=bag,to=null,kind='sale',amount=20,date='2026-11-02',harvestId=origin,organization=org}={})=>(await q('select register_cometa_grain_exit($1,$2,$3,$4,$5,$6,$7,$8,$9,$10) as id',[organization,id,harvestId,date,kind,from,to,amount,'Destino','Remito 2']))[0].id;
  const saleOp=randomUUID();await exit({id:saleOp});await exit({id:saleOp});
  await assert.rejects(exit({id:saleOp,amount:21}),/operacion/);
  await assert.rejects(exit({amount:40.001}),/saldo/);
  await assert.rejects(exit({amount:-1}),/toneladas/);
  await assert.rejects(exit({date:'2026-10-30'}),/fecha/);
  await assert.rejects(exit({kind:'transfer',to:bag,amount:1}),/destino/);
  await assert.rejects(exit({kind:'transfer',to:foreign,amount:1}),/destino/);
  await assert.rejects(exit({from:foreign,amount:1}),/Origen/);
  await assert.rejects(exit({organization:other}),/permisos/);
  const transferOp=randomUUID();await exit({id:transferOp,kind:'transfer',to:silo,amount:10,date:'2026-11-03'});
  data=await report();
  const balance=(harvestId,store)=>Number(data.balances.find(row=>row.harvest_id===harvestId&&row.store_id===store)?.tonnes||0);
  assert.equal(balance(origin,bag),30);assert.equal(balance(origin,silo),35);
  assert.equal(data.balances.reduce((sum,row)=>sum+Number(row.tonnes),0),65);
  // Two different lots in one silo retain separate origins, including kilogram precision.
  const second=await harvest({lot:field2,amount:0.125,parts:[{kind:'deposit',store_id:bag,tonnes:0.125}]});
  data=await report();assert.equal(balance(second,bag),0.125);assert.equal(balance(origin,bag),30);
  await assert.rejects(exit({harvestId:second,amount:0.126}),/saldo/);
  await exit({harvestId:second,amount:0.125});data=await report();assert.equal(balance(second,bag),0);
  await assert.rejects(q('select void_cometa_grain_operation($1,$2)',[org,origin]),/posteriores/);
  await assert.rejects(q('select void_cometa_grain_operation($1,$2)',[org,saleOp]),/posteriores/);
  await q('select void_cometa_grain_operation($1,$2)',[org,transferOp]);
  await q('select void_cometa_grain_operation($1,$2)',[org,transferOp]);data=await report();assert.equal(balance(origin,bag),40);assert.equal(balance(origin,silo),25);
  await q('select void_cometa_grain_operation($1,$2)',[org,saleOp]);
  await q('select void_cometa_grain_operation($1,$2)',[org,origin]);
  data=await report();assert.equal(data.harvests.find(row=>row.id===origin).voided,true);assert.equal(balance(origin,bag),0);assert.equal(balance(origin,silo),0);assert.equal(data.events.filter(row=>row.harvest_id===origin).length,5);
  assert.equal((await q('select count(*)::int as n from cometa_movements'))[0].n,0);
  await q("update organization_members set role='viewer' where organization_id=$1",[org]);
  await assert.rejects(configure('field','Prohibido'),/permisos/);await assert.rejects(harvest(),/permisos/);await assert.rejects(exit(),/permisos/);await assert.rejects(q('select void_cometa_grain_operation($1,$2)',[org,origin]),/permisos/);
  await assert.rejects(report(other),/permisos/);
  await db.exec('set role authenticated');
  assert.equal((await q('select count(*)::int as n from cometa_grain_stores where organization_id=$1',[other]))[0].n,0);
  await assert.rejects(q('delete from cometa_grain_events'),/permission denied/);
  assert.equal((await q('select count(*)::int as n from cometa_harvests'))[0].n,2);
 }finally{await db.close()}
});

