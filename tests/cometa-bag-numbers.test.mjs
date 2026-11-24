import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {randomUUID} from 'node:crypto';
import test from 'node:test';
import {PGlite} from '@electric-sql/pglite';
import {bagNumberLabel,bagReferenceTonnes,storeLabel} from '../lib/cometa-grain.ts';
const read=path=>readFile(new URL('../'+path,import.meta.url),'utf8');
function fn(source,name){const start=source.indexOf('create or replace function '+name+'(');return source.slice(start,source.indexOf('$$;',source.indexOf('as $$',start))+3)}

test('bag numbers preserve existing identities, allow repeated names, isolate stock and survive retries and edits',async()=>{
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
  const configure=async(kind,name,location='Casa',capacity=null,id=null)=>(await q('select configure_cometa_grain($1,$2,$3,$4,$5,$6) as id',[org,kind,name,location,capacity,id]))[0].id;
  const legacy=await configure('bag','Bolsa 1');
  const field=(await q("select save_cometa_field($1,'Lote',25) as id",[org]))[0].id;
  const harvest=async(store,tonnes)=>(await q('select register_cometa_harvest_with_season($1,$2,$3,$4,$5,$6,$7,$8,$9) as id',[org,randomUUID(),'2026-11-01',field,'2026/27','Maíz',tonnes,JSON.stringify([{kind:'deposit',store_id:store,tonnes}]),'gruesa']))[0].id;
  const h1=await harvest(legacy,200);
  const bagMigration=await read('supabase/migrations/084_cometa_bag_numbers.sql');await db.exec(bagMigration);await db.exec(bagMigration);
  const report=async()=>(await q('select get_cometa_grain($1) as data',[org]))[0].data;
  const store=async(id)=>(await report()).stores.find(row=>row.id===id);
  assert.equal((await store(legacy)).bag_number,1);assert.equal(bagNumberLabel(await store(legacy)),'SB-0001');
  const save=async({id=randomUUID(),target=null,kind='bag',name='Bolsa 1',location='Casa',capacity=null,organization=org}={})=>(await q('select save_cometa_grain_store($1,$2,$3,$4,$5,$6,$7) as data',[organization,kind,name,location,capacity,target,id]))[0].data;
  const createId=randomUUID(),second=await save({id:createId});assert.equal(second.id,createId);assert.equal(second.bag_number,2);assert.notEqual(second.id,legacy);
  assert.equal((await save({id:createId})).bag_number,2);
  await assert.rejects(save({id:createId,name:'Otro'}),/operacion/);
  const third=await save();assert.equal(third.bag_number,3);
  const legacyApi=await configure('bag','Bolsa 1');assert.equal((await store(legacyApi)).bag_number,4);
  await db.exec(bagMigration);assert.equal((await store(second.id)).bag_number,2);
  assert.equal((await save({target:second.id,name:'Bolsa renombrada',location:'Freyre'})).bag_number,2);
  await assert.rejects(save({target:second.id,kind:'silo'}),/tipo y numero/);
  await assert.rejects(configure('silo','Convertida','Casa',null,legacy),/tipo y numero/);
  await assert.rejects(q('update cometa_grain_stores set bag_number=99 where id=$1',[second.id]),/numero/);
  const fixed=await save({kind:'silo',name:'Silo nuevo'});assert.equal(fixed.bag_number,null);
  await assert.rejects(save({kind:'silo',name:'Silo nuevo'}),/silo fijo/);
  const sameNameBag=await save({name:'Silo nuevo'});assert.equal(sameNameBag.bag_number,5);
  const h2=await harvest(third.id,50),data=await report();
  const balance=(data,id)=>data.balances.filter(row=>row.store_id===id).reduce((sum,row)=>sum+Number(row.tonnes),0);
  assert.equal(balance(data,legacy),200);assert.equal(balance(data,third.id),50);
  assert.equal(bagReferenceTonnes(legacy,data.events),200);assert.equal(bagReferenceTonnes(third.id,data.events),50);
  assert.notEqual(storeLabel(await store(legacy)),storeLabel(await store(third.id)));
  const clearId=randomUUID();await q('select clear_cometa_grain_store($1,$2,$3,$4,$5,$6)',[org,clearId,legacy,'2026-11-02',JSON.stringify([{harvest_id:h1,tonnes:200}]),'Fin de bolsa']);
  assert.equal(balance(await report(),legacy),0);assert.equal(balance(await report(),third.id),50);
  assert.equal((await store(legacy)).bag_number,1);assert.equal((await save()).bag_number,6);
  await q('select void_cometa_grain_operation($1,$2)',[org,clearId]);assert.equal(balance(await report(),legacy),200);
  const foreign=randomUUID();await q("insert into cometa_grain_stores(id,organization_id,location,name,kind) values($1,$2,'Casa','Bolsa 1','bag')",[foreign,other]);
  assert.equal(Number((await q('select bag_number from cometa_grain_stores where id=$1',[foreign]))[0].bag_number),1);
  await assert.rejects(save({target:foreign}),/organizacion/);await assert.rejects(save({organization:other}),/permisos/);
  for(const kind of ['invalid',null])await assert.rejects(save({kind}),/tipo/);
  await assert.rejects(save({capacity:-1}),/capacidad/);
  assert.equal((await q('select count(*)::int as n from cometa_movements'))[0].n,0);
  assert.ok((await report()).events.some(row=>row.harvest_id===h1&&row.destination_id===legacy));
  assert.ok((await report()).events.some(row=>row.harvest_id===h2&&row.destination_id===third.id));
  await q("update organization_members set role='viewer' where organization_id=$1",[org]);await assert.rejects(save(),/permisos/);
  await db.exec('set role authenticated');await assert.rejects(q('select * from cometa_bag_counters'),/permission denied/);
  await assert.rejects(q('update cometa_grain_stores set bag_number=123 where id=$1',[legacy]),/permission denied/);
  assert.equal((await q('select count(*)::int as n from cometa_grain_stores where organization_id=$1',[other]))[0].n,0);
 }finally{await db.close()}
});

