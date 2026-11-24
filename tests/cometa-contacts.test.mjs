import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {randomUUID} from 'node:crypto';
import test from 'node:test';
import {PGlite} from '@electric-sql/pglite';
import {contactsForMovement} from '../lib/cometa-contacts.ts';
const read=path=>readFile(new URL('../'+path,import.meta.url),'utf8');
function fn(source,name){const start=source.indexOf('create or replace function '+name+'(');return source.slice(start,source.indexOf('$$;',source.indexOf('as $$',start))+3)}

test('cash suggestions share dual-role contacts and distinguish buyers from suppliers',()=>{
 const contacts=[{id:'s',party_role:'supplier'},{id:'b',party_role:'buyer'},{id:'both',party_role:'both'}];
 assert.deepEqual(contactsForMovement(contacts,'expense').map(row=>row.id),['s','both']);
 assert.deepEqual(contactsForMovement(contacts,'income').map(row=>row.id),['b','both']);
 assert.equal(contacts.length,3);
});

test('contacts migrate existing suppliers, share one identity, enforce roles and preserve historical cash',async()=>{
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
  await db.exec(await read('supabase/migrations/077_cometa_suppliers.sql'));
  const legacy=(await q("select * from save_cometa_supplier($1,'Deliar','30-123','555')",[org]))[0];
  const category=(await q("select id from cometa_categories where organization_id=$1 and name='Insumos'",[org]))[0].id;
  const movement=(await q("select * from register_cometa_movement($1,'expense','2026-11-05',$2,123.45,'ARS','Semillas','Deliar',null,null,null,null,$3)",[org,category,randomUUID()]))[0];
  const migration=await read('supabase/migrations/082_cometa_contacts.sql');await db.exec(migration);await db.exec(migration);
  const migrated=(await q('select * from cometa_suppliers where id=$1',[legacy.id]))[0];
  assert.equal(migrated.party_role,'supplier');assert.equal(migrated.name,legacy.name);assert.equal(migrated.tax_id,legacy.tax_id);
  const save=async({name='Deliar',role='both',id=null,organization=org,tax='',details=''}={})=>(await q('select * from save_cometa_contact($1,$2,$3,$4,$5,$6)',[organization,name,tax,details,role,id]))[0];
  const both=await save({id:legacy.id});assert.equal(both.id,legacy.id);assert.equal(both.party_role,'both');
  await db.exec(migration);assert.equal((await q('select party_role from cometa_suppliers where id=$1',[both.id]))[0].party_role,'both');
  await assert.rejects(save({name:'  DELIAR  ',role:'buyer'}),/Ya existe un contacto/);
  const buyer=await save({name:'  Acopio   Centro ',role:'buyer'});assert.equal(buyer.name,'Acopio Centro');
  await assert.rejects(save({name:'acopio centro',role:'supplier'}),/Ya existe/);
  for(const role of ['bad','',null])await assert.rejects(q('select save_cometa_contact($1,$2,$3,$4,$5)',[org,'Invalido','','',role]),/proveedor, comprador/);
  for(const name of ['',null,'a'.repeat(201)])await assert.rejects(save({name}),/nombre/);
  await assert.rejects(save({tax:'1'.repeat(31)}),/CUIT/);await assert.rejects(save({details:'a'.repeat(201)}),/contacto/);
  const foreign=randomUUID();await q("insert into cometa_suppliers(id,organization_id,name,party_role) values($1,$2,'Ajeno','buyer')",[foreign,other]);
  await assert.rejects(save({organization:other}),/permisos/);await assert.rejects(save({id:foreign}),/disponible/);
  // Old clients remain compatible and cannot silently reset a contact's role.
  await q("select save_cometa_supplier($1,'Deliar actualizado','','',$2)",[org,both.id]);
  assert.equal((await q('select party_role from cometa_suppliers where id=$1',[both.id]))[0].party_role,'both');
  await q('select archive_cometa_supplier($1,$2)',[org,both.id]);
  await assert.rejects(save({id:both.id}),/disponible/);
  const historical=(await q('select * from cometa_movements where id=$1',[movement.id]))[0];
  assert.equal(historical.counterparty,'Deliar');assert.equal(Number(historical.amount),123.45);assert.equal(historical.status,'valid');
  assert.equal((await q('select count(*)::int as n from cometa_movements'))[0].n,1);
  await q("update organization_members set role='viewer' where organization_id=$1",[org]);
  await assert.rejects(save({name:'No permitido'}),/permisos/);
  await db.exec('set role authenticated');
  assert.equal((await q('select count(*)::int as n from cometa_suppliers where organization_id=$1',[other]))[0].n,0);
  await assert.rejects(q("update cometa_suppliers set party_role='both' where id=$1",[buyer.id]),/permission denied/);
  await assert.rejects(q('select save_cometa_contact($1,$2)',[org,'Viewer']),/permisos/);
 }finally{await db.close()}
});
