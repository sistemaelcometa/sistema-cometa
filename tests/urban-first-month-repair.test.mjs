import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import { PGlite } from '@electric-sql/pglite';

const root = new URL('../', import.meta.url);
const sql = path => readFile(new URL(path, root), 'utf8');
const org = '98a857e1-dacc-4890-90e9-1f1ac8de9782';
const charge = '0f592252-be61-4946-84c3-5c3fee521f0f';
const paid = 'fb987ff3-1dac-4304-ada6-3093c9b4d9a6';
const voided = '8d39799a-fb8c-4add-a9ec-99f4ee618b05';
const items = [
  ['d019661d-4330-4ea5-a7fe-98dbca581c1e', 'rent', 950000, 'urban_lease'],
  ['994cea24-9158-4aab-aa9b-5c91e1c29bd3', 'building_expense', 2898.5, 'urban_expense_allocation'],
  ['ad04d3b7-603c-49a9-a69f-fcbbb6012282', 'building_expense', 1523.5, 'urban_expense_allocation'],
  ['b9fc6786-4fb8-4c77-922c-a442d06e842d', 'building_expense', 13311.75, 'urban_expense_allocation'],
  ['f1cedbf0-ef48-4a34-ab69-9f3ac39636c0', 'building_expense', 2737.5, 'urban_expense_allocation'],
  ['7788e7a1-0d8b-4f69-97c1-97fbb1c969e8', 'rent_surcharge', 95000, 'payment_surcharge'],
];

function functionSql(source, name) {
  const start = source.indexOf(`create or replace function ${name}(`);
  assert.ok(start >= 0, name);
  return source.slice(start, source.indexOf('$$;', source.indexOf('as $$', start)) + 3);
}

test('first-month repair preserves money/history and prevents expense and surcharge resurrection', async t => {
  const db = new PGlite();
  const actor = randomUUID(), building = randomUUID(), unit = randomUUID();
  const lease = randomUUID(), tenant = randomUUID(), period = randomUUID();
  const query = async (text, args = []) => (await db.query(text, args)).rows;
  const snapshot = table => query(`select * from ${table} order by id`);
  try {
    const schema = await sql('supabase/migrations/001_initial_rentals_schema.sql');
    await db.exec(`create schema auth;
      create table auth.users(id uuid primary key);
      create function auth.uid() returns uuid language sql stable as $$
        select nullif(current_setting('test.actor_id', true), '')::uuid;
      $$;`);
    await db.exec(schema.match(/create type \w+ as enum \([\s\S]*?\);/g).join('\n'));
    await db.exec(schema.match(/create table \w+ \([\s\S]*?\r?\n\);/g).join('\n'));
    await db.exec(functionSql(schema, 'has_org_role'));
    await db.exec(functionSql(schema, 'is_org_member'));
    const permissions = await sql('supabase/migrations/055_urban_billing_single_source_of_truth.sql');
    for (const name of ['can_manage_urban_billing_sync', 'can_read_urban_billing_sync']) {
      await db.exec(functionSql(permissions, name));
    }
    await db.exec(await sql('supabase/migrations/060_stop_urban_billing_sync_churn.sql'));
    await query("select set_config('test.actor_id', $1, false)", [actor]);
    await query('insert into auth.users values ($1)', [actor]);
    await query("insert into profiles(id,email) values($1,'test@localhost')", [actor]);
    await query("insert into organizations(id,name,slug) values($1,'Prueba','prueba')", [org]);
    await query("insert into organization_members(organization_id,user_id,role,status) values($1,$2,'owner','active')", [org, actor]);
    await query("insert into urban_buildings(id,organization_id,name) values($1,$2,'COLONIZADORES')", [building, org]);
    await query("insert into urban_units(id,organization_id,building_id,name,surface_m2) values($1,$2,$3,'DPTO 3',20)", [unit, org, building]);
    await query("insert into contacts(id,organization_id,first_name,last_name) values($1,$2,'BETINA','ACOSTA')", [tenant, org]);
    await query("insert into urban_leases(id,organization_id,unit_id,primary_tenant_contact_id,start_date,end_date,current_amount,currency,monthly_due_day,status) values($1,$2,$3,$4,'2026-10-01','2028-09-30',950000,'ARS',10,'active')", [lease, org, unit, tenant]);
    await query("insert into urban_charges(id,organization_id,lease_id,unit_id,period_month,due_date,status) values($1,$2,$3,$4,'2026-10-01','2026-10-10','partial')", [charge, org, lease, unit]);
    await query("insert into urban_expense_periods(id,organization_id,building_id,period_month,status) values($1,$2,$3,'2026-09-01','calculated')", [period, org, building]);
    for (const [id, type, amount, source] of items) {
      await query("insert into urban_charge_items(id,organization_id,charge_id,item_type,description,amount_due,currency,source_entity_type) values($1,$2,$3,$4,'Prueba',$5,'ARS',$6)", [id, org, charge, type, amount, source]);
      if (type === 'building_expense') {
        const expense = randomUUID(), allocation = randomUUID();
        await query("insert into urban_expense_items(id,organization_id,period_id,expense_date,description,amount,currency,transfer_to_tenant) values($1,$2,$3,'2026-09-01','Prueba',$4,'ARS',true)", [expense, org, period, amount]);
        await query("insert into urban_expense_allocations(id,organization_id,expense_item_id,period_id,unit_id,unit_surface_m2_snapshot,building_total_surface_m2_snapshot,percentage_snapshot,allocated_amount,currency,transfer_to_tenant,tenant_amount,charge_item_id) values($1,$2,$3,$4,$5,20,20,100,$6,'ARS',true,$6,$7)", [allocation, org, expense, period, unit, amount, id]);
        await query('update urban_charge_items set source_entity_id=$1 where id=$2', [allocation, id]);
      }
    }
    for (const [id, date, amount, status] of [[paid, '2026-10-06', 950000, 'valid'], [voided, '2026-10-20', 95000, 'voided']]) {
      await query("insert into urban_payments(id,organization_id,lease_id,unit_id,payment_date,received_amount,currency,payment_method,status) values($1,$2,$3,$4,$5,$6,'ARS','transfer',$7)", [id, org, lease, unit, date, amount, status]);
    }
    for (const [id, type, amount] of items) {
      await query("insert into urban_payment_allocations(organization_id,payment_id,charge_item_id,allocated_amount,currency) values($1,$2,$3,$4,'ARS')", [org, type === 'rent' ? paid : voided, id, type === 'rent_surcharge' ? 74528.75 : amount]);
    }
    const paymentsBefore = await snapshot('urban_payments');
    const allocationsBefore = await snapshot('urban_payment_allocations');
    const expenseItemsBefore = await snapshot('urban_expense_items');
    const expenseCostsBefore = (await snapshot('urban_expense_allocations')).map(({ charge_item_id, ...cost }) => cost);
    const migration = await sql('supabase/migrations/066_guard_first_month_expenses_and_voided_surcharges.sql');
    const repair = await sql('supabase/manual/2026-10-20_reparar_colonizadores_dpto3_octubre.sql');

    await t.test('diagnostic reproduces false partial with $115471.25 of stale concepts', async () => {
      const diagnostic = await sql('supabase/manual/2026-10-20_diagnostico_colonizadores_dpto3_octubre.sql');
      const [row] = await query(diagnostic);
      assert.equal(row.estado_guardado, 'partial');
      assert.equal(Number(row.expensas_aplicables), 0);
      assert.equal(Number(row.saldo_base_exacto), 0);
      assert.equal(Number(row.saldo_conceptos_exacto), 115471.25);
      assert.equal(Number(row.cantidad_pagos_validos), 1);
    });

    await t.test('repair is repeatable, settles rent and keeps all payment/cost history', async () => {
      await db.exec(migration);
      await db.exec(migration);
      await db.exec(repair);
      await db.exec(repair);
      assert.equal((await query('select status from urban_charges where id=$1', [charge]))[0].status, 'paid');
      assert.equal(Number((await query('select sum(amount_due) as total from urban_charge_items where charge_id=$1', [charge]))[0].total), 950000);
      assert.deepEqual(await snapshot('urban_payments'), paymentsBefore);
      assert.deepEqual(await snapshot('urban_payment_allocations'), allocationsBefore);
      assert.deepEqual(await snapshot('urban_expense_items'), expenseItemsBefore);
      assert.deepEqual((await snapshot('urban_expense_allocations')).map(({ charge_item_id, ...cost }) => cost), expenseCostsBefore);
      assert.equal((await query("select count(*)::int as n from audit_logs where action='repair_first_month_charge'"))[0].n, 1);
    });

    await t.test('reconciliation cannot attach September expenses to an October lease', async () => {
      await query('select reconcile_urban_expense_period_charges($1,$2)', [org, period]);
      assert.ok((await query("select amount_due from urban_charge_items where item_type='building_expense'")).every(r => Number(r.amount_due) === 0));
      assert.ok((await snapshot('urban_expense_allocations')).every(r => r.charge_item_id === null));
      // November must still bill October expenses, including a unit with exclusions.
      await query("update urban_expense_periods set period_month='2026-10-01' where id=$1", [period]);
      await query('select reconcile_urban_expense_period_charges($1,$2)', [org, period]);
      const [next] = await query("select sum(ci.amount_due) as expenses from urban_charge_items ci join urban_charges ch on ch.id=ci.charge_id where ch.period_month='2026-11-01' and ci.item_type='building_expense'");
      assert.equal(Number(next.expenses), 20471.25);
      await query('select reconcile_urban_expense_period_charges($1,$2)', [org, period]);
      assert.equal((await query("select count(*)::int as n from urban_charge_items ci join urban_charges ch on ch.id=ci.charge_id where ch.period_month='2026-11-01'"))[0].n, 4);
      await query("update urban_expense_periods set period_month='2026-09-01' where id=$1", [period]);
    });

    await t.test('repair aborts and rolls back when valid money has changed', async () => {
      const extra = randomUUID();
      await query("insert into urban_payments(id,organization_id,lease_id,unit_id,payment_date,received_amount,currency,payment_method) values($1,$2,$3,$4,'2026-10-20',1,'ARS','cash')", [extra, org, lease, unit]);
      await query("insert into urban_payment_allocations(organization_id,payment_id,charge_item_id,allocated_amount,currency) values($1,$2,$3,1,'ARS')", [org, extra, items[5][0]]);
      const before = await snapshot('urban_charge_items');
      await assert.rejects(db.exec(repair), /Hay conceptos\/pagos diferentes/);
      await db.exec('rollback');
      assert.deepEqual(await snapshot('urban_charge_items'), before);
      await query('delete from urban_payment_allocations where payment_id=$1', [extra]);
      await query('delete from urban_payments where id=$1', [extra]);
    });

    await t.test('billing API returns zero first-month expenses even when allocations are nonzero', async () => {
      // Move this fixture into the current month so this regression remains runnable later.
      await query("update urban_charges set period_month=(period_month+interval '100 years')::date where id<>$1", [charge]);
      await db.exec("update urban_leases set start_date=date_trunc('month',now())::date, end_date=(date_trunc('month',now())+interval '2 years')::date");
      await query("update urban_charges set period_month=date_trunc('month',now())::date,due_date=(date_trunc('month',now())+interval '9 days')::date where id=$1", [charge]);
      await query("update urban_expense_periods set period_month=(date_trunc('month',now())-interval '1 month')::date where id=$1", [period]);
      const [result] = await query('select get_urban_billing($1) as billing', [org]);
      const row = result.billing.charges.find(r => r.id === charge);
      assert.ok(row);
      assert.equal(row.expenses, 0);
      assert.equal(row.status, 'paid');
    });

    await t.test('void clears unused payment surcharges but preserves ones backed by another valid payment', async () => {
      const fee = items[5][0], extra = randomUUID();
      await query('update urban_payments set status=\'valid\' where id=$1', [voided]);
      await query('update urban_charge_items set amount_due=95000 where id=$1', [fee]);
      const operation = randomUUID();
      await query("select void_urban_payment($1,$2,'Prueba',$3)", [org, voided, operation]);
      assert.equal(Number((await query('select amount_due from urban_charge_items where id=$1', [fee]))[0].amount_due), 0);
      assert.equal((await query('select status from urban_charges where id=$1', [charge]))[0].status, 'paid');
      await query("select void_urban_payment($1,$2,'Prueba',$3)", [org, voided, operation]);
      await query("insert into urban_payments(id,organization_id,lease_id,unit_id,payment_date,received_amount,currency,payment_method) values($1,$2,$3,$4,'2026-10-20',100,'ARS','cash')", [extra, org, lease, unit]);
      await query("insert into urban_payment_allocations(organization_id,payment_id,charge_item_id,allocated_amount,currency) values($1,$2,$3,100,'ARS')", [org, extra, fee]);
      await query('update urban_charge_items set amount_due=95000 where id=$1', [fee]);
      await query("update urban_payments set status='valid' where id=$1", [voided]);
      await query("select void_urban_payment($1,$2,'Prueba compartida',$3)", [org, voided, randomUUID()]);
      assert.equal(Number((await query('select amount_due from urban_charge_items where id=$1', [fee]))[0].amount_due), 95000);
      await db.exec("update organization_members set role='viewer'");
      await assert.rejects(query("select void_urban_payment($1,$2,'Sin permisos',$3)", [org, extra, randomUUID()]), /No tenes permisos/);
    });
  } finally {
    await db.close();
  }
});
