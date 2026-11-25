import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {randomUUID} from 'node:crypto';
import test from 'node:test';
import {PGlite} from '@electric-sql/pglite';
import {harvestYield,yieldLabel} from '../lib/cometa-grain.ts';
const read=path=>readFile(new URL('../'+path,import.meta.url),'utf8');
function fn(source,name){const start=source.indexOf('create or replace function '+name+'(');return source.slice(start,source.indexOf('$$;',source.indexOf('as $$',start))+3)}

test('field hectares snapshot harvest yields, preserve old history and quantities, and enforce organization and roles',async()=>{
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
  await db.exec(await read('supabase/migrations/079_cometa_harvest_seasons_and_fields.sql'));
  const store=(await q('select id from cometa_grain_stores where organization_id=$1 limit 1',[org]))[0].id;
  const oldField=(await q("select configure_cometa_grain($1,'field','Lote anterior') as id",[org]))[0].id;
  const parts=JSON.stringify([{kind:'deposit',store_id:store,tonnes:100}]);
  const harvest=async(lot,id=randomUUID())=>(await q('select register_cometa_harvest_with_season($1,$2,$3,$4,$5,$6,$7,$8,$9) as id',[org,id,'2026-11-16',lot,'2026/27','Soja',100,parts,'gruesa']))[0].id;
  const oldHarvest=await harvest(oldField);
  const migration=await read('supabase/migrations/080_cometa_field_hectares_and_yield.sql');await db.exec(migration);await db.exec(migration);
  const report=async()=>(await q('select get_cometa_grain($1) as data',[org]))[0].data;
  let data=await report();assert.equal(data.harvests[0].field_hectares,null);assert.equal(data.fields[0].hectares,null);
  const save=async(name,area,id=null,organization=org)=>(await q('select save_cometa_field($1,$2,$3,$4) as id',[organization,name,area,id]))[0].id;
  const field=await save('Lote 25',25),unknown=await save('Sin superficie',null);
  const first=await harvest(field),missing=await harvest(unknown);
  data=await report();const snapshot=id=>data.harvests.find(row=>row.id===id).field_hectares;
  assert.equal(Number(snapshot(first)),25);assert.equal(snapshot(missing),null);assert.equal(harvestYield(100,snapshot(first)),40);assert.equal(yieldLabel(100,snapshot(first)),'40,0 qq/ha');assert.equal(yieldLabel(100,snapshot(missing)),'—');
  await save('Lote 25',40,field);assert.equal(await harvest(field,first),first);
  const second=await harvest(field);data=await report();assert.equal(Number(snapshot(first)),25);assert.equal(Number(snapshot(second)),40);assert.equal(harvestYield(100,snapshot(second)),25);assert.equal(yieldLabel(100,snapshot(first)),'40,0 qq/ha');
  await save('Lote anterior',50,oldField);data=await report();assert.equal(snapshot(oldHarvest),null); // no invented historical acreage
  await save('Lote 25',null,field);const noArea=await harvest(field);data=await report();assert.equal(snapshot(noArea),null);assert.equal(Number(snapshot(first)),25);
  await save('Lote 25',12.5,field);const fractional=await harvest(field);data=await report();assert.equal(Number(snapshot(fractional)),12.5);assert.equal(100/Number(snapshot(fractional)),8);
  // Older configuration clients preserve the existing area.
  await q("select configure_cometa_grain($1,'field','Lote renombrado','',null,$2)",[org,field]);assert.equal(Number((await report()).fields.find(row=>row.id===field).hectares),12.5);
  const count=(await q('select count(*)::int as n from cometa_fields'))[0].n;
  for(const invalid of [0,-1,'NaN','Infinity','-Infinity',1e9,1.0001])await assert.rejects(save('Invalido',invalid),/hectareas/);
  assert.equal((await q('select count(*)::int as n from cometa_fields'))[0].n,count);
  await assert.rejects(save('Otro',2,null,other),/permisos/);
  const foreign=randomUUID();await q('insert into cometa_fields(id,organization_id,name) values($1,$2,$3)',[foreign,other,'Ajeno']);await assert.rejects(save('Ajeno modificado',2,foreign),/organizacion/);
  await q('select delete_cometa_field($1,$2)',[org,unknown]);await assert.rejects(save('Eliminar editado',2,unknown),/eliminado/);
  data=await report();assert.equal(data.balances.reduce((sum,row)=>sum+Number(row.tonnes),0),600);
  assert.equal((await q('select count(*)::int as n from cometa_movements'))[0].n,0);
  await q("update organization_members set role='viewer' where organization_id=$1",[org]);
  await assert.rejects(save('No permitido',2),/permisos/);
  await db.exec('set role authenticated');assert.equal((await q('select count(*)::int as n from cometa_fields where organization_id=$1',[other]))[0].n,0);
  await assert.rejects(q('update cometa_fields set hectares=1'),/permission denied/);
 }finally{await db.close()}
});

