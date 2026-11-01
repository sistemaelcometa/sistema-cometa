import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { randomUUID } from 'node:crypto';
import test from 'node:test';
import { PGlite } from '@electric-sql/pglite';
import { argentinaDay, watchArgentinaDay } from '../lib/argentina-day.ts';

const read = path => readFile(new URL('../' + path, import.meta.url), 'utf8');
function fn(source, name) {
  const start = source.indexOf('create or replace function ' + name + '(');
  return source.slice(start, source.indexOf('$$;', source.indexOf('as $$', start)) + 3);
}

test('Argentina midnight releases yesterday contracts while today stays occupied, without changing financial history', async () => {
  const db = new PGlite(), org = randomUUID(), other = randomUUID(), actor = randomUUID();
  const rows = async (sql, args=[]) => (await db.query(sql,args)).rows;
  try {
    const schema = await read('supabase/migrations/001_initial_rentals_schema.sql');
    await db.exec(`create schema auth;create table auth.users(id uuid primary key);
      create function auth.uid() returns uuid language sql stable as $$select nullif(current_setting('test.actor',true),'')::uuid;$$;`);
    await db.exec(schema.match(/create type \w+ as enum \([\s\S]*?\);/g).join('\n'));
    await db.exec(schema.match(/create table \w+ \([\s\S]*?\r?\n\);/g).join('\n'));
    for (const name of ['is_org_member','has_org_role']) await db.exec(fn(schema,name));
    const migration = await read('supabase/migrations/069_urban_availability_after_lease_end.sql');
    await db.exec(migration); await db.exec(migration);
    const tenantMigration = await read('supabase/migrations/070_urban_tenant_status_after_lease_end.sql');
    await db.exec(tenantMigration); await db.exec(tenantMigration);
    await rows("select set_config('test.actor',$1,false)",[actor]);
    await rows('insert into auth.users values($1)',[actor]);
    await rows("insert into profiles(id,email) values($1,'test@local')",[actor]);
    await rows("insert into organizations(id,name,slug) values($1,'A','a'),($2,'B','b')",[org,other]);
    await rows("insert into organization_members(organization_id,user_id,role,status) values($1,$2,'owner','active')",[org,actor]);
    const building = (await rows("insert into urban_buildings(organization_id,name,address) values($1,'Edificio','Direccion') returning id",[org]))[0].id;
    const tenant = (await rows("insert into contacts(organization_id,first_name) values($1,'Inquilino') returning id",[org]))[0].id;
    const today = "(now() at time zone 'America/Argentina/Buenos_Aires')::date";
    const units = {};
    for (const [name,offset,status] of [['expired',-1,'rented'],['last-day',0,'rented'],['current',30,'rented'],['future',60,'rented'],['maintenance',-1,'maintenance'],['archived',-1,'archived']]) {
      const unit = (await rows("insert into urban_units(organization_id,building_id,name,surface_m2,status) values($1,$2,$3,50,$4) returning id",[org,building,name,status]))[0].id;
      units[name] = unit;
      await rows(`insert into urban_leases(organization_id,unit_id,primary_tenant_contact_id,start_date,end_date,current_amount,currency,monthly_due_day,status)
        values($1,$2,$3,${today} + ${name==='future'?10:-60},${today} + ${offset},950000,'ARS',10,'active')`,[org,unit,tenant]);
    }
    const expiredTenant = (await rows("insert into contacts(organization_id,first_name,is_tenant) values($1,'Anterior',true) returning id",[org]))[0].id;
    await rows('update urban_leases set primary_tenant_contact_id=$1 where unit_id=$2',[expiredTenant,units.expired]);
    const before = await rows('select * from urban_leases order by id');
    const result = await rows('select * from get_urban_structure($1)',[org]);
    const byName = Object.fromEntries(result.map(row=>[row.unit_name,row]));
    assert.equal(byName.expired.unit_status,'available'); assert.equal(byName.expired.lease_id,null);
    assert.equal(byName['last-day'].unit_status,'rented'); assert.ok(byName['last-day'].lease_id);
    assert.ok(byName.current.lease_id); assert.ok(byName.future.lease_id);
    assert.equal(byName.maintenance.unit_status,'maintenance'); assert.equal(byName.archived,undefined);
    assert.deepEqual(await rows('select * from get_urban_structure($1)',[other]),[]);
    const tenants = await rows('select * from get_urban_tenants($1)',[org]);
    const expiredRow = tenants.find(row=>row.id===expiredTenant);
    assert.equal(Number(expiredRow.active_lease_count),0);
    assert.equal(Number(expiredRow.lease_count),1);
    assert.equal(expiredRow.current_units,null);
    assert.ok(expiredRow.last_lease_end);
    const currentTenant = tenants.find(row=>row.id===tenant);
    assert.equal(Number(currentTenant.active_lease_count),3);
    assert.equal(Number(currentTenant.lease_count),5);
    assert.ok(currentTenant.current_units.includes('last-day'));
    assert.ok(currentTenant.current_units.includes('future'));
    assert.ok(!currentTenant.current_units.includes('maintenance'));
    assert.deepEqual(await rows('select * from get_urban_tenants($1)',[other]),[]);
    assert.deepEqual(await rows('select * from urban_leases order by id'),before);
    assert.equal((await rows('select count(*)::int as n from urban_charges'))[0].n,0);
    await rows("select update_urban_unit_details($1,$2,null,'available',null)",[org,units.expired]);
    await assert.rejects(rows("select update_urban_unit_details($1,$2,null,'available',null)",[org,units['last-day']]),/contrato activo/);
    await assert.rejects(rows("select update_urban_unit_details($1,$2,null,'available',null)",[org,units.future]),/contrato activo/);
  } finally { await db.close(); }
});

test('day watcher uses Argentina dates, refreshes once per change and cleans up listeners', () => {
  assert.equal(argentinaDay(new Date('2026-11-01T02:59:59Z')),'2026-10-31');
  assert.equal(argentinaDay(new Date('2026-11-01T03:00:00Z')),'2026-11-01');
  const listeners = new Map(), originalWindow=globalThis.window, originalDocument=globalThis.document;
  let interval, cleared=false, date=new Date('2026-11-01T02:59:59Z'), calls=0;
  const events={addEventListener:(event,fn)=>listeners.set(event,fn),removeEventListener:(event)=>listeners.delete(event)};
  globalThis.window={...events,setInterval:fn=>{interval=fn;return 1},clearInterval:()=>{cleared=true}};
  globalThis.document=events;
  try {
    const stop=watchArgentinaDay(()=>calls++,()=>date);
    interval(); assert.equal(calls,0);
    date=new Date('2026-11-01T03:00:00Z'); interval(); assert.equal(calls,1);
    listeners.get('focus')(); listeners.get('visibilitychange')(); assert.equal(calls,1);
    date=new Date('2026-11-03T12:00:00Z'); listeners.get('focus')(); assert.equal(calls,2);
    stop(); assert.equal(cleared,true); assert.equal(listeners.size,0);
  } finally {globalThis.window=originalWindow;globalThis.document=originalDocument;}
});
