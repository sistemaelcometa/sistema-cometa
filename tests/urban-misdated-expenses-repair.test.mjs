import assert from 'node:assert/strict';
import { randomUUID } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import { PGlite } from '@electric-sql/pglite';

const root = new URL('../', import.meta.url);
const sql = path => readFile(new URL(path, root), 'utf8');
function functionSql(source, name) {
  const start = source.indexOf(`create or replace function ${name}(`);
  assert.ok(start >= 0, name);
  return source.slice(start, source.indexOf('$$;', source.indexOf('as $$', start)) + 3);
}

test('one-off correction archives only September costs and keeps October, receipts and payments intact', async t => {
  const db = new PGlite();
  const org = '98a857e1-dacc-4890-90e9-1f1ac8de9782', actor = randomUUID();
  const building = randomUUID(), unit = randomUUID(), tenant = randomUUID(), lease = randomUUID();
  const periods = [randomUUID(), randomUUID()], charge = randomUUID();
  const paid = randomUUID(), voided = randomUUID(), expenses = [], replacementIds = [];
  const costs = [['Seguros - Seguro',6094],['Servicios - AMOS',11594],['Impuestos - Provincial',10950],['Impuestos - Municipal',53247]];
  const query = async (text, args = []) => (await db.query(text, args)).rows;
  const snapshot = table => query(`select * from ${table} order by id`);
  const repair = await sql('supabase/manual/2026-10-20_retirar_gastos_septiembre_colonizadores.sql');
  async function rejectedRepair(pattern) {
    const before = await snapshot('urban_expense_items');
    await assert.rejects(db.exec(repair), pattern);
    await db.exec('rollback');
    assert.deepEqual(await snapshot('urban_expense_items'), before);
    assert.equal((await query("select tgenabled from pg_trigger where tgname='guard_urban_expense_item_payment_lock_before_change'"))[0].tgenabled, 'O');
  }
  try {
    const schema = await sql('supabase/migrations/001_initial_rentals_schema.sql');
    await db.exec(`create schema auth; create table auth.users(id uuid primary key);
      create function auth.uid() returns uuid language sql stable as $$
        select nullif(current_setting('test.actor_id', true), '')::uuid;
      $$;`);
    await db.exec(schema.match(/create type \w+ as enum \([\s\S]*?\);/g).join('\n'));
    await db.exec(schema.match(/create table \w+ \([\s\S]*?\r?\n\);/g).join('\n'));
    await db.exec(functionSql(schema, 'has_org_role'));
    const permissions = await sql('supabase/migrations/055_urban_billing_single_source_of_truth.sql');
    await db.exec(functionSql(permissions, 'can_manage_urban_billing_sync'));
    await db.exec(await sql('supabase/migrations/060_stop_urban_billing_sync_churn.sql'));
    const exclusions = await sql('supabase/migrations/045_urban_expense_item_unit_exclusions.sql');
    await db.exec(exclusions.slice(exclusions.indexOf('create table'), exclusions.indexOf('alter table')));
    await query("select set_config('test.actor_id',$1,false)", [actor]);
    await query('insert into auth.users values($1)', [actor]);
    await query("insert into profiles(id,email) values($1,'test@localhost')", [actor]);
    await query("insert into organizations(id,name,slug) values($1,'Prueba','prueba')", [org]);
    await query("insert into organization_members(organization_id,user_id,role,status) values($1,$2,'owner','active')", [org,actor]);
    await query("insert into urban_buildings(id,organization_id,name) values($1,$2,'COLONIZADORES')", [building,org]);
    await query("insert into urban_units(id,organization_id,building_id,name,surface_m2) values($1,$2,$3,'DPTO 3',113)", [unit,org,building]);
    await query("insert into contacts(id,organization_id,first_name,last_name) values($1,$2,'BETINA','ACOSTA')", [tenant,org]);
    await query("insert into urban_leases(id,organization_id,unit_id,primary_tenant_contact_id,start_date,end_date,current_amount,currency,monthly_due_day,status) values($1,$2,$3,$4,'2026-10-01','2028-09-30',950000,'ARS',10,'active')", [lease,org,unit,tenant]);
    await query("insert into urban_charges(id,organization_id,lease_id,unit_id,period_month,due_date,status) values($1,$2,$3,$4,'2026-10-01','2026-10-10','partial')", [charge,org,lease,unit]);
    for (let i=0;i<2;i++) await query("insert into urban_expense_periods(id,organization_id,building_id,period_month,status) values($1,$2,$3,$4,'calculated')", [periods[i],org,building,i===0?'2026-09-01':'2026-10-01']);
    for (const [description,amount] of costs) {
      const originals = [randomUUID(),randomUUID()]; expenses.push(originals[0]); replacementIds.push(originals[1]);
      for(let i=0;i<2;i++) await query("insert into urban_expense_items(id,organization_id,period_id,expense_date,description,amount,currency,transfer_to_tenant) values($1,$2,$3,'2026-10-20',$4,$5,'ARS',true)", [originals[i],org,periods[i],description,amount]);
      const allocation = randomUUID(), item = randomUUID();
      await query("insert into urban_charge_items(id,organization_id,charge_id,item_type,description,amount_due,currency,source_entity_type,source_entity_id) values($1,$2,$3,'building_expense',$4,$5,'ARS','urban_expense_allocation',$6)", [item,org,charge,description,amount/4,allocation]);
      await query("insert into urban_expense_allocations(id,organization_id,expense_item_id,period_id,unit_id,unit_surface_m2_snapshot,building_total_surface_m2_snapshot,percentage_snapshot,allocated_amount,currency,transfer_to_tenant,tenant_amount,charge_item_id) values($1,$2,$3,$4,$5,113,452,25,$6,'ARS',true,$6,$7)", [allocation,org,originals[0],periods[0],unit,amount/4,item]);
    }
    for(const [id,status,amount] of [[paid,'valid',950000],[voided,'voided',95000]]) await query("insert into urban_payments(id,organization_id,lease_id,unit_id,payment_date,received_amount,currency,payment_method,status) values($1,$2,$3,$4,'2026-10-06',$5,'ARS','transfer',$6)", [id,org,lease,unit,amount,status]);
    const rent = randomUUID();
    await query("insert into urban_charge_items(id,organization_id,charge_id,item_type,description,amount_due,currency) values($1,$2,$3,'rent','Alquiler',950000,'ARS')", [rent,org,charge]);
    await query("insert into urban_payment_allocations(organization_id,payment_id,charge_item_id,allocated_amount,currency) values($1,$2,$3,950000,'ARS')", [org,paid,rent]);
    await query("insert into urban_payment_allocations(organization_id,payment_id,charge_item_id,allocated_amount,currency) select organization_id,$1,id,amount_due,'ARS' from urban_charge_items where charge_id=$2 and item_type='building_expense'", [voided,charge]);
    await db.exec(await sql('supabase/migrations/067_lock_building_expenses_after_any_monthly_payment.sql'));

    await t.test('missing October copy or changed amount aborts without touching expenses or disabling guards', async () => {
      await query("update urban_expense_periods set status='draft' where id=$1", [periods[1]]);
      await query('update urban_expense_items set amount=6000 where id=$1', [replacementIds[0]]);
      await rejectedRepair(/Falta una copia unica en octubre/);
      await query('update urban_expense_items set amount=6094 where id=$1', [replacementIds[0]]);
      await query("update urban_expense_periods set status='calculated' where id=$1", [periods[1]]);
    });

    await t.test('valid money allocated to an expense prevents any correction', async () => {
      await query("update urban_payments set status='valid' where id=$1", [voided]);
      await rejectedRepair(/Hay dinero valido imputado/);
      await query("update urban_payments set status='voided' where id=$1", [voided]);
    });

    await t.test('a failure after archiving rolls back the archive, concept changes and temporary guard exception', async () => {
      const conceptsBefore = await snapshot('urban_charge_items');
      await db.exec(`create function reject_repair_audit() returns trigger language plpgsql as $$
        begin
          if new.action = 'repair_misdated_september_expenses' then raise exception 'Prueba de rollback posterior'; end if;
          return new;
        end; $$;
        create trigger reject_repair_audit before insert on audit_logs for each row execute function reject_repair_audit();`);
      await rejectedRepair(/Prueba de rollback posterior/);
      assert.deepEqual(await snapshot('urban_charge_items'), conceptsBefore);
      await db.exec('drop trigger reject_repair_audit on audit_logs; drop function reject_repair_audit();');
    });

    await t.test('successful correction archives only four September items, keeps October/history and closes the exact balance', async () => {
      const paymentsBefore=await snapshot('urban_payments'), allocationsBefore=await snapshot('urban_payment_allocations');
      const octoberBefore=await query('select * from urban_expense_items where period_id=$1 order by id', [periods[1]]);
      const expensesAllocationsBefore=await snapshot('urban_expense_allocations');
      await db.exec(repair);
      assert.ok((await query('select status from urban_expense_items where id=any($1::uuid[])', [expenses])).every(r=>r.status==='voided'));
      assert.equal((await query('select status from urban_charges where id=$1', [charge]))[0].status,'paid');
      assert.deepEqual(await snapshot('urban_payments'),paymentsBefore);
      assert.deepEqual(await snapshot('urban_payment_allocations'),allocationsBefore);
      assert.deepEqual(await snapshot('urban_expense_allocations'),expensesAllocationsBefore);
      assert.deepEqual(await query('select * from urban_expense_items where period_id=$1 order by id', [periods[1]]),octoberBefore);
      assert.equal((await query("select status from urban_expense_periods where id=$1", [periods[0]]))[0].status,'closed');
      await assert.rejects(query('update urban_expense_items set amount=1 where id=$1', [expenses[0]]),/ya hay un cobro registrado/);
      await db.exec(repair);
      assert.equal((await query("select count(*)::int as n from audit_logs where action='repair_misdated_september_expenses'"))[0].n,1);
    });
  } finally { await db.close(); }
});
