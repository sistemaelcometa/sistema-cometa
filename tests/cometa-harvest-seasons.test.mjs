import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {randomUUID} from 'node:crypto';
import test from 'node:test';
import {PGlite} from '@electric-sql/pglite';
const read=path=>readFile(new URL('../'+path,import.meta.url),'utf8');
function fn(source,name){const start=source.indexOf('create or replace function '+name+'(');return source.slice(start,source.indexOf('$$;',source.indexOf('as $$',start))+3)}

test('harvest seasons and field deletion preserve quantities and history, enforce roles and support retries',async()=>{
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


  await db.exec(await read('supabase/migrations/078_cometa_harvest_and_grain.sql'));
  const configure=async(name)=>(await q("select configure_cometa_grain($1,'field',$2) as id",[org,name]))[0].id;
  const field=await configure('Lote historico'),unused=await configure('Lote sin cosechas'),otherField=randomUUID();
  await q('insert into cometa_fields(id,organization_id,name) values($1,$2,$3)',[otherField,other,'Ajeno']);
  const store=(await q('select id from cometa_grain_stores where organization_id=$1 limit 1',[org]))[0].id;
  const parts=JSON.stringify([{kind:'deposit',store_id:store,tonnes:10}]),legacyId=randomUUID();
  const legacy=async(id,lot=field)=>q('select register_cometa_harvest($1,$2,$3,$4,$5,$6,$7,$8)',[org,id,'2026-11-01',lot,'2026/27','Soja',10,parts]);
  await legacy(legacyId);
  const before=(await q('select get_cometa_grain($1) as data',[org]))[0].data;
  const migration=await read('supabase/migrations/079_cometa_harvest_seasons_and_fields.sql');await db.exec(migration);await db.exec(migration);
  const report=async()=>(await q('select get_cometa_grain($1) as data',[org]))[0].data;
  assert.equal((await report()).harvests[0].season,null);
  assert.deepEqual((await report()).balances,before.balances);
  const save=async({id=randomUUID(),lot=field,season='gruesa',amount=10,organization=org}={})=>(await q('select register_cometa_harvest_with_season($1,$2,$3,$4,$5,$6,$7,$8,$9) as id',[organization,id,'2026-11-09',lot,'2026/27','Soja',amount,parts,season]))[0].id;
  const fina=randomUUID(),gruesa=randomUUID();await save({id:fina,season:'fina'});await save({id:gruesa});
  assert.equal(await save({id:gruesa}),gruesa);
  await assert.rejects(save({id:gruesa,season:'fina'}),/operacion/);
  await assert.rejects(save({id:gruesa,amount:9}),/operacion/);
  for(const season of ['',null,'otra'])await assert.rejects(save({season}),/fina o gruesa/);
  await assert.rejects(save({amount:11}),/reparto/);
  let data=await report();assert.equal(data.harvests.length,3);assert.equal(data.events.length,3);
  assert.equal(Number(data.balances.reduce((sum,row)=>sum+Number(row.tonnes),0)),30);
  assert.equal(data.harvests.find(row=>row.id===fina).season,'fina');assert.equal(data.harvests.find(row=>row.id===gruesa).season,'gruesa');
  await assert.rejects(q('select delete_cometa_field($1,$2)',[org,otherField]),/organizacion/);
  await assert.rejects(q('select delete_cometa_field($1,$2)',[other,field]),/permisos/);
  await q('select delete_cometa_field($1,$2)',[org,field]);await q('select delete_cometa_field($1,$2)',[org,field]);
  await assert.rejects(save(),/lote fue eliminado/);await assert.rejects(legacy(randomUUID()),/lote fue eliminado/);
  assert.equal(await save({id:gruesa}),gruesa); // network retry remains safe after removal
  data=await report();assert.equal(data.harvests.length,3);assert.ok(data.harvests.every(row=>row.field_name==='Lote historico'));assert.equal(data.fields.filter(row=>!row.deleted_at).length,1);
  assert.equal(data.balances.reduce((sum,row)=>sum+Number(row.tonnes),0),30);
  const replacement=await configure('Lote historico');assert.notEqual(replacement,field);await save({lot:replacement});
  await q('select delete_cometa_field($1,$2)',[org,unused]);data=await report();assert.equal(data.fields.filter(row=>!row.deleted_at).length,1);
  await q("update organization_members set role='viewer' where organization_id=$1",[org]);
  await assert.rejects(save({lot:replacement}),/permisos/);await assert.rejects(q('select delete_cometa_field($1,$2)',[org,replacement]),/permisos/);
  await db.exec('set role authenticated');
  assert.equal((await q('select count(*)::int as n from cometa_fields where organization_id=$1',[other]))[0].n,0);
  await assert.rejects(q('delete from cometa_fields'),/permission denied/);
  await assert.rejects(q('update cometa_harvests set season=null'),/permission denied/);
 }finally{await db.close()}
});

