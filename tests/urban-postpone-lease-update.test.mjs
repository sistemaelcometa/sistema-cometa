import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import test from 'node:test';
import {randomUUID} from 'node:crypto';
import {PGlite} from '@electric-sql/pglite';
const read=path=>readFile(new URL('../'+path,import.meta.url),'utf8');
test('one-off December shift updates only Mauro Molinero and is repeatable and guarded',async()=>{
 const db=new PGlite(),org='98a857e1-dacc-4890-90e9-1f1ac8de9782',other=randomUUID(),building=randomUUID(),unit=randomUUID(),tenant=randomUUID(),lease=randomUUID(),secondLease=randomUUID();
 const q=async(sql,args=[])=>(await db.query(sql,args)).rows;
 try{
  const schema=await read('supabase/migrations/001_initial_rentals_schema.sql');
  await db.exec('create schema auth;create table auth.users(id uuid primary key);create function auth.uid() returns uuid language sql as $$select null::uuid;$$;');
  await db.exec(schema.match(/create type \w+ as enum \([\s\S]*?\);/g).join('\n'));await db.exec(schema.match(/create table \w+ \([\s\S]*?\r?\n\);/g).join('\n'));
  await q("insert into organizations(id,name,slug) values($1,'Org','org'),($2,'Otra','otra')",[org,other]);
  await q("insert into urban_buildings(id,organization_id,name) values($1,$2,'PELLEGRINI')",[building,org]);
  await q("insert into urban_units(id,organization_id,building_id,name,surface_m2,status) values($1,$2,$3,'DPTO 4',13.33,'rented')",[unit,org,building]);
  await q("insert into contacts(id,organization_id,first_name,last_name) values($1,$2,'MAURO','MOLINERO')",[tenant,org]);
  await q("insert into urban_leases(id,organization_id,unit_id,primary_tenant_contact_id,start_date,end_date,current_amount,currency,monthly_due_day,status,next_adjustment_date,adjustment_frequency_months) values($1,$2,$3,$4,'2026-03-15','2028-03-14',457000,'ARS',10,'active','2026-11-01',4),($5,$2,$3,$4,'2024-03-15','2026-03-14',400000,'ARS',10,'finalized','2026-03-01',6)",[lease,org,unit,tenant,secondLease]);
  const script=await read('supabase/manual/2026-11-05_pasar_actualizacion_mauro_molinero_a_diciembre.sql');
  const before=await q('select * from urban_leases where id=$1',[lease]),previous=await q('select * from urban_leases where id=$1',[secondLease]);
  await db.exec(script);await db.exec(script);
  const updated=(await q('select * from urban_leases where id=$1',[lease]))[0];
  assert.equal(updated.next_adjustment_date.toISOString().slice(0,10),'2026-12-01');assert.equal(updated.adjustment_frequency_months,4);
  assert.deepEqual({...updated,next_adjustment_date:before[0].next_adjustment_date,adjustment_frequency_months:before[0].adjustment_frequency_months},before[0]);
  assert.deepEqual(await q('select * from urban_leases where id=$1',[secondLease]),previous);
  assert.equal((await q('select count(*)::int as n from audit_logs'))[0].n,1);
  await q("update urban_leases set next_adjustment_date='2027-04-01' where id=$1",[lease]);
  await assert.rejects(db.exec(script),/fecha de actualizacion cambio/);await db.exec('rollback');
  assert.equal((await q('select next_adjustment_date::text as next_adjustment_date from urban_leases where id=$1',[lease]))[0].next_adjustment_date,'2027-04-01');
  await q("update urban_leases set next_adjustment_date='2026-11-01' where id=$1",[lease]);
  await q("update contacts set last_name='OTRO' where id=$1",[tenant]);
  await assert.rejects(db.exec(script),/unico contrato/);await db.exec('rollback');
  assert.equal((await q('select next_adjustment_date::text as next_adjustment_date from urban_leases where id=$1',[lease]))[0].next_adjustment_date,'2026-11-01');
 }finally{await db.close()}
});
