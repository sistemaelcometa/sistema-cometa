import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import { createRequire } from 'node:module';
import test from 'node:test';
import vm from 'node:vm';
import { PGlite } from '@electric-sql/pglite';

const root = new URL('../', import.meta.url);
const sql = path => readFile(new URL(path, root), 'utf8');
function functionSql(source, name) {
  const start = source.indexOf(`create or replace function ${name}(`);
  assert.ok(start >= 0, name);
  return source.slice(start, source.indexOf('$$;', source.indexOf('as $$', start)) + 3);
}

test('any valid monthly payment locks the entire building expense period, including zero expenses', async t => {
  const db = new PGlite();
  const org = randomUUID(), actor = randomUUID(), tenant = randomUUID();
  const buildings = [randomUUID(), randomUUID()], units = [], charges = [], leases = [];
  const periods = [randomUUID(), randomUUID()], payments = [];
  const query = async (text, args = []) => (await db.query(text, args)).rows;
  const snapshot = table => query(`select * from ${table} order by id`);
  const status = async index => (await query('select status from urban_expense_periods where id=$1', [periods[index]]))[0].status;
  async function pay(index, amount = 950000, type = 'rent') {
    const payment = randomUUID(), item = randomUUID();
    await query("insert into urban_charge_items(id,organization_id,charge_id,item_type,description,amount_due,currency) values($1,$2,$3,$4,'Prueba',$5,'ARS')", [item, org, charges[index], type, amount]);
    await query("insert into urban_payments(id,organization_id,lease_id,unit_id,payment_date,received_amount,currency,payment_method) values($1,$2,$3,$4,'2026-10-06',$5,'ARS','transfer')", [payment, org, leases[index], units[index], amount]);
    await query("insert into urban_payment_allocations(organization_id,payment_id,charge_item_id,allocated_amount,currency) values($1,$2,$3,$4,'ARS')", [org, payment, item, amount]);
    payments.push(payment);
    return payment;
  }
  const reset = (index = 0) => query("select reset_urban_expense_period($1,$2,'2026-09-01')", [org, buildings[index]]);
  const migration = await sql('supabase/migrations/067_lock_building_expenses_after_any_monthly_payment.sql');
  try {
    const schema = await sql('supabase/migrations/001_initial_rentals_schema.sql');
    await db.exec(`create schema auth; create table auth.users(id uuid primary key);
      create function auth.uid() returns uuid language sql stable as $$
        select nullif(current_setting('test.actor_id',true),'')::uuid;
      $$;`);
    await db.exec(schema.match(/create type \w+ as enum \([\s\S]*?\);/g).join('\n'));
    await db.exec(schema.match(/create table \w+ \([\s\S]*?\r?\n\);/g).join('\n'));
    await db.exec(functionSql(schema, 'has_org_role'));
    await db.exec(functionSql(schema, 'is_org_member'));
    const exclusions = await sql('supabase/migrations/045_urban_expense_item_unit_exclusions.sql');
    await db.exec(exclusions.slice(exclusions.indexOf('create table'), exclusions.indexOf('alter table')));
    await query("select set_config('test.actor_id',$1,false)", [actor]);
    await query('insert into auth.users values($1)', [actor]);
    await query("insert into profiles(id,email) values($1,'test@localhost')", [actor]);
    await query("insert into organizations(id,name,slug) values($1,'Prueba','prueba')", [org]);
    await query("insert into organization_members(organization_id,user_id,role,status) values($1,$2,'owner','active')", [org, actor]);
    await query("insert into contacts(id,organization_id,first_name) values($1,$2,'Inquilino')", [tenant, org]);
    for (let i = 0; i < 2; i++) {
      await query("insert into urban_buildings(id,organization_id,name) values($1,$2,$3)", [buildings[i], org, 'Edificio ' + i]);
      await query("insert into urban_expense_periods(id,organization_id,building_id,period_month,status) values($1,$2,$3,'2026-09-01','calculated')", [periods[i], org, buildings[i]]);
    }
    for (let i = 0; i < 3; i++) {
      const unit = randomUUID(), lease = randomUUID(), charge = randomUUID();
      units.push(unit); leases.push(lease); charges.push(charge);
      await query("insert into urban_units(id,organization_id,building_id,name,surface_m2) values($1,$2,$3,$4,20)", [unit, org, buildings[i === 2 ? 1 : 0], 'DPTO ' + i]);
      await query("insert into urban_leases(id,organization_id,unit_id,primary_tenant_contact_id,start_date,end_date,current_amount,currency,monthly_due_day,status) values($1,$2,$3,$4,'2026-10-01','2028-09-30',950000,'ARS',10,'active')", [lease, org, unit, tenant]);
      await query("insert into urban_charges(id,organization_id,lease_id,unit_id,period_month,due_date) values($1,$2,$3,$4,'2026-10-01','2026-10-10')", [charge, org, lease, unit]);
    }

    await t.test('migration backfills a rent-only payment with zero expense allocations without changing money', async () => {
      await pay(0);
      const beforePayments = await snapshot('urban_payments'), beforeAllocations = await snapshot('urban_payment_allocations');
      await db.exec(migration); await db.exec(migration);
      assert.equal(await status(0), 'closed');
      assert.equal(await status(1), 'calculated');
      assert.deepEqual(await snapshot('urban_payments'), beforePayments);
      assert.deepEqual(await snapshot('urban_payment_allocations'), beforeAllocations);
      await assert.rejects(reset(), /ya hay un cobro registrado/);
      await assert.rejects(query('select cleanup_urban_expense_period_allocations($1,$2)', [org, periods[0]]), /ya hay un cobro registrado/);
    });

    await t.test('direct API changes cannot reopen the paid period or insert/edit expenses', async () => {
      await assert.rejects(query("update urban_expense_periods set status='draft' where id=$1", [periods[0]]), /ya tiene cobros registrados/);
      await assert.rejects(query("insert into urban_expense_items(organization_id,period_id,expense_date,description,amount,currency) values($1,$2,'2026-09-01','Duplicado',100,'ARS')", [org, periods[0]]), /ya hay un cobro registrado/);
      const rpc = await sql('supabase/migrations/050_lock_expense_periods_after_calculation_and_payment.sql');
      await db.exec(functionSql(rpc, 'save_urban_expense_item'));
      await assert.rejects(query("select save_urban_expense_item($1,$2,'2026-09-01','Servicios','AMOS',100)", [org, buildings[0]]), /liquidacion de expensas ya esta calculada/);
      await db.exec(await sql('supabase/migrations/057_make_expense_calculation_idempotent.sql'));
      await assert.rejects(query("select calculate_urban_expense_period($1,$2,'2026-09-01')", [org, buildings[0]]), /periodo de expensas esta cerrado/);
    });

    await t.test('a second department keeps the whole building locked until all valid payments are voided', async () => {
      await pay(1, 1);
      await query("update urban_payments set status='voided' where id=$1", [payments[0]]);
      assert.equal(await status(0), 'closed');
      await assert.rejects(reset(), /ya hay un cobro registrado/);
      await query("update urban_payments set status='voided' where id=$1", [payments[1]]);
      assert.equal(await status(0), 'calculated');
      await reset();
      assert.equal(await status(0), 'draft');
      await query("insert into urban_expense_items(organization_id,period_id,expense_date,description,amount,currency) values($1,$2,'2026-09-01','Ahora permitido',100,'ARS')", [org, periods[0]]);
    });

    await t.test('a payment before a period exists still closes that period when it is created', async () => {
      const monthPeriod = randomUUID();
      await query("update urban_charges set period_month='2026-11-01' where id=$1", [charges[0]]);
      await pay(0, 100);
      await query("insert into urban_expense_periods(id,organization_id,building_id,period_month) values($1,$2,$3,'2026-10-01')", [monthPeriod, org, buildings[0]]);
      assert.equal((await query('select status from urban_expense_periods where id=$1', [monthPeriod]))[0].status, 'closed');
      // Other months and buildings remain editable.
      assert.equal(await status(0), 'draft');
      await reset(1);
      assert.equal(await status(1), 'draft');
      const expense = randomUUID();
      await query("insert into urban_expense_items(id,organization_id,period_id,expense_date,description,amount,currency) values($1,$2,$3,'2026-09-01','AMOS',100,'ARS')", [expense, org, periods[1]]);
      await query('insert into urban_expense_item_excluded_units(organization_id,expense_item_id,unit_id) values($1,$2,$3)', [org, expense, units[2]]);
      await pay(2, 100);
      assert.equal(await status(1), 'closed');
      assert.equal(await status(0), 'draft');
      await assert.rejects(query('update urban_expense_items set amount=200 where id=$1', [expense]), /ya hay un cobro registrado/);
      await assert.rejects(query('delete from urban_expense_items where id=$1', [expense]), /ya hay un cobro registrado/);
      await assert.rejects(query('delete from urban_expense_item_excluded_units where expense_item_id=$1', [expense]), /ya hay un cobro registrado/);
      await assert.rejects(query('delete from urban_expense_periods where id=$1', [periods[1]]), /ya hay un cobro registrado/);
    });

    await t.test('refreshing an unchanged lock does not rewrite updated_at or bypass reset permissions', async () => {
      const before = await snapshot('urban_expense_periods');
      await query('select refresh_urban_expense_period_payment_lock($1)', [periods[1]]);
      assert.deepEqual(await snapshot('urban_expense_periods'), before);
      await db.exec("update organization_members set role='viewer'");
      await assert.rejects(reset(), /No tenes permisos/);
      await query("select set_config('test.actor_id','',false)");
      await assert.rejects(reset(), /Usuario no autenticado/);
    });
  } finally { await db.close(); }
});

const require = createRequire(import.meta.url), ts = require('typescript');
const page = await sql('app/page.tsx');
const ast = ts.createSourceFile('page.tsx', page, ts.ScriptTarget.Latest, true, ts.ScriptKind.TSX);
const functions = new Map();
function visit(node) {
  if (ts.isFunctionDeclaration(node)) functions.set(node.name?.text, node);
  ts.forEachChild(node, visit);
}
visit(ast);
const helpers = ['parseDateParts', 'daysInMonth', 'T', 'addMonths', 'periodToDate', 'hasBuildingPeriodPayment'].map(name => functions.get(name).getText(ast)).join('\n');
const check = vm.runInNewContext(`${helpers};hasBuildingPeriodPayment`, { p: ['Enero','Febrero','Marzo','Abril','Mayo','Junio','Julio','Agosto','Septiembre','Octubre','Noviembre','Diciembre'] });

test('expense UI locks on the billed month, not on payment date, for any building unit', () => {
  const building = { units: [{ id: 'one' }, { id: 'two' }] };
  assert.equal(check(building, 'Septiembre 2026', [{ unitId: 'two', amount: 950000, chargePeriod: '2026-10', paidAt: '2026-09-30' }]), true);
  assert.equal(check(building, 'Septiembre 2026', [{ unitId: 'one', amount: 1, chargeId: 'charge' }], [{ id: 'charge', periodMonth: '2026-10-01' }]), true);
  assert.equal(check(building, 'Septiembre 2026', [{ unitId: 'other', amount: 1, chargePeriod: '2026-10' }]), false);
  assert.equal(check(building, 'Septiembre 2026', [{ unitId: 'one', amount: 1, chargePeriod: '2026-11' }]), false);
  assert.equal(check(building, 'Septiembre 2026', [{ unitId: 'one', amount: 1, chargePeriod: '2026-10', status: 'voided' }]), false);
  assert.equal(check(building, 'Septiembre 2026', [{ unitId: 'one', amount: 0, chargePeriod: '2026-10' }]), false);
  assert.equal(check(building, 'Diciembre 2026', [{ unitId: 'one', amount: 1, chargePeriod: '2027-01' }]), true);
  assert.ok(page.includes('expenseClosed=periodStatus===`closed`||hasBuildingPeriodPayment(e,t,paymentRecords,charges)'));
});
