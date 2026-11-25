import assert from 'node:assert/strict';
import {readFile} from 'node:fs/promises';
import {randomUUID} from 'node:crypto';
import test from 'node:test';
import {PGlite} from '@electric-sql/pglite';
import {argentinaDay} from '../lib/argentina-day.ts';
const read=path=>readFile(new URL('../'+path,import.meta.url),'utf8');
function fn(source,name){const start=source.indexOf('create or replace function '+name+'(');return source.slice(start,source.indexOf('$$;',source.indexOf('as $$',start))+3)}

test('monthly reminder persists snooze and paid status, observes Argentina days and isolates organizations and roles',async()=>{
 const db=new PGlite(),org=randomUUID(),other=randomUUID(),actor=randomUUID(),second=randomUUID();
 const q=async(sql,args=[])=>(await db.query(sql,args)).rows;
 try{
  const schema=await read('supabase/migrations/001_initial_rentals_schema.sql');
  await db.exec("create role anon;create role authenticated;create schema auth;create table auth.users(id uuid primary key);create function auth.uid() returns uuid language sql stable as $$select nullif(current_setting('test.actor',true),'')::uuid;$$;grant usage on schema auth to authenticated;");
  await db.exec(schema.match(/create type \w+ as enum \([\s\S]*?\);/g).join('\n'));
  await db.exec(schema.match(/create table \w+ \([\s\S]*?\r?\n\);/g).join('\n'));
  for(const name of ['is_org_member','has_org_role'])await db.exec(fn(schema,name));
  await q("select set_config('test.actor',$1,false)",[actor]);
  for(const id of [actor,second]){await q('insert into auth.users values($1)',[id]);await q("insert into profiles(id,email) values($1,$2)",[id,id+'@local'])}
  await q("insert into organizations(id,name,slug) values($1,'Campo','campo'),($2,'Otro','otro')",[org,other]);
  await q("insert into organization_members(organization_id,user_id,role,status) values($1,$2,'owner','active'),($1,$3,'editor','active')",[org,actor,second]);
  const migration=await read('supabase/migrations/087_monthly_payment_reminder.sql');await db.exec(migration);await db.exec(migration);
  await db.exec("set timezone='Pacific/Auckland'");assert.equal((await q("select to_char(monthly_reminder_argentina_today(),'YYYY-MM-DD') as day"))[0].day,argentinaDay());
  const installClock=()=>db.exec("create or replace function monthly_reminder_argentina_today() returns date language sql stable set search_path=public as $$select current_setting('test.today')::date;$$;");
  await installClock();
  const day=async(value)=>q("select set_config('test.today',$1,false)",[value]);
  const get=async(organization=org)=>(await q('select get_monthly_payment_reminder($1) as data',[organization]))[0].data;
  const act=async(action,period='2026-11-01',organization=org)=>(await q('select update_monthly_payment_reminder($1,$2,$3) as data',[organization,period,action]))[0].data;
  const audits=async()=>(await q('select count(*)::int as n from audit_logs'))[0].n;
  await day('2026-11-04');assert.equal((await get()).visible,false);await assert.rejects(act('paid'),/dia 5/);
  await day('2026-11-05');assert.equal((await get()).visible,true);assert.equal((await get()).title,'Pagar Santiago');
  let saved=await act('snooze');assert.equal(saved.visible,false);assert.equal(saved.snoozed_until,'2026-11-06');
  const once=await audits();await act('snooze');assert.equal(await audits(),once);assert.equal((await get()).visible,false);
  await q("select set_config('test.actor',$1,false)",[second]);assert.equal((await get()).visible,false);await q("select set_config('test.actor',$1,false)",[actor]);
  await day('2026-11-06');assert.equal((await get()).visible,true);saved=await act('paid');assert.equal(saved.visible,false);assert.ok(saved.paid_at);
  const paidAudit=await audits();await act('paid');await act('snooze');assert.equal(await audits(),paidAudit);assert.equal((await get()).visible,false);
  await day('2026-11-30');assert.equal((await get()).visible,false);
  await db.exec(migration);await installClock();assert.equal((await get()).visible,false);
  await day('2026-12-01');assert.equal((await get()).visible,false);assert.equal((await get()).paid_at,null);
  await day('2026-12-05');assert.equal((await get()).visible,true);await assert.rejects(act('paid','2026-11-01'),/mes del recordatorio/);
  await assert.rejects(act('bad','2026-12-01'),/Elegi/);await assert.rejects(act(null,'2026-12-01'),/Elegi/);
  await day('2026-12-31');saved=await act('snooze','2026-12-01');assert.equal(saved.snoozed_until,'2027-01-01');
  await day('2027-01-01');assert.equal((await get()).visible,false);await day('2027-01-05');assert.equal((await get()).visible,true);
  await day('2028-02-28');assert.equal((await act('snooze','2028-02-01')).snoozed_until,'2028-02-29');
  await day('2028-02-29');assert.equal((await get()).visible,true);assert.equal((await act('snooze','2028-02-01')).snoozed_until,'2028-03-01');
  await assert.rejects(get(other),/permisos/);await assert.rejects(act('paid','2028-02-01',other),/permisos/);
  await q("update organization_members set role='viewer' where user_id=$1",[actor]);assert.equal((await get()).visible,false);await assert.rejects(act('paid','2028-02-01'),/permisos/);
  assert.equal((await q('select count(*)::int as n from urban_payments'))[0].n,0);
  assert.equal((await q('select count(*)::int as n from pde_reservation_payments'))[0].n,0);
  await db.exec('set role authenticated');assert.equal((await q('select count(*)::int as n from monthly_payment_reminder_states where organization_id=$1',[other]))[0].n,0);
  await assert.rejects(q("update monthly_payment_reminder_states set paid_at=now()"),/permission denied/);
  await assert.rejects(q('select monthly_reminder_argentina_today()'),/permission denied/);
 }finally{await db.close()}
});
