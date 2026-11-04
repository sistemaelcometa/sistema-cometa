import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {randomUUID} from 'node:crypto';
import test from 'node:test';
import {PGlite} from '@electric-sql/pglite';
const read=path=>readFile(new URL('../'+path,import.meta.url),'utf8');
function fn(source,name){const start=source.indexOf('create or replace function '+name+'(');return source.slice(start,source.indexOf('$$;',source.indexOf('as $$',start))+3)}

test('agricultural movements enforce roles, organization, cents and retries; reports keep currencies separate',async()=>{
 const db=new PGlite(),org=randomUUID(),other=randomUUID(),actor=randomUUID();
 const q=async(sql,args=[])=>(await db.query(sql,args)).rows;
 try{
  const schema=await read('supabase/migrations/001_initial_rentals_schema.sql');
  await db.exec("create role anon;create role authenticated;create schema auth;create table auth.users(id uuid primary key);create function auth.uid() returns uuid language sql stable as $$select nullif(current_setting('test.actor',true),'')::uuid;$$;grant usage on schema auth to authenticated;create schema storage;create table storage.objects(bucket_id text,name text);");
  await db.exec(schema.match(/create type \w+ as enum \([\s\S]*?\);/g).join('\n'));
  await db.exec(schema.match(/create table \w+ \([\s\S]*?\r?\n\);/g).join('\n'));
  for(const name of ['is_org_member','has_org_role'])await db.exec(fn(schema,name));
  await q("select set_config('test.actor',$1,false)",[actor]);
  await q('insert into auth.users values($1)',[actor]);
  await q("insert into profiles(id,email) values($1,'test@local')",[actor]);
  await q("insert into organizations(id,name,slug) values($1,'Campo','campo'),($2,'Otro','otro')",[org,other]);
  await q("insert into organization_members(organization_id,user_id,role,status) values($1,$2,'owner','active')",[org,actor]);
  const migration=await read('supabase/migrations/074_cometa_agricultural_movements.sql');await db.exec(migration);await db.exec(migration);
  await q('select ensure_cometa_categories($1)',[org]);
  const categories=await q('select * from cometa_categories where organization_id=$1',[org]);
  assert.equal(categories.length,9);assert.equal(categories.filter(c=>c.kind==='income').length,2);
  assert.ok(categories.find(c=>c.name==='Combustible').description.includes('ciudad'));
  const expense=categories.find(c=>c.name==='Insumos').id,income=categories.find(c=>c.kind==='income').id;
  const save=async({organization=org,kind='expense',category=expense,amount=1500.25,currency='ARS',operation=randomUUID(),path=null,name=null,date='2026-11-04'}={})=>(await q('select * from register_cometa_movement($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13)',[organization,kind,date,category,amount,currency,'Movimiento de prueba','Proveedor','A-0001','Observacion',path,name,operation]))[0];
  const report=async(extra=[]) => (await q('select get_cometa_report($1,$2,$3,$4,$5,$6,$7,$8,$9) as result',[org,...[null,null,null,null,null,null,20,0].map((value,index)=>extra[index]===undefined?value:extra[index])]))[0].result;
  const operation=randomUUID(),first=await save({operation});assert.equal((await save({operation})).id,first.id);
  await assert.rejects(save({operation,amount:1501}),/operacion/);
  for(const amount of [0,-1,0.001,1e12,'NaN'])await assert.rejects(save({amount}),/importe/);
  await assert.rejects(save({category:income}),/categoria/);
  await assert.rejects(save({organization:other}),/permisos/);
  await save({kind:'income',category:income,amount:2000.50});await save({amount:10.10,currency:'USD'});await save({kind:'income',category:income,amount:20,currency:'USD'});
  let data=await report();assert.equal(data.total,4);
  assert.equal(Number(data.totals.find(row=>row.currency==='ARS').income),2000.50);
  assert.equal(Number(data.totals.find(row=>row.currency==='ARS').expense),1500.25);
  assert.equal(Number(data.totals.find(row=>row.currency==='USD').expense),10.10);
  assert.equal(Number(data.expensesByCategory.find(row=>row.currency==='USD').amount),10.10);
  const page=await report([null,null,null,null,null,null,1,1]);assert.equal(page.rows.length,1);assert.equal(page.total,4);assert.equal(page.totals.length,2);
  assert.equal((await report(['2027-01-01'])).total,0);
  assert.equal((await report([null,null,'income'])).total,2);
  assert.equal((await report([null,null,null,null,'USD'])).total,2);
  assert.equal((await report([null,null,null,null,null,'no existe'])).total,0);
  const receiptOperation=randomUUID(),receiptPath='org/'+org+'/cometa/'+receiptOperation+'/receipt.pdf';
  await assert.rejects(save({operation:receiptOperation,path:receiptPath,name:'Factura.pdf'}),/comprobante/);
  await q("insert into storage.objects values('receipts',$1)",[receiptPath]);
  const attached=await save({operation:receiptOperation,path:receiptPath,name:'Factura.pdf'});assert.equal(attached.receipt_path,receiptPath);
  await assert.rejects(save({path:receiptPath,name:'Factura.pdf'}),/comprobante/);
  await q("update organization_members set role='viewer' where organization_id=$1",[org]);
  await assert.rejects(save(),/permisos/);await assert.rejects(q('select void_cometa_movement($1,$2)',[org,first.id]),/permisos/);
  await db.exec('set role authenticated');
  assert.equal((await q('select count(*)::int as n from cometa_movements'))[0].n,5);
  assert.equal((await q('select count(*)::int as n from cometa_categories where organization_id=$1',[other]))[0].n,0);
  await assert.rejects(q('delete from cometa_movements'),/permission denied/);
  await db.exec('reset role');
  await q("update organization_members set role='owner' where organization_id=$1",[org]);
  await q('select void_cometa_movement($1,$2)',[org,first.id]);await q('select void_cometa_movement($1,$2)',[org,first.id]);
  data=await report();assert.equal(data.total,4);
  assert.equal(Number(data.totals.find(row=>row.currency==='ARS').expense),1500.25); // only attached expense remains
  assert.equal((await q("select count(*)::int as n from audit_logs where action='cometa_movement_voided'"))[0].n,1);
  assert.equal((await q("select status from cometa_movements where id=$1",[first.id]))[0].status,'voided');
  for(const table of ['urban_charges','urban_payments','urban_expense_items','pde_reservations'])assert.equal((await q('select count(*)::int as n from '+table))[0].n,0);
 }finally{await db.close()}
});
