import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {randomUUID} from 'node:crypto';
import test from 'node:test';
import {PGlite} from '@electric-sql/pglite';
import {groupGrainEvents} from '../lib/cometa-grain.ts';
const read=path=>readFile(new URL('../'+path,import.meta.url),'utf8');
function fn(source,name){const start=source.indexOf('create or replace function '+name+'(');return source.slice(start,source.indexOf('$$;',source.indexOf('as $$',start))+3)}

test('history groups one truck across origins while keeping original harvest deposits separate',()=>{
 const events=[{id:'a',operation_id:'truck',tonnes:10,request:{batch_exit:true}},{id:'b',operation_id:'truck',tonnes:20,request:{batch_exit:true}},{id:'c',operation_id:'harvest',tonnes:40,request:null},{id:'d',operation_id:'harvest',tonnes:50,request:null}];
 const groups=groupGrainEvents(events);assert.equal(groups.length,3);assert.equal(groups[0].events.length,2);assert.equal(groups[0].events.reduce((sum,event)=>sum+event.tonnes,0),30);assert.equal(groups[1].events.length,1);assert.equal(groups[2].events.length,1);
});

test('multi-source grain exits are atomic, retry-safe and reversible across every origin, with no cash writes',async()=>{
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
  const stores=await q('select id from cometa_grain_stores where organization_id=$1 order by location,name',[org]);const a=stores[0].id,b=stores[1].id,dest=stores[2].id,foreign=(await q('select id from cometa_grain_stores where organization_id=$1 limit 1',[other]))[0].id;
  const field=(await q("select save_cometa_field($1,'Lote',25) as id",[org]))[0].id;
  const harvest=async(store,amount)=>(await q('select register_cometa_harvest_with_season($1,$2,$3,$4,$5,$6,$7,$8,$9) as id',[org,randomUUID(),'2026-11-01',field,'2026/27','Soja',amount,JSON.stringify([{kind:'deposit',store_id:store,tonnes:amount}]),'gruesa']))[0].id;
  const h1=await harvest(a,50),h2=await harvest(b,60);
  const parts=[{source_id:a,harvest_id:h1,tonnes:10},{source_id:b,harvest_id:h2,tonnes:20}];
  const batch=async({id=randomUUID(),sources=parts,date='2026-11-02',kind='sale',to=null,detail='Entrega a proveedor',reference='Camion 30 t',organization=org}={})=>(await q('select register_cometa_grain_batch($1,$2,$3,$4,$5,$6,$7,$8) as id',[organization,id,date,kind,JSON.stringify(sources),to,detail,reference]))[0].id;
  const report=async()=>(await q('select get_cometa_grain($1) as data',[org]))[0].data;
  const balance=async(origin,store)=>Number((await report()).balances.find(row=>row.harvest_id===origin&&row.store_id===store)?.tonnes||0);
  const count=async()=>(await q('select count(*)::int as n from cometa_grain_events'))[0].n;
  const op=randomUUID();assert.equal(await batch({id:op}),op);await batch({id:op});assert.equal(await count(),4);assert.equal(await balance(h1,a),40);assert.equal(await balance(h2,b),40);
  assert.equal((await report()).events.filter(e=>e.operation_id===op).reduce((sum,e)=>sum+Number(e.tonnes),0),30);
  assert.ok((await report()).events.filter(e=>e.operation_id===op).every(e=>e.request.batch_exit&&e.recipient==='Entrega a proveedor'));
  await assert.rejects(batch({id:op,detail:'Otro'}),/operacion/);
  // A later operation on the SECOND origin must prevent partial cancellation of both.
  const later=await batch({sources:[{source_id:b,harvest_id:h2,tonnes:1}],date:'2026-11-03'});
  await assert.rejects(q('select void_cometa_grain_operation($1,$2)',[org,op]),/posteriores/);assert.equal(await balance(h1,a),40);assert.equal(await balance(h2,b),39);
  await q('select void_cometa_grain_operation($1,$2)',[org,later]);await q('select void_cometa_grain_operation($1,$2)',[org,op]);await q('select void_cometa_grain_operation($1,$2)',[org,op]);assert.equal(await balance(h1,a),50);assert.equal(await balance(h2,b),60);
  await batch({id:op});assert.equal(await balance(h1,a),50); // a retry cannot resurrect a voided operation
  const before=await count();
  for(const sources of [
    [{source_id:a,harvest_id:h1,tonnes:5},{source_id:b,harvest_id:h2,tonnes:61}],
    [{source_id:a,harvest_id:h1,tonnes:30},{source_id:a,harvest_id:h1,tonnes:30}],
    [{source_id:a,harvest_id:h1,tonnes:5},{source_id:foreign,harvest_id:h2,tonnes:1}],
    [{source_id:a,harvest_id:h1,tonnes:5},{source_id:b,harvest_id:h2,tonnes:0.0001}]
  ]){await assert.rejects(batch({sources}),/saldo|invalido|decimales/);assert.equal(await count(),before);assert.equal(await balance(h1,a),50);assert.equal(await balance(h2,b),60)}
  for(const sources of [null,[],Array.from({length:101},()=>parts[0])])await assert.rejects(batch({sources}),/origen/);
  for(const amount of [0,-1,'NaN','Infinity'])await assert.rejects(batch({sources:[{...parts[0],tonnes:amount}]}),/toneladas/);
  await assert.rejects(batch({date:'2026-10-01'}),/fecha/);await assert.rejects(batch({detail:''}),/detalle/);
  await assert.rejects(batch({kind:'transfer',to:a}),/invalido/);await assert.rejects(batch({kind:'transfer',to:foreign}),/invalido/);await assert.rejects(batch({to:dest}),/invalido/);assert.equal(await count(),before);
  const transfer=await batch({kind:'transfer',to:dest,date:'2026-11-04',detail:'Traslado a planta'});assert.equal(await balance(h1,dest),10);assert.equal(await balance(h2,dest),20);
  assert.equal((await report()).balances.reduce((sum,row)=>sum+Number(row.tonnes),0),110);
  const afterTransfer=await batch({sources:[{source_id:dest,harvest_id:h2,tonnes:5}],date:'2026-11-05'});
  await assert.rejects(q('select void_cometa_grain_operation($1,$2)',[org,transfer]),/posteriores/);
  await q('select void_cometa_grain_operation($1,$2)',[org,afterTransfer]);await q('select void_cometa_grain_operation($1,$2)',[org,transfer]);assert.equal(await balance(h1,dest),0);assert.equal(await balance(h2,dest),0);assert.equal(await balance(h1,a),50);
  // Legacy harvest cancellation remains supported.
  await q('select void_cometa_grain_operation($1,$2)',[org,h1]);assert.equal(await balance(h1,a),0);
  await assert.rejects(batch({organization:other}),/permisos/);
  await q("update organization_members set role='viewer' where organization_id=$1",[org]);await assert.rejects(batch(),/permisos/);await assert.rejects(q('select void_cometa_grain_operation($1,$2)',[org,op]),/permisos/);
  assert.equal((await q('select count(*)::int as n from cometa_movements'))[0].n,0);
  await db.exec('set role authenticated');await assert.rejects(q('delete from cometa_grain_events'),/permission denied/);
 }finally{await db.close()}
});

