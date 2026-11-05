import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {randomUUID} from 'node:crypto';
import test from 'node:test';
import {PGlite} from '@electric-sql/pglite';
const read=path=>readFile(new URL('../'+path,import.meta.url),'utf8');
function fn(source,name){const start=source.indexOf('create or replace function '+name+'(');return source.slice(start,source.indexOf('$$;',source.indexOf('as $$',start))+3)}

test('suppliers isolate organizations, reject duplicates, enforce roles and preserve historical movements',async()=>{
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
  const migration=await read('supabase/migrations/077_cometa_suppliers.sql');await db.exec(migration);await db.exec(migration);
  const save=async(name,id=null,organization=org)=>(await q('select * from save_cometa_supplier($1,$2,$3,$4,$5)',[organization,name,'30-12345678-9','contacto',id]))[0];
  const first=await save('  Agro   Centro  ');assert.equal(first.name,'Agro Centro');
  await assert.rejects(save('agro centro'),/Ya existe/);
  for(const invalid of ['',null,'a'.repeat(201)])await assert.rejects(save(invalid),/nombre/);
  await assert.rejects(save('Fuera',null,other),/permisos/);
  const foreign=randomUUID();await q('insert into cometa_suppliers(id,organization_id,name) values($1,$2,$3)',[foreign,other,'Otro proveedor']);
  await assert.rejects(save('Cambio ajeno',foreign),/disponible/);
  await assert.rejects(q('select archive_cometa_supplier($1,$2)',[org,foreign]),/disponible/);
  const category=(await q("select id from cometa_categories where organization_id=$1 and name='Insumos'",[org]))[0].id;
  const payment=(await q("select * from register_cometa_movement($1,'expense','2026-11-05',$2,123.45,'ARS','Semillas',$3,null,null,null,null,$4)",[org,category,first.name,randomUUID()]))[0];
  await save('Nombre nuevo',first.id);
  await q('select archive_cometa_supplier($1,$2)',[org,first.id]);await q('select archive_cometa_supplier($1,$2)',[org,first.id]);
  const historical=(await q('select * from cometa_movements where id=$1',[payment.id]))[0];
  assert.equal(historical.counterparty,'Agro Centro');assert.equal(Number(historical.amount),123.45);assert.equal(historical.status,'valid');
  assert.equal((await q('select count(*)::int as n from cometa_suppliers where organization_id=$1 and archived_at is null',[org]))[0].n,0);
  await assert.rejects(save('Cambio archivado',first.id),/disponible/);
  await save('Agro Centro');
  await q("update organization_members set role='viewer' where organization_id=$1",[org]);
  await assert.rejects(save('No permitido'),/permisos/);
  await assert.rejects(q('select archive_cometa_supplier($1,$2)',[org,first.id]),/permisos/);
  await db.exec('set role authenticated');
  assert.equal((await q('select count(*)::int as n from cometa_suppliers where organization_id=$1',[other]))[0].n,0);
  assert.equal((await q('select count(*)::int as n from cometa_suppliers'))[0].n,2);
  await assert.rejects(q("insert into cometa_suppliers(organization_id,name) values($1,'Directo')",[org]),/permission denied/);
  await assert.rejects(q('delete from cometa_suppliers'),/permission denied/);
 }finally{await db.close()}
});
